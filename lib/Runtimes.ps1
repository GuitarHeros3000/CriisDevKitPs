#Requires -Version 5.1
<#
    De donde sale cada runtime: Git, Maven, Gradle, .NET, VS Code

    Parte de lib\Common.ps1, que es quien carga este archivo. No se toma
    por separado: los scripts siguen haciendo un unico dot-source de
    Common.ps1 y no se enteran de esta division.
#>

# --------------------------------------------------------------------------
# Git portable
#
# Git es el peor caso que se encontro probando Install-NoAdmin: su instalador
# ignora /CURRENTUSER, pide admin y se instala para toda la maquina; y tampoco
# se puede extraer, porque usa un Inno Setup mas nuevo del que sabe leer
# innoextract (y 7-Zip no reconoce el formato).
#
# PortableGit es la salida, y es oficial: no es un instalador sino un 7-Zip
# autoextraible que Git for Windows publica en cada release. No toca el
# registro, no pide admin y trae Git Bash entero.
# --------------------------------------------------------------------------

$GitReleasesApi = "https://api.github.com/repos/git-for-windows/git/releases"

function Get-Sha256FromReleaseBody {
    <#
        Saca el SHA-256 de un archivo de la tabla que Git for Windows publica en
        el cuerpo de cada release:

            Filename | SHA-256
            -------- | -------
            PortableGit-2.55.0.5-64-bit.7z.exe | 5aa8a20f6e9a...

        Es texto libre escrito por quien publica la release, no un campo de la
        API, asi que se busca la linea del archivo EXACTO en vez de fiarse de la
        posicion, y se comprueba que lo hallado tenga forma de SHA-256.
    #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][AllowNull()][string]$Body,
        [Parameter(Mandatory=$true)][string]$FileName
    )

    if ([string]::IsNullOrWhiteSpace($Body)) { return $null }

    foreach ($linea in ($Body -split "`r?`n")) {
        $partes = $linea -split '\|'
        if ($partes.Count -lt 2) { continue }
        if ($partes[0].Trim() -ne $FileName) { continue }

        $hash = $partes[1].Trim().ToLowerInvariant()
        if ($hash -match '^[0-9a-f]{64}$') { return $hash }
    }
    return $null
}

function Get-GitPortableAsset {
    <#
        De una release de la API de GitHub saca el autoextraible de PortableGit
        de 64 bits, con su version y su checksum.

        Separada de la llamada de red para poder probarla: recibe el objeto de
        la release ya descargado. Devuelve $null si esa release no publica un
        PortableGit de 64 bits, que pasa en algunas.
    #>
    param([Parameter(Mandatory=$true)]$Release)

    $asset = @($Release.assets | Where-Object { $_.name -match '^PortableGit-([\d.]+)-64-bit\.7z\.exe$' })
    if ($asset.Count -eq 0) { return $null }

    $nombre = $asset[0].name
    $null = $nombre -match '^PortableGit-([\d.]+)-64-bit\.7z\.exe$'

    return [PSCustomObject]@{
        Version  = $Matches[1]
        FileName = $nombre
        Url      = $asset[0].browser_download_url
        Sha256   = (Get-Sha256FromReleaseBody -Body $Release.body -FileName $nombre)
        Tag      = $Release.tag_name
    }
}

function Get-GitPortableRelease {
    <#
        Devuelve el PortableGit a instalar. Sin -Version, el de la ultima
        release; con -Version (ej: 2.55.0.5), se busca entre las ultimas
        publicadas.

        No se compone la etiqueta a mano a partir de la version: la etiqueta es
        "v2.55.0.windows.5" y el archivo "PortableGit-2.55.0.5-64-bit.7z.exe",
        dos formas distintas del mismo numero. Buscar por nombre de archivo
        entre las releases evita esa traduccion.
    #>
    param([string]$Version)

    $cabeceras = @{ 'User-Agent' = "AssassinSkipAdm/$KitVersion"; 'Accept' = 'application/vnd.github+json' }

    if ([string]::IsNullOrWhiteSpace($Version)) {
        $release = Invoke-JsonApi -Uri "$GitReleasesApi/latest" -Headers $cabeceras
        if (-not $release) { return $null }
        return Get-GitPortableAsset -Release $release
    }

    $buscada = $Version.Trim().TrimStart('v')
    $releases = Invoke-JsonApi -Uri "$GitReleasesApi`?per_page=30" -Headers $cabeceras
    if (-not $releases) { return $null }

    foreach ($r in $releases) {
        $a = Get-GitPortableAsset -Release $r
        if ($a -and $a.Version -eq $buscada) { return $a }
    }
    return $null
}

function ConvertFrom-GitVersionOutput {
    <#
        Convierte lo que escupe "git --version" en la version tal como se llama
        el archivo publicado:

            "git version 2.55.0.windows.5"  ->  "2.55.0.5"

        Existe porque tres sitios distintos parseaban esa cadena cada uno a su
        manera, y uno lo hacia mal: con [\d.]+ el cuantificador voraz se comia
        tambien el punto de ".windows", devolvia "2.55.0." y la parte
        ".windows.5" ya no encajaba en el grupo opcional. Se veia como
        "Git 2.55.0." en la lista de versiones instaladas.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Output)

    if ([string]::IsNullOrWhiteSpace($Output)) { return $null }

    if ($Output -match 'git version (\d+\.\d+\.\d+)\.windows\.(\d+)') {
        return "$($Matches[1]).$($Matches[2])"
    }
    # Un Git que no sea el de Windows no lleva el sufijo .windows.N.
    if ($Output -match 'git version (\d+(?:\.\d+)*)') {
        return $Matches[1]
    }
    return $null
}

function Get-GitLine {
    <#
        La "linea" de una version de Git: 2.55.0.5 -> 2.55, que es lo que da
        nombre a la carpeta git-2.55. Es la misma regla que para Maven y Gradle,
        asi que delega en Get-ToolLine en vez de repetirla; se conserva el
        nombre propio porque es como se lee en Setup-GitEnv.
    #>
    param([Parameter(Mandatory=$true)][string]$Version)
    return (Get-ToolLine -Version $Version)
}

function Write-GitShell {
    <#
        Shell de Git portable. Solo se pone cmd\ en el PATH, que es lo que hace
        tambien el instalador oficial en su opcion por defecto: bin\ trae bash,
        sh y otros que taparian los comandos del sistema con el mismo nombre.
        Para el entorno Unix completo esta git-bash.exe, que se anuncia abajo.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$GitPath,
        [Parameter(Mandatory=$true)][string]$Version
    )

    $cmdDir = ConvertTo-CmdLiteral (Join-Path $GitPath "cmd")
    $bash   = ConvertTo-CmdEchoText (Join-Path $GitPath "git-bash.exe")
    $linea  = (Get-GitLine -Version $Version) -replace '\.', ''

    $lines = @(
        "@echo off",
        "set `"PATH=$cmdDir;%PATH%`"",
        "title Git $Version Shell",
        "echo.",
        "echo ============================================",
        "echo   Git $Version Shell",
        "echo ============================================",
        "echo.",
        "git --version",
        "echo.",
        "echo Comandos:",
        "echo   git clone <url>     - Clonar un repositorio",
        "echo   git status          - Estado del repositorio",
        "echo.",
        "echo Para el entorno Unix completo (bash, ssh, grep):",
        "echo   $bash",
        "echo.",
        "echo Escribe exit para cerrar",
        "cmd /k"
    )

    $file = Join-Path $GitPath "git$linea-shell.bat"
    Set-Content -Path $file -Value ($lines -join "`n") -Encoding ASCII
    return $file
}

# --------------------------------------------------------------------------
# Maven y Gradle
#
# Los dos son lo mismo desde el punto de vista del kit: un zip que se
# descomprime, se pone su bin\ en el PATH y necesita un JDK para funcionar. Ni
# uno ni otro traen instalador, asi que aqui no hay nada que esquivar: es el
# camino oficial y no pide admin.
# --------------------------------------------------------------------------

$MavenBaseUrl  = "https://dlcdn.apache.org/maven/maven-3/"
$GradleVersionApi = "https://services.gradle.org/versions/current"
$GradleAllVersionsApi = "https://services.gradle.org/versions/all"

function Get-MavenRelease {
    <#
        Devuelve la version de Maven a instalar, su zip y su SHA-512.

        Apache no tiene una API: se lee el listado de directorio de dlcdn y se
        coge la version mas alta. Y publica SHA-512, no SHA-256, que es la razon
        de que Invoke-Download admita los dos.

        Admite tambien una LINEA ("3.9") y devuelve su ultimo parche. Hacia
        falta porque el devenv.json anota la linea, igual que hace con Python:
        pedir "3.9" componia la URL de una version que no existe y Restore-Env
        no podia reinstalar Maven, solo daba un 404.
    #>
    param([string]$Version)

    $elegida = $Version
    $linea   = if ($Version -match '^\d+\.\d+$') { $Version } else { $null }

    if ([string]::IsNullOrWhiteSpace($elegida) -or $linea) {
        $html = Get-WebText -Uri $MavenBaseUrl -Quiet
        if (-not $html) { return $null }

        $vs = @([regex]::Matches($html, 'href="(\d+\.\d+\.\d+)/"') |
                ForEach-Object { $_.Groups[1].Value } |
                Where-Object { -not $linea -or $_ -like "$linea.*" } |
                Sort-Object { [version]$_ } -Descending)
        if ($vs.Count -eq 0) { return $null }
        $elegida = $vs[0]
    }

    $zip = "apache-maven-$elegida-bin.zip"
    $url = "$MavenBaseUrl$elegida/binaries/$zip"

    $sha = Get-HashFromChecksumText -Text (Get-WebText -Uri "$url.sha512" -Quiet) -Algorithm SHA512

    return [PSCustomObject]@{
        Version  = $elegida
        FileName = $zip
        Url      = $url
        Sha512   = $sha
        # La carpeta que el zip trae dentro.
        Inner    = "apache-maven-$elegida"
    }
}

function Get-GradleRelease {
    <#
        Gradle si publica una API con la version actual, su zip y su checksum.
        Para una version concreta se componen las URL, que siguen un patron fijo.

        Una LINEA ("9.7") se resuelve a su ultimo parche consultando el listado
        completo. Aqui no bastaba con componer la URL como con una version
        exacta: Gradle publica tanto 9.7 como 9.7.1, asi que pedir la linea
        habria instalado el primer parche en vez del ultimo, en silencio. Es lo
        que anota el devenv.json, de modo que sin esto Restore-Env reproducia
        una version distinta de la que se guardo.
    #>
    param([string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) {
        $api = Invoke-JsonApi -Uri $GradleVersionApi -Quiet
        if (-not $api -or [string]::IsNullOrWhiteSpace($api.version)) { return $null }
        $elegida = $api.version
        $url     = $api.downloadUrl
        $shaUrl  = $api.checksumUrl
    }
    else {
        $elegida = $Version.Trim()

        if ($elegida -match '^\d+\.\d+$') {
            $todas = Invoke-JsonApi -Uri $GradleAllVersionsApi -Quiet
            if (-not $todas) { return $null }

            # Fuera los candidatos y los rotos: un manifiesto pide una version
            # publicada, no una release candidate.
            $enLinea = @($todas |
                Where-Object { -not $_.snapshot -and -not $_.broken -and -not $_.rcFor -and -not $_.milestoneFor } |
                ForEach-Object { [string]$_.version } |
                Where-Object { $_ -eq $elegida -or $_ -like "$elegida.*" } |
                Sort-Object { try { [version]$_ } catch { [version]'0.0' } } -Descending)

            if ($enLinea.Count -eq 0) { return $null }
            $elegida = $enLinea[0]
        }

        $url     = "https://services.gradle.org/distributions/gradle-$elegida-bin.zip"
        $shaUrl  = "$url.sha256"
    }

    $sha = Get-HashFromChecksumText -Text (Get-WebText -Uri $shaUrl -Quiet) -Algorithm SHA256

    return [PSCustomObject]@{
        Version  = $elegida
        FileName = "gradle-$elegida-bin.zip"
        Url      = $url
        Sha256   = $sha
        Inner    = "gradle-$elegida"
    }
}

function Get-JdkVersionAt {
    <#
        Devuelve la version del JDK que hay en una carpeta, o $null.

        Se lee del archivo "release" que todo JDK trae en su raiz, en vez de
        ejecutar java.exe: es instantaneo, no arranca una JVM y funciona aunque
        ese JDK este roto. Solo se recurre al binario si no hay release.

        El parametro se llama JavaHome y no Home: $Home es una variable
        automatica de PowerShell -la carpeta del usuario- y declararla como
        parametro rompe la funcion entera.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyString()][AllowNull()][string]$JavaHome)

    if ([string]::IsNullOrWhiteSpace($JavaHome)) { return $null }
    $raiz = [Environment]::ExpandEnvironmentVariables($JavaHome)
    if (-not (Test-Path -LiteralPath $raiz)) { return $null }

    $release = Join-Path $raiz "release"
    if (Test-Path -LiteralPath $release) {
        foreach ($l in (Get-Content -LiteralPath $release -ErrorAction SilentlyContinue)) {
            if ($l -match '^JAVA_VERSION\s*=\s*"?([^"]+)"?') { return $Matches[1].Trim() }
        }
    }

    $exe = Join-Path $raiz "bin\java.exe"
    if (Test-Path -LiteralPath $exe) {
        $run = Invoke-NativeCommand -FilePath $exe -Arguments @('-version') -Quiet
        if ($run.Output -match 'version "([^"]+)"') { return $Matches[1] }
    }
    return $null
}

function Get-JavaMajor {
    <#
        La version mayor de un Java, normalizando el esquema antiguo: "1.8.0_202"
        es Java 8, no Java 1. Sin esto, comparar versiones daria que Java 8 es
        mas nuevo que Java 25.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) { return $null }
    if ($Version -match '^1\.(\d+)') { return [int]$Matches[1] }
    if ($Version -match '^(\d+)')    { return [int]$Matches[1] }
    return $null
}

function Resolve-KitJdk {
    <#
        Devuelve la ruta del JDK del kit que se le pida por su linea ("21"), o
        $null si no esta instalado. Sin -Linea devuelve el mas alto, que es lo
        que hacia Get-KitJavaHome y sigue siendo el valor por defecto.
    #>
    param([string]$Linea)

    if ([string]::IsNullOrWhiteSpace($Linea)) { return (Get-KitJavaHome) }

    $ruta = Join-Path (Join-Path $WorkspaceRoot "Java") ("jdk-" + $Linea.Trim())
    if (Test-Path (Join-Path $ruta "bin\java.exe")) { return $ruta }
    return $null
}

function Get-KitJdkLines {
    <#
        Las lineas de JDK del kit instaladas, de menor a mayor.

        No es Get-InstalledRuntimeLines con la entrada de Java porque aqui hacen
        falta dos cosas mas: exigir bin\java.exe -una carpeta a medio borrar daria
        un shell con un JAVA_HOME roto- y ordenar por NUMERO, ya que como texto
        "21" iria antes que "8" y "el mas alto" acabaria siendo el Java 8.
    #>
    $javaRoot = Join-Path $WorkspaceRoot "Java"
    if (-not (Test-Path -LiteralPath $javaRoot)) { return @() }

    return @(Get-ChildItem -LiteralPath $javaRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^jdk-(\d+)$' -and (Test-Path (Join-Path $_.FullName "bin\java.exe")) } |
        ForEach-Object { $_.Name -replace '^jdk-', '' } |
        Sort-Object { [int]$_ })
}

function Get-KitJavaHome {
    <#
        Devuelve el JDK del kit que deben usar Maven y Gradle, o $null.

        Se prefiere el JDK del kit al JAVA_HOME del sistema a proposito: si hay
        uno instalado por el kit es el que el usuario controla, y es el que va a
        seguir ahi. Se coge el de version mas alta.
    #>
    $lineas = @(Get-KitJdkLines)
    if ($lineas.Count -eq 0) { return $null }

    # Get-KitJdkLines ordena de menor a mayor.
    return (Join-Path (Join-Path $WorkspaceRoot "Java") ("jdk-" + $lineas[-1]))
}

function Write-BuildToolShell {
    <#
        Shell de Maven o de Gradle. Los dos necesitan lo mismo: su bin\ en el
        PATH y un JAVA_HOME que apunte a un JDK, porque ninguno de los dos trae
        Java dentro y sin esa variable no arrancan.

        Si hay un JDK del kit se usa ese; si no, se deja el JAVA_HOME que ya
        hubiera y el shell avisa cuando no hay ninguno, en vez de fallar con un
        error de Java que no dice de que va.

        Con -SufijoJdk se escribe un shell APARTE atado a un JDK concreto
        (mvn39-java21-shell.bat). Existe porque con varios JDK instalados el
        shell normal se queda con el mas alto, y quien trabaja a diario con
        proyectos que piden Javas distintos necesitaba reejecutar el Setup para
        cambiar. Con uno por JDK, se abre el que toque.
    #>
    param(
        [Parameter(Mandatory=$true)][ValidateSet('Maven', 'Gradle')][string]$Tool,
        [Parameter(Mandatory=$true)][string]$ToolPath,
        [Parameter(Mandatory=$true)][string]$Version,
        [string]$JavaHome,
        [string]$SufijoJdk
    )

    $binCmd = ConvertTo-CmdLiteral (Join-Path $ToolPath "bin")
    $exe    = if ($Tool -eq 'Maven') { 'mvn' } else { 'gradle' }
    $linea  = (Get-ToolLine -Version $Version) -replace '\.', ''

    $lines = @(
        "@echo off",
        "set `"PATH=$binCmd;%PATH%`""
    )

    if ($JavaHome) {
        $lines += "set `"JAVA_HOME=$(ConvertTo-CmdLiteral $JavaHome)`""
        $lines += "set `"PATH=$(ConvertTo-CmdLiteral (Join-Path $JavaHome 'bin'));%PATH%`""
    }

    $titulo = if ($SufijoJdk) { "$Tool $Version  (Java $SufijoJdk)" } else { "$Tool $Version Shell" }
    # Gradle tampoco lee HTTP_PROXY: se le pasa como propiedades de sistema por
    # GRADLE_OPTS, que es lo mismo que hace su gradle.properties pero sin tocar
    # el ~\.gradle del usuario.
    if ($Tool -eq 'Gradle') { $lines += Get-GradleProxyLine }

    $lines += @(
        "title $titulo",
        "echo.",
        "echo ============================================",
        "echo   $titulo",
        "echo ============================================",
        "echo."
    )

    if (-not $JavaHome) {
        $lines += @(
            "if not defined JAVA_HOME (",
            "    echo AVISO: no hay JAVA_HOME y $exe no arranca sin un JDK.",
            "    echo   Instala uno con:  Setup-JavaEnv.bat",
            "    echo.",
            ")"
        )
    }

    $lines += @(
        "$exe -version",
        "echo.",
        "echo Escribe exit para cerrar",
        "cmd /k"
    )

    $nombre = if ($SufijoJdk) { "$($exe)$linea-java$SufijoJdk-shell.bat" } else { "$($exe)$linea-shell.bat" }
    $file = Join-Path $ToolPath $nombre
    Set-Content -Path $file -Value ($lines -join "`n") -Encoding ASCII
    return $file
}

function Write-BuildToolShellsPorJdk {
    <#
        Escribe un shell de la herramienta por CADA JDK del kit instalado, ademas
        del de siempre.

        Solo tiene sentido con mas de un JDK: con uno, el shell normal ya apunta
        ahi y un segundo archivo identico solo confundiria.

        Tambien borra los shells de JDK que ya no estan, para que no queden
        apuntando a una carpeta desinstalada.

        Devuelve { Escritos = rutas; Borrados = cuantos se retiraron }.
    #>
    param(
        [Parameter(Mandatory=$true)][ValidateSet('Maven', 'Gradle')][string]$Tool,
        [Parameter(Mandatory=$true)][string]$ToolPath,
        [Parameter(Mandatory=$true)][string]$Version
    )

    $exe    = if ($Tool -eq 'Maven') { 'mvn' } else { 'gradle' }
    $lineas = @(Get-KitJdkLines)
    if ($lineas.Count -lt 2) { $lineas = @() }

    # Fuera los que sobran antes de escribir: si se desinstalo un JDK, su shell
    # ya no lleva a ningun sitio.
    $borrados = 0
    Get-ChildItem -LiteralPath $ToolPath -Filter "$exe*-java*-shell.bat" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '-java(\d+)-shell\.bat$' -and $lineas -notcontains $Matches[1] } |
        ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            $borrados++
        }

    $escritos = @()
    foreach ($l in $lineas) {
        $escritos += (Write-BuildToolShell -Tool $Tool -ToolPath $ToolPath -Version $Version `
                                           -JavaHome (Join-Path (Join-Path $WorkspaceRoot "Java") "jdk-$l") `
                                           -SufijoJdk $l)
    }

    return [PSCustomObject]@{
        Escritos = $escritos
        Borrados = $borrados
    }
}

function Get-ShellJavaHome {
    <#
        Que JAVA_HOME exporta un shell generado, o cadena vacia si no exporta
        ninguno.
    #>
    param([Parameter(Mandatory=$true)][string]$ShellBat)

    if (-not (Test-Path -LiteralPath $ShellBat)) { return '' }
    return ([regex]::Match((Get-Content -LiteralPath $ShellBat -Raw), 'set "JAVA_HOME=([^"]+)"')).Groups[1].Value
}
function Get-BuildToolJavaBindings {
    <#
        A que linea de JDK del kit apunta hoy el shell por defecto de cada
        herramienta: @{ maven = '21'; gradle = '25' }.

        Se lee del shell y no se deduce del catalogo porque es el dato real: es
        ese JAVA_HOME el que decide con que Java compilan. Solo se devuelven los
        que apuntan a un JDK del kit; uno de fuera no lo sabria reproducir
        Restore-Env en otra maquina.
    #>
    $bindings = [ordered]@{}
    $javaRoot = (Join-Path $WorkspaceRoot "Java").TrimEnd('\')

    foreach ($t in @(
        @{ Clave = 'maven';  Root = 'Maven';  Exe = 'mvn';    Jar = 'lib\maven-core-*.jar';      Rx = 'maven-core-([\d.]+)\.jar' },
        @{ Clave = 'gradle'; Root = 'Gradle'; Exe = 'gradle'; Jar = 'lib\gradle-launcher-*.jar'; Rx = 'gradle-launcher-([\d.]+)\.jar' }
    )) {
        $root = Join-Path $WorkspaceRoot $t.Root
        if (-not (Test-Path -LiteralPath $root)) { continue }

        foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            $jars = @(Get-ChildItem -Path (Join-Path $d.FullName $t.Jar) -ErrorAction SilentlyContinue)
            if ($jars.Count -eq 0 -or $jars[0].Name -notmatch $t.Rx) { continue }

            $shell = Join-Path $d.FullName "$($t.Exe)$((Get-ToolLine -Version $Matches[1]) -replace '\.','')-shell.bat"
            $jh = Get-ShellJavaHome -ShellBat $shell
            if (-not $jh) { continue }

            $padre = Split-Path -Parent $jh.TrimEnd('\')
            if ($padre.TrimEnd('\') -ine $javaRoot) { continue }
            if ((Split-Path -Leaf $jh) -match '^jdk-(\d+)$') { $bindings[$t.Clave] = $Matches[1] }
        }
    }

    return $bindings
}

function Sync-BuildToolShells {
    <#
        Repasa los shells por JDK de Maven y Gradle contra los JDK que hay ahora.

        Se llama despues de instalar o desinstalar un JDK: si no, instalar Java
        21 despues de Maven no daria shell para el 21, y habria que reejecutar el
        Setup de Maven a mano.

        Ademas rescata el shell por defecto si su JAVA_HOME se quedo apuntando a
        un JDK borrado: no hacerlo deja la herramienta rota hasta que alguien
        reejecute su Setup, y el error que da Java no menciona nada de esto.

        Devuelve una linea por herramienta tocada; nada si no hay ninguna.
    #>
    $resumen = @()

    foreach ($t in @(
        @{ Tool = 'Maven';  Root = 'Maven';  Exe = 'mvn';    Marca = 'bin\mvn.cmd';    Jar = 'lib\maven-core-*.jar';      Rx = 'maven-core-([\d.]+)\.jar' },
        @{ Tool = 'Gradle'; Root = 'Gradle'; Exe = 'gradle'; Marca = 'bin\gradle.bat'; Jar = 'lib\gradle-launcher-*.jar'; Rx = 'gradle-launcher-([\d.]+)\.jar' }
    )) {
        $root = Join-Path $WorkspaceRoot $t.Root
        if (-not (Test-Path -LiteralPath $root)) { continue }

        foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            if (-not (Test-Path (Join-Path $d.FullName $t.Marca))) { continue }

            # La version sale del jar y no de ejecutar la herramienta: gradle y
            # mvn necesitan JAVA_HOME, que aqui puede no estar puesto.
            $jars = @(Get-ChildItem -Path (Join-Path $d.FullName $t.Jar) -ErrorAction SilentlyContinue)
            if ($jars.Count -eq 0 -or $jars[0].Name -notmatch $t.Rx) { continue }
            $version = $Matches[1]

            $hechos = Write-BuildToolShellsPorJdk -Tool $t.Tool -ToolPath $d.FullName -Version $version
            if ($hechos.Escritos.Count -gt 0) {
                $resumen += "$($t.Tool) $version : $($hechos.Escritos.Count) shells, uno por JDK"
            }
            elseif ($hechos.Borrados -gt 0) {
                $resumen += "$($t.Tool) $version : retirados $($hechos.Borrados) shells de JDK que ya no estan"
            }

            # El shell por defecto atado a un JDK que ya no existe.
            $porDefecto = Join-Path $d.FullName "$($t.Exe)$((Get-ToolLine -Version $version) -replace '\.','')-shell.bat"
            $jh = Get-ShellJavaHome -ShellBat $porDefecto
            if ($jh -and -not (Test-Path -LiteralPath $jh)) {
                $nuevo = Get-KitJavaHome
                Write-BuildToolShell -Tool $t.Tool -ToolPath $d.FullName -Version $version -JavaHome $nuevo | Out-Null
                $resumen += if ($nuevo) {
                    "$($t.Tool) $version : el shell apuntaba a $(Split-Path -Leaf $jh), ahora a $(Split-Path -Leaf $nuevo)"
                } else {
                    "$($t.Tool) $version : el shell apuntaba a $(Split-Path -Leaf $jh), que ya no esta; queda sin JDK"
                }
            }
        }
    }

    return $resumen
}

function Get-ToolLine {
    <#
        La "linea" de una version: 3.9.16 -> 3.9, 9.7.1 -> 9.7. Da nombre a la
        carpeta, igual que en python-3.12 y git-2.55: una carpeta por linea, y
        -Force actualiza el parche dentro.
    #>
    param([Parameter(Mandatory=$true)][string]$Version)

    $p = $Version.TrimStart('v').Split('.')
    if ($p.Count -lt 2) { return $p[0] }
    return "$($p[0]).$($p[1])"
}

# --------------------------------------------------------------------------
# .NET SDK
#
# Es el caso mas facil de todos: Microsoft publica dotnet-install.ps1, un script
# pensado EXPRESAMENTE para instalar sin admin y en la carpeta que le digas. No
# hay nada que esquivar; solo hay que llamarlo bien y pasarle el proxy.
# --------------------------------------------------------------------------

$DotnetIndexUrl   = "https://builds.dotnet.microsoft.com/dotnet/release-metadata/releases-index.json"
$DotnetInstallUrl = "https://dot.net/v1/dotnet-install.ps1"

function Get-DotnetRelease {
    <#
        Devuelve el canal de .NET a instalar y la version exacta de su SDK.

        Sin -Channel se coge el LTS activo mas alto: es lo que quiere quien no
        tiene una preferencia. Los canales fuera de soporte se descartan, para no
        instalar algo que ya no recibe parches de seguridad.
    #>
    param([string]$Channel)

    $idx = Invoke-JsonApi -Uri $DotnetIndexUrl -Quiet
    if (-not $idx -or -not $idx.'releases-index') { return $null }

    $todos = @($idx.'releases-index' | Where-Object { $_.'latest-sdk' })

    if (-not [string]::IsNullOrWhiteSpace($Channel)) {
        $c = @($todos | Where-Object { $_.'channel-version' -eq $Channel.Trim() })
        if ($c.Count -eq 0) { return $null }
        $elegido = $c[0]
    }
    else {
        $vivos = @($todos | Where-Object { $_.'support-phase' -in @('active', 'maintenance') })
        $lts   = @($vivos | Where-Object { $_.'release-type' -eq 'lts' } |
                   Sort-Object { [version]$_.'channel-version' } -Descending)
        if ($lts.Count -gt 0) { $elegido = $lts[0] }
        elseif ($vivos.Count -gt 0) {
            $elegido = @($vivos | Sort-Object { [version]$_.'channel-version' } -Descending)[0]
        }
        else { return $null }
    }

    return [PSCustomObject]@{
        Channel    = $elegido.'channel-version'
        SdkVersion = $elegido.'latest-sdk'
        Tipo       = $elegido.'release-type'
        Soporte    = $elegido.'support-phase'
        Eol        = $elegido.'eol-date'
    }
}

function Write-DotnetShell {
    <#
        Shell del SDK de .NET. Ademas del PATH define DOTNET_ROOT.

        Comprobado: dotnet.exe SI localiza su propio SDK por la ubicacion del
        ejecutable, asi que compilar y ejecutar funciona sin esa variable. Lo que
        DOTNET_ROOT resuelve es lo otro: las herramientas globales y las
        aplicaciones ya publicadas la leen para saber que runtime usar, y en un
        equipo con un .NET instalado por admin en Program Files -lo normal- sin
        ella pueden acabar resolviendo al del sistema en vez de a este. Se pone
        para que el shell no deje esa ambiguedad.

        DOTNET_CLI_TELEMETRY_OPTOUT se pone a 1 porque este kit existe para
        equipos corporativos vigilados, donde una herramienta que llama a casa
        sin avisar es justo lo que no se quiere.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$DotnetPath,
        [Parameter(Mandatory=$true)][string]$Version,
        [Parameter(Mandatory=$true)][string]$Channel
    )

    $raiz  = ConvertTo-CmdLiteral $DotnetPath
    $linea = $Channel -replace '\.', ''

    $lines = @(
        "@echo off",
        "set `"PATH=$raiz;%PATH%`"",
        "set `"DOTNET_ROOT=$raiz`"",
        "set `"DOTNET_CLI_TELEMETRY_OPTOUT=1`"",
        "title .NET $Version Shell",
        "echo.",
        "echo ============================================",
        "echo   .NET SDK $Version Shell",
        "echo ============================================",
        "echo.",
        "dotnet --version",
        "echo.",
        "echo Comandos:",
        "echo   dotnet new console  - Crear un proyecto",
        "echo   dotnet build        - Compilar",
        "echo   dotnet run          - Ejecutar",
        "echo.",
        "echo Escribe exit para cerrar",
        "cmd /k"
    )

    $file = Join-Path $DotnetPath "dotnet$linea-shell.bat"
    Set-Content -Path $file -Value ($lines -join "`n") -Encoding ASCII
    return $file
}

# --------------------------------------------------------------------------
# Visual Studio Code portable
#
# El instalador normal de VS Code -el "System Installer"- pide admin. Pero
# Microsoft publica ademas el .zip, y ese admite MODO PORTABLE oficial: basta
# con crear una carpeta "data" junto al ejecutable y VS Code guarda ahi sus
# ajustes y extensiones en vez de en %APPDATA%. Sin registro y sin admin.
# --------------------------------------------------------------------------

$VSCodeUpdateApi = "https://update.code.visualstudio.com/api/update/win32-x64-archive/stable/latest"

function Get-VSCodeRelease {
    <#
        Devuelve la version, el zip y su SHA-256, que la API de actualizacion de
        VS Code da los tres de una vez. Se pide el canal "archive": el otro es el
        instalador, que es justo el que pide admin.
    #>
    param([string]$Version)

    # Con una version concreta no se usa la API de actualizacion -que solo sabe
    # de la ultima- sino la ruta por version, que redirige al zip. Comprobado
    # con 1.134.0 y 1.135.0. A cambio no hay checksum publicado: se descarga sin
    # el y se dice, en vez de fingir que se verifico.
    if (-not [string]::IsNullOrWhiteSpace($Version)) {
        $v = $Version.Trim()
        return [PSCustomObject]@{
            Version  = $v
            Url      = "https://update.code.visualstudio.com/$v/win32-x64-archive/stable"
            Sha256   = $null
            FileName = "VSCode-win32-x64-$v.zip"
        }
    }

    $api = Invoke-JsonApi -Uri $VSCodeUpdateApi -Quiet
    if (-not $api -or [string]::IsNullOrWhiteSpace($api.url)) { return $null }

    $version = if ($api.productVersion) { $api.productVersion } else { $api.name }

    return [PSCustomObject]@{
        Version  = $version
        Url      = $api.url
        Sha256   = $api.sha256hash
        FileName = "VSCode-win32-x64-$version.zip"
    }
}

function Write-VSCodeShell {
    <#
        Shell de VS Code. Pone bin\ en el PATH, que es donde vive code.cmd, el
        lanzador de linea de comandos.

        VSCODE_PORTABLE se fija ademas de crear la carpeta data\: la carpeta sola
        ya activa el modo portable al arrancar desde ahi, pero la variable lo
        deja explicito para cualquier proceso que se lance desde este shell.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$VSCodePath,
        [Parameter(Mandatory=$true)][string]$Version
    )

    $binCmd  = ConvertTo-CmdLiteral (Join-Path $VSCodePath "bin")
    $dataCmd = ConvertTo-CmdLiteral (Join-Path $VSCodePath "data")
    $exeTxt  = ConvertTo-CmdEchoText (Join-Path $VSCodePath "Code.exe")
    $linea   = (Get-ToolLine -Version $Version) -replace '\.', ''

    $lines = @(
        "@echo off",
        "set `"PATH=$binCmd;%PATH%`"",
        "set `"VSCODE_PORTABLE=$dataCmd`"",
        "title VS Code $Version Shell",
        "echo.",
        "echo ============================================",
        "echo   VS Code $Version (portable)",
        "echo ============================================",
        "echo.",
        "echo Ajustes y extensiones viven en data\, no en tu perfil.",
        "echo.",
        "echo Comandos:",
        "echo   code .              - Abrir la carpeta actual",
        "echo   code archivo.txt    - Abrir un archivo",
        "echo   $exeTxt",
        "echo.",
        "echo Escribe exit para cerrar",
        "cmd /k"
    )

    $file = Join-Path $VSCodePath "code$linea-shell.bat"
    Set-Content -Path $file -Value ($lines -join "`n") -Encoding ASCII
    return $file
}
