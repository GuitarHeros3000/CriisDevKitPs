#Requires -Version 5.1
<#
.SYNOPSIS
    Setup-DotnetEnv.ps1 - Instala el SDK de .NET sin permisos de administrador.
.DESCRIPTION
    Es el caso mas facil de todos los que cubre el kit: Microsoft publica
    dotnet-install.ps1, un script pensado EXPRESAMENTE para instalar sin admin y
    en la carpeta que le digas. Aqui no hay nada que esquivar.

    Lo que aporta el kit: elegir el canal LTS con soporte, poner el SDK en la
    misma estructura que el resto (Dotnet\dotnet-<canal>), pasarle el proxy
    corporativo, dejarlo en el PATH y generar un shell con DOTNET_ROOT, que es
    imprescindible cuando el SDK no vive en su carpeta por defecto.

    Se usa -NoPath a proposito: de anadir la carpeta al PATH se encarga el kit,
    con copia de seguridad, y no un script de terceros. Ademas se compara el
    PATH antes y despues, para no tener que fiarse de que ese modificador se
    respete.
.PARAMETER Channel
    Canal a instalar (ej: 10.0, 8.0). Si se omite, el LTS con soporte mas alto.
.PARAMETER Force
    Reinstala aunque ya exista ese canal.
.PARAMETER WhatIf
    Muestra el plan y no toca nada.
.EXAMPLE
    .\Setup-DotnetEnv.ps1
.EXAMPLE
    .\Setup-DotnetEnv.ps1 -Channel 8.0 -Force
#>

param(
    [string]$Channel,

    [switch]$Force,

    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

$DotnetRoot = Join-Path $WorkspaceRoot "Dotnet"

Write-Log "========================================" "INFO"
Write-Log "  .NET SDK Setup" "INFO"
Write-Log "========================================" "INFO"
Write-Log ""

function Get-InstalledDotnetVersion {
    param([string]$DotnetExe)

    if (-not (Test-Path -LiteralPath $DotnetExe)) { return $null }

    # Se fija DOTNET_ROOT apuntando a ESTE dotnet para que la version que se lea
    # sea la suya con seguridad, aunque el entorno ya traiga una apuntando a
    # otra instalacion.
    $previo = $env:DOTNET_ROOT
    $env:DOTNET_ROOT = Split-Path -Parent $DotnetExe
    try {
        $run = Invoke-NativeCommand -FilePath $DotnetExe -Arguments @('--version') -Quiet
        if ($run.ExitCode -ne 0) { return $null }
        if ($run.Output -match '(\d+\.\d+\.\d+)') { return $Matches[1] }
        return $null
    }
    finally { Restore-EnvVar -Name 'DOTNET_ROOT' -Value $previo }
}

function Install-DotnetSdk {
    param([PSCustomObject]$Release, [string]$FolderName)

    $dotnetPath = Join-Path $DotnetRoot $FolderName
    $dotnetExe  = Join-Path $dotnetPath "dotnet.exe"

    if (Test-Path $dotnetExe) {
        $instalada = Get-InstalledDotnetVersion -DotnetExe $dotnetExe

        if ($Force) {
            Write-Log "-Force: se reinstala $FolderName desde cero" "WARN"
            if ($instalada) { Write-Log "  habia: $instalada  ->  se pondra: $($Release.SdkVersion)" }
            Remove-Item -LiteralPath $dotnetPath -Recurse -Force
        }
        elseif ($instalada -eq $Release.SdkVersion) {
            Write-Log ".NET SDK $instalada ya esta instalado y al dia" "SUCCESS"
            return $dotnetPath
        }
        elseif ($instalada) {
            Write-Log "Ya hay .NET SDK $instalada en $FolderName" "WARN"
            Write-Log "  Disponible: $($Release.SdkVersion)" "WARN"
            Write-Log "  Para actualizarlo:  .\Setup-DotnetEnv.bat -Channel $($Release.Channel) -Force" "WARN"
            return $dotnetPath
        }
        else {
            Write-Log "Hay un dotnet.exe que no arranca en $FolderName" "ERROR"
            Write-Log "  Instalacion corrupta. Reinstala con:  -Force" "WARN"
            return $null
        }
    }

    if (-not (Test-Path $DotnetRoot)) {
        New-Item -ItemType Directory -Path $DotnetRoot -Force | Out-Null
    }

    # El instalador oficial se baja con Invoke-Download y no a pelo, para que
    # pase por el proxy y por el espejo interno como todo lo demas.
    $script = Join-Path $env:TEMP ("dotnet-install-" + [Guid]::NewGuid().ToString('N') + ".ps1")
    # Este es el caso donde la firma mas importa de todo el kit: no es un zip
    # que se extrae, es un SCRIPT que se va a EJECUTAR. Microsoft lo firma.
    Write-Log "Obteniendo el instalador oficial de Microsoft..."
    if (-not (Invoke-Download -Uri $DotnetInstallUrl -OutFile $script `
                              -FirmanteEsperado 'Microsoft Corporation' `
                              -Description "dotnet-install.ps1")) {
        return $null
    }

    try {
        $argumentos = @{
            Version    = $Release.SdkVersion
            InstallDir = $dotnetPath
            NoPath     = $true    # del PATH se encarga el kit, con copia previa
        }

        # dotnet-install.ps1 tiene sus propios parametros de proxy: no lee
        # HTTPS_PROXY por su cuenta, asi que hay que pasarselo.
        $proxy = Resolve-DownloadProxy -Uri ([Uri]"https://builds.dotnet.microsoft.com")
        if ($proxy) {
            $partes = Split-ProxyCredential -Proxy $proxy
            $argumentos.ProxyAddress = $partes.Direccion
            if (-not $partes.Credencial) {
                # Con credenciales escritas en la URL no se puede hacer mas: el
                # script solo admite la identidad de Windows.
                $argumentos.ProxyUseDefaultCredentials = $true
            }
            else {
                Write-Log "  El instalador de Microsoft no admite usuario y clave de proxy." "WARN"
                Write-Log "  Si falla la descarga, es por eso." "WARN"
            }
            Write-Log "  Proxy para el instalador: $(Format-ProxyForDisplay $partes.Direccion)"
        }

        Write-Log "Instalando .NET SDK $($Release.SdkVersion) (canal $($Release.Channel))..."
        Write-Log "  (unos 200 MB, tarda un poco)"

        # Foto del PATH antes y despues, para poder afirmar que el instalador no
        # lo toca en vez de suponerlo. Comprobado que -NoPath se respeta: al
        # reinstalar no anade nada.
        #
        # Quien SI anade %USERPROFILE%\.dotnet\tools es la "primera ejecucion"
        # del SDK, la que dispara el primer 'dotnet new'. Ocurre una sola vez en
        # la vida del perfil y no la controla este kit, asi que si aparece
        # despues no sera aqui. Esta comprobacion se queda igualmente: es barata
        # y convierte "el kit es el unico que toca tu PATH" en algo que se
        # verifica en cada instalacion en vez de una promesa.
        $pathAntes = [Environment]::GetEnvironmentVariable('PATH', 'User')

        & $script @argumentos
        $rc = $LASTEXITCODE

        $pathDespues = [Environment]::GetEnvironmentVariable('PATH', 'User')
        if ($pathDespues -ne $pathAntes) {
            $antes  = @(Split-UserPath -Value $pathAntes)
            $nuevas = @(Split-UserPath -Value $pathDespues | Where-Object { $antes -notcontains $_ })
            foreach ($n in $nuevas) {
                Write-Log "  El instalador de Microsoft anadio al PATH: $n" "WARN"
            }
            if ($nuevas.Count -gt 0) {
                Write-Log "  No lo ha hecho el kit. Revisalo si no lo esperabas." "WARN"
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $script -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path $dotnetExe)) {
        Write-Log "El instalador termino pero no hay dotnet.exe en $dotnetPath" "ERROR"
        if ($rc) { Write-Log "  codigo de salida: $rc" "ERROR" }
        return $null
    }

    Write-Log ".NET SDK instalado en $dotnetPath" "SUCCESS"
    return $dotnetPath
}

# --------------------------------------------------------------------------

Write-Log $(if ($Channel) { "Buscando el canal $Channel..." } else { "Consultando los canales de .NET con soporte..." })

$release = Get-DotnetRelease -Channel $Channel
if (-not $release) {
    Write-Log "No se pudo determinar que .NET instalar." "ERROR"
    if ($Channel) { Write-Log "  El canal '$Channel' no aparece en el indice de Microsoft." "WARN" }
    else          { Write-Log "  No se pudo leer $DotnetIndexUrl. Reintenta." "WARN" }
    exit 1
}

Write-Log "  Canal $($release.Channel) ($($release.Tipo.ToUpperInvariant()), $($release.Soporte)), SDK $($release.SdkVersion)" "SUCCESS"
if ($release.Eol) { Write-Log "  Soporte hasta: $($release.Eol)" }

$FolderName = "dotnet-$($release.Channel)"
$shellName  = "dotnet$($release.Channel -replace '\.','')-shell.bat"

Write-Log "Carpeta destino: $DotnetRoot" "INFO"
Write-Log ""

if ($WhatIf) {
    $destino = Join-Path $DotnetRoot $FolderName
    $yaHay = Get-InstalledDotnetVersion -DotnetExe (Join-Path $destino "dotnet.exe")

    Write-Host ""
    Write-Host "Se va a instalar:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host ("  [version]  .NET SDK {0}  (canal {1}, {2})" -f $release.SdkVersion, $release.Channel, $release.Tipo.ToUpperInvariant())
    Write-Host ("  [metodo]   dotnet-install.ps1 de Microsoft, que instala por usuario de fabrica") -ForegroundColor DarkGray
    Write-Host ("  [carpeta]  {0}" -f $destino)
    if ($yaHay) {
        if ($Force) { Write-Host ("             -Force BORRARIA la actual ({0})" -f $yaHay) -ForegroundColor Red }
        else        { Write-Host ("             ya hay {0}; sin -Force no se tocaria" -f $yaHay) -ForegroundColor Yellow }
    }
    Write-Host ("  [PATH]     {0}" -f $destino)
    Write-Host ("  [shell]    {0}   (fija DOTNET_ROOT)" -f $shellName)
    Write-Host ""
    Write-Host "-WhatIf: no se ha tocado nada." -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

$dotnetPath = Install-DotnetSdk -Release $release -FolderName $FolderName
if (-not $dotnetPath) { exit 1 }

Show-PathConflicts -Root $DotnetRoot -Keep $dotnetPath -Label ".NET"
Add-UserPathEntry -Path $dotnetPath

Write-DotnetShell -DotnetPath $dotnetPath -Version $release.SdkVersion -Channel $release.Channel | Out-Null
Write-Log "Shell creado: $dotnetPath\$shellName" "SUCCESS"

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  CONFIGURACION COMPLETADA" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Estructura creada:" -ForegroundColor Yellow
Write-Host "  $DotnetRoot"
Write-Host "  +-- $FolderName\"
Write-Host "      +-- dotnet.exe"
Write-Host "      +-- $shellName"
Write-Host ""
Write-Host ".NET SDK $($release.SdkVersion) agregado al PATH, sin administrador." -ForegroundColor Green
Write-Host ""
Write-Host "Usa el shell y no el PATH a secas: fija DOTNET_ROOT, que es lo que leen" -ForegroundColor Gray
Write-Host "las herramientas globales y las apps publicadas para elegir runtime. Si hay" -ForegroundColor Gray
Write-Host "un .NET instalado por admin en Program Files, sin esa variable pueden acabar" -ForegroundColor Gray
Write-Host "usando el del sistema en vez de este." -ForegroundColor Gray
Write-Host ""
Write-Host "Para comenzar:" -ForegroundColor Yellow
Write-Host "  Usa el shell: ..\Dotnet\$FolderName\$shellName" -ForegroundColor White
Write-Host "  Comprueba con: .\Doctor-Env.bat" -ForegroundColor Gray
Write-Host ""
