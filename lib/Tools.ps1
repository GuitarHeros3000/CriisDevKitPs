#Requires -Version 5.1
<#
    Herramientas auxiliares (7z, innoextract) y Node

    Parte de lib\Common.ps1, que es quien carga este archivo. No se toma
    por separado: los scripts siguen haciendo un unico dot-source de
    Common.ps1 y no se enteran de esta division.
#>

# --------------------------------------------------------------------------
# Herramientas auxiliares (7z, innoextract)
# --------------------------------------------------------------------------
#
# Install-NoAdmin necesita un extractor para los instaladores NSIS e Inno Setup.
# Antes se limitaba a decir que faltaba y parar. Ahora el kit puede conseguirlos
# el mismo y los deja aqui, en una carpeta hermana como el resto.

$KitToolsDir = Join-Path $WorkspaceRoot "Apps\tools"

function Find-KitTool {
    <#
    .SYNOPSIS
        Localiza una herramienta auxiliar. Devuelve su ruta, o $null.
    .DESCRIPTION
        Busca en dos sitios y en este orden:

          1. El PATH. Si el usuario ya tiene la herramienta instalada, se usa la
             suya: el kit no debe imponer su copia sobre algo que ya funciona.
          2. Apps\tools, donde deja las que ha descargado el propio kit.

        Solo busca. Descargarla es cosa de Install-NoAdmin, que es quien sabe si
        hace falta de verdad; Doctor usa esto para informar sin descargar nada.
    #>
    param([Parameter(Mandatory=$true)][string]$FileName)

    $enPath = Get-Command $FileName -ErrorAction SilentlyContinue
    if ($enPath) { return $enPath.Source }

    $propia = Join-Path $KitToolsDir $FileName
    if (Test-Path -LiteralPath $propia) { return $propia }

    return $null
}

function Test-RuntimeSelected {
    <#
        Ayuda a los scripts que aceptan un -Runtime opcional: sin valor, todos
        entran; con valor, solo el elegido.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [AllowEmptyString()][AllowNull()][string]$Selected
    )
    return ([string]::IsNullOrWhiteSpace($Selected) -or $Selected -eq $Name)
}

function Get-NodeArchiveInfo {
    <#
        URL y checksum oficial del zip de Node para una version concreta.
        Se centraliza aqui porque lo usan Setup-AngularEnv y Export-Env, y si
        divergieran el bundle offline traeria un archivo distinto al que instala
        el setup normal.
    #>
    param([Parameter(Mandatory=$true)][string]$Version)

    $v = $Version.TrimStart('v')
    $folder = "node-v$v-win-x64"
    $file = "$folder.zip"

    return [PSCustomObject]@{
        FileName   = $file
        FolderName = $folder
        Url        = "https://nodejs.org/dist/v$v/$file"
        ShasumsUrl = "https://nodejs.org/dist/v$v/SHASUMS256.txt"
    }
}

$NodeIndexUrl = "https://nodejs.org/dist/index.json"

function Get-NodeLtsReleases {
    <#
        Ultima release de cada linea LTS de Node que tenga zip para win-x64.
        El indice viene ordenado de mas nueva a mas vieja.

        Vive aqui y no en Setup-AngularEnv porque lo usan tres sitios: la
        resolucion de Node para Angular, Setup-NodeEnv y Update-Env.
    #>
    $index = Invoke-JsonApi -Uri $NodeIndexUrl -TimeoutSec 120 -Quiet
    if (-not $index) { return @() }

    $seen = @{}
    $result = @()
    foreach ($rel in $index) {
        if (-not $rel.lts -or $rel.lts -eq $false) { continue }
        if ($rel.files -notcontains 'win-x64-zip') { continue }

        $major = [int](($rel.version.TrimStart('v')).Split('.')[0])
        if ($seen.ContainsKey($major)) { continue }

        $seen[$major] = $true
        $result += [PSCustomObject]@{
            Major   = $major
            Version = $rel.version.TrimStart('v')
            Lts     = $rel.lts
        }
    }

    return @($result | Sort-Object Major)
}

function Get-GradleProxyLine {
    <#
        GRADLE_OPTS con el proxy, o nada si no hay proxy que pasar.

        Gradle, como Maven, ignora HTTP_PROXY y HTTPS_PROXY: la JVM solo mira sus
        propias propiedades de sistema. El TLS no se toca aqui porque Gradle
        corre sobre el JDK y ya va por el cacerts.
    #>
    $proxy = Resolve-DownloadProxy -Uri ([Uri]"https://services.gradle.org")
    if (-not $proxy) { return @() }

    $u = [Uri]$proxy
    $props = "-Dhttp.proxyHost=$($u.Host) -Dhttp.proxyPort=$($u.Port) " +
             "-Dhttps.proxyHost=$($u.Host) -Dhttps.proxyPort=$($u.Port)"

    $cred = Split-ProxyCredential -Proxy $proxy
    if ($cred -and $cred.Credencial) {
        $usuario = $cred.Credencial.UserName
        $clave   = $cred.Credencial.GetNetworkCredential().Password
        $props += " -Dhttp.proxyUser=$usuario -Dhttp.proxyPassword=$clave"
        $props += " -Dhttps.proxyUser=$usuario -Dhttps.proxyPassword=$clave"
    }

    return @("set `"GRADLE_OPTS=$props %GRADLE_OPTS%`"")
}

function Get-NodeCaLine {
    <#
        La linea que hace que Node confie en la CA de la empresa, o nada si no
        hay ninguna guardada.

        Node no mira el almacen de Windows ni el del JDK: lleva su propia lista
        compilada dentro del binario, y la unica forma de anadirle una CA sin
        recompilarlo es NODE_EXTRA_CA_CERTS. npm, ng y todo lo que corra sobre
        esa Node lo heredan por ser variable de entorno.
    #>
    if (-not (Test-Path -LiteralPath $CorpCaPem)) { return @() }
    return @("set `"NODE_EXTRA_CA_CERTS=$(ConvertTo-CmdLiteral $CorpCaPem)`"")
}

function Write-NodeShell {
    <#
        Shell de una Node instalada suelta (sin Angular). No define
        NPM_CONFIG_PREFIX: al no haber un CLI global que aislar, npm usa su
        prefijo normal dentro de la propia carpeta de Node.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$NodePath,
        [Parameter(Mandatory=$true)][string]$Version
    )

    $nodeCmd = ConvertTo-CmdLiteral $NodePath
    $major   = $Version.Split('.')[0]

    $lines = @(
        "@echo off",
        "set `"PATH=$nodeCmd;%PATH%`""
    )
    $lines += Get-NodeCaLine

    $lines += @(
        "title Node v$Version Shell",
        "echo.",
        "echo ============================================",
        "echo   Node v$Version Shell",
        "echo ============================================",
        "echo.",
        "node --version",
        "npm --version",
        "echo.",
        "echo Comandos:",
        "echo   node archivo.js     - Ejecutar",
        "echo   npm install         - Instalar dependencias",
        "echo.",
        "echo Escribe exit para cerrar",
        "cmd /k"
    )

    $file = Join-Path $NodePath "node$major-shell.bat"
    Set-Content -Path $file -Value ($lines -join "`n") -Encoding ASCII
    return $file
}
