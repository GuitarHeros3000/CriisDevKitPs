#Requires -Version 5.1
<#
.SYNOPSIS
    Setup-PythonEnv.ps1 - Configura entorno Python sin permisos de administrador
.DESCRIPTION
    Descarga Python portable e instala paquetes en carpeta por version.
    La estructura se crea en una carpeta 'Python' junto a la raiz del kit.
.PARAMETER PythonVersion
    Version de Python a instalar (ej: 3.12)
.PARAMETER InstallPackages
    Paquetes pip a instalar separados por coma (ej: django,flask)
.PARAMETER Force
    Reinstala aunque ya exista esa version menor. Necesario para actualizar el
    patch (3.12.9 -> 3.12.10), porque la carpeta se llama solo python-3.12.
    Borra la carpeta: se pierden los paquetes pip instalados ahi.
.EXAMPLE
    .\Setup-PythonEnv.ps1 -PythonVersion 3.12
.EXAMPLE
    .\Setup-PythonEnv.ps1 -PythonVersion 3.12 -InstallPackages django,flask
.EXAMPLE
    .\Setup-PythonEnv.ps1 -PythonVersion 3.12 -Force
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$PythonVersion = "3.12",

    [string]$InstallPackages,

    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

$PythonRoot = Join-Path $WorkspaceRoot "Python"

$PythonFtpUrl = "https://www.python.org/ftp/python/"

function Get-EmbedZipUrl {
    param([string]$FullVersion)
    return "$PythonFtpUrl$FullVersion/python-$FullVersion-embed-amd64.zip"
}

function Resolve-PythonVersion {
    <#
    .SYNOPSIS
        Convierte "3.12" en la ultima X.Y.Z que tenga binario para Windows.
    .DESCRIPTION
        Antes se rellenaba el patch con "0", asi que "-PythonVersion 3.12"
        instalaba 3.12.0, de octubre de 2023, con dos anos y medio de parches
        de seguridad sin aplicar.

        No basta con coger el numero mas alto: cuando una serie pasa a modo
        "solo seguridad", python.org publica esas versiones SOLO como codigo
        fuente. Por eso se prueban las candidatas de mayor a menor hasta dar
        con una que tenga de verdad el zip embeddable.

        Devuelve $null si no se pudo resolver, despues de explicar por que. No
        llama a exit: matar el proceso desde dentro de una funcion la hace
        intesteable e impide que nadie la reutilice. Misma convencion que
        Invoke-Download e Invoke-JsonApi en Common.ps1.
    #>
    param([string]$Requested)

    $parts = $Requested.Split('.')
    if ($parts.Count -ge 3) {
        Write-Log "Version exacta pedida: $Requested"
        return $Requested
    }

    $minorPrefix = "$($parts[0]).$($parts[1])"
    Write-Log "Buscando la ultima $minorPrefix.x con binario para Windows..."

    # El indice de python.org es un listado HTML de directorio, no JSON.
    $listing = Get-WebText -Uri $PythonFtpUrl

    if (-not $listing) {
        Write-Log "No se pudo leer el indice de python.org." "WARN"
        Write-Log "  Indica la version completa a mano:  -PythonVersion $minorPrefix.10" "WARN"
        return $null
    }

    $pattern = 'href="(' + [regex]::Escape($minorPrefix) + '\.\d+)/"'
    $candidates = @([regex]::Matches($listing, $pattern) |
        ForEach-Object { $_.Groups[1].Value } |
        Sort-Object { [version]$_ } -Descending)

    if ($candidates.Count -eq 0) {
        Write-Log "python.org no publica ninguna version $minorPrefix.x" "ERROR"
        return $null
    }

    # Se limita el sondeo: si en 12 intentos no aparece un zip, algo raro pasa.
    foreach ($candidate in ($candidates | Select-Object -First 12)) {
        if (Test-UrlExists -Uri (Get-EmbedZipUrl -FullVersion $candidate)) {
            Write-Log "  Elegida: $candidate" "SUCCESS"
            if ($candidate -ne $candidates[0]) {
                Write-Log "  ($($candidates[0]) es mas nueva pero solo se publica como codigo fuente)"
            }
            return $candidate
        }
    }

    Write-Log "Ninguna $minorPrefix.x reciente tiene zip embeddable para Windows." "ERROR"
    Write-Log "  Esa serie ya solo se publica como codigo fuente; usa una mas nueva." "WARN"
    return $null
}

Write-Log "========================================" "INFO"
Write-Log "  Python Environment Setup" "INFO"
Write-Log "========================================" "INFO"
Write-Log ""

# Acepta "3.12" o "3.12.4". El zip embeddable requiere la version completa X.Y.Z;
# el archivo ._pth usa solo el tag mayor+menor (ej: python312._pth).
#
# El exit vive AQUI, en el cuerpo del script, y no dentro de las funciones: ellas
# explican que fallo y devuelven $null, y es este nivel el que decide que eso es
# fatal. Asi se pueden probar por separado y reutilizar desde otro script sin que
# se lleven por delante el proceso entero.
$fullVersion = Resolve-PythonVersion -Requested $PythonVersion
if (-not $fullVersion) { exit 1 }

$versionParts = $fullVersion.Split('.')
$major = $versionParts[0]
$minor = $versionParts[1]
$minorVersion = "$major.$minor"
$minorTag = "$major$minor"

$EnvSetup = @{
    PythonRoot = $PythonRoot
    Version = $minorVersion
    FullVersion = $fullVersion
    MinorTag = $minorTag
    FolderName = "python-$minorVersion"
    DownloadUrl = (Get-EmbedZipUrl -FullVersion $fullVersion)
    GetPipUrl = "https://bootstrap.pypa.io/get-pip.py"
}

function Initialize-PythonDirectories {
    $pythonPath = Join-Path $EnvSetup.PythonRoot $EnvSetup.FolderName
    $scriptsPath = Join-Path $pythonPath "Scripts"

    Write-Log "Creando estructura en:"
    Write-Log "  $pythonPath"

    $directories = @(
        $EnvSetup.PythonRoot,
        $pythonPath,
        $scriptsPath
    )

    foreach ($dir in $directories) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    return $pythonPath
}

function Get-InstalledPythonVersion {
    param([string]$PythonExe)

    $run = Invoke-NativeCommand -FilePath $PythonExe -Arguments @('--version') -Quiet
    if ($run.ExitCode -ne 0) { return $null }
    if ($run.Output -match '(\d+\.\d+\.\d+)') { return $Matches[1] }
    return $null
}

function Get-PythonPortable {
    $pythonFolderPath = Join-Path $EnvSetup.PythonRoot $EnvSetup.FolderName
    $pythonExe = Join-Path $pythonFolderPath "python.exe"

    if (Test-Path $pythonExe) {
        # La carpeta lleva solo mayor.menor (python-3.12), asi que una version
        # ya instalada tapa a cualquier patch posterior. Se compara el patch real
        # para no dejar al usuario con parches viejos sin enterarse.
        $installed = Get-InstalledPythonVersion -PythonExe $pythonExe

        if ($Force) {
            Write-Log "-Force: se reinstala $($EnvSetup.FolderName) desde cero" "WARN"
            if ($installed) { Write-Log "  habia: $installed  ->  se pondra: $($EnvSetup.FullVersion)" }
            Remove-Item -LiteralPath $pythonFolderPath -Recurse -Force
        }
        elseif ($installed -eq $EnvSetup.FullVersion) {
            Write-Log "Python $installed ya esta instalado y al dia" "SUCCESS"
            return $pythonFolderPath
        }
        elseif ($installed) {
            Write-Log "Ya hay Python $installed instalado en $($EnvSetup.FolderName)" "WARN"
            Write-Log "  Disponible: $($EnvSetup.FullVersion)" "WARN"
            Write-Log "  Para actualizarlo:  .\Setup-PythonEnv.bat -PythonVersion $($EnvSetup.Version) -Force" "WARN"
            Write-Log "  (-Force borra la carpeta y reinstala; perderias los paquetes pip)" "WARN"
            return $pythonFolderPath
        }
        else {
            Write-Log "Hay un python.exe que no arranca en $($EnvSetup.FolderName)" "ERROR"
            Write-Log "  Instalacion corrupta. Reinstala con:  -PythonVersion $($EnvSetup.Version) -Force" "WARN"
            return $null
        }
    }

    $zipPath = Join-Path $EnvSetup.PythonRoot "python-win.zip"
    $tempExtract = Join-Path $EnvSetup.PythonRoot "temp_python"

    # python.org no publica un archivo de checksums junto al zip embeddable
    # (solo firmas GPG/sigstore, que necesitan herramientas extra). Nos apoyamos
    # en HTTPS para la autenticidad y comprobamos la integridad abriendo el zip.
    Write-Log "Descargando Python v$($EnvSetup.FullVersion)..."
    $ok = Invoke-Download -Uri $EnvSetup.DownloadUrl `
                          -OutFile $zipPath `
                          -Description "Python v$($EnvSetup.FullVersion) (embeddable)"
    if (-not $ok) {
        Write-Log "Sugerencia: comprueba que la version $($EnvSetup.FullVersion) exista en python.org/ftp/python" "WARN"
        return $null
    }

    if (-not (Test-ZipIntegrity -ZipPath $zipPath)) {
        Write-Log "El zip de Python llego danado o incompleto" "ERROR"
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        return $null
    }

    Write-Log "Extrayendo..."
    if (Test-Path $tempExtract) {
        Remove-Item $tempExtract -Recurse -Force
    }
    New-Item -ItemType Directory -Path $tempExtract -Force | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $tempExtract -Force

    if (-not (Test-Path $pythonFolderPath)) {
        New-Item -ItemType Directory -Path $pythonFolderPath -Force | Out-Null
    }

    Move-Item -Path "$tempExtract\*" -Destination $pythonFolderPath -Force
    Remove-Item $tempExtract -Recurse -Force
    Remove-Item $zipPath -Force

    Write-Log "Python instalado en $pythonFolderPath" "SUCCESS"

    return $pythonFolderPath
}

function Enable-Pip {
    param([string]$PythonPath)

    # El nombre del ._pth usa solo mayor+menor (ej: python312._pth), nunca el patch.
    $pthFile = Join-Path $PythonPath "python$($EnvSetup.MinorTag)._pth"

    if (-not (Test-Path $pthFile)) {
        Write-Log "No se encontro $pthFile (zip embeddable inesperado)" "WARN"
        return
    }

    $lines = Get-Content $pthFile

    # 1) Habilitar site (necesario para que pip y sus scripts funcionen)
    $lines = $lines | ForEach-Object { $_ -replace '^\s*#\s*import site\s*$', 'import site' }

    # 2) Exponer Lib\site-packages para que los paquetes instalados sean importables.
    #    El embeddable no lo incluye por defecto.
    if ($lines -notcontains 'Lib\site-packages') {
        $lines += 'Lib\site-packages'
    }
    if ($lines -notcontains 'import site') {
        $lines += 'import site'
    }

    Set-Content -Path $pthFile -Value $lines -Encoding ASCII
    Write-Log "Archivo ._pth configurado (site + site-packages)" "SUCCESS"
}

function Install-Pip {
    param([string]$PythonPath)

    $pythonExe = Join-Path $PythonPath "python.exe"

    # Si pip ya responde, no hacemos nada. En una instalacion nueva escribe
    # "No module named pip" en stderr, por eso va con Invoke-NativeCommand.
    $probe = Invoke-NativeCommand -FilePath $pythonExe -Arguments @('-m', 'pip', '--version') -Quiet
    if ($probe.ExitCode -eq 0) {
        Write-Log "pip ya esta disponible" "SUCCESS"
        return $true
    }

    # El zip embeddable no trae pip: hay que arrancarlo con get-pip.py.
    $getPip = Join-Path $PythonPath "get-pip.py"

    Write-Log "Descargando get-pip.py..."
    if (-not (Invoke-Download -Uri $EnvSetup.GetPipUrl -OutFile $getPip -Description "get-pip.py")) {
        return $false
    }

    Write-Log "Instalando pip..."

    # get-pip.py NO instala el pip que lleva embebido: lo usa solo para poder
    # ejecutarse, y el paquete lo BAJA de PyPI (junto a setuptools y wheel). Asi
    # que detras de un proxy corporativo hay que decirselo, o este paso falla y el
    # Python recien instalado se queda sin pip.
    #
    # Va por PIP_PROXY, igual que en Install-Packages y por el mismo motivo: con
    # --proxy la clave acabaria en la linea de comandos del proceso.
    #
    # Verificado con un venv --without-pip y la cache desactivada: con PIP_PROXY
    # apuntando a un puerto cerrado, get-pip.py falla. Ojo al comprobarlo a mano,
    # que con la cache de pip caliente la instalacion sale bien sin tocar la red
    # y parece que el proxy no se usa.
    $proxy = Resolve-DownloadProxy -Uri ([Uri]"https://pypi.org")
    $previousPipProxy = $env:PIP_PROXY
    if ($proxy) {
        Write-Log "  Usando proxy para pip: $(Format-ProxyForDisplay $proxy)"
        $env:PIP_PROXY = $proxy
    }

    try {
        $run = Invoke-NativeCommand -FilePath $pythonExe -Arguments @($getPip, '--no-warn-script-location')
    }
    finally {
        if ($proxy) { Restore-EnvVar -Name 'PIP_PROXY' -Value $previousPipProxy }
    }
    $ok = ($run.ExitCode -eq 0)

    Remove-Item $getPip -Force -ErrorAction SilentlyContinue

    if ($ok) {
        Write-Log "pip instalado" "SUCCESS"
    }
    else {
        Write-Log "get-pip.py fallo (codigo $($run.ExitCode))" "ERROR"
        Write-Log "  get-pip.py descarga pip de PyPI, asi que este paso necesita red." "WARN"
        if (-not $proxy) {
            Write-Log "  Si sales a internet por proxy, declaralo:  `$env:HTTPS_PROXY = ..." "WARN"
        }
    }

    return $ok
}

function Install-Packages {
    param(
        [string]$PythonPath,
        [string]$Packages
    )

    if ([string]::IsNullOrWhiteSpace($Packages)) {
        return
    }

    $pythonExe = Join-Path $PythonPath "python.exe"

    # Verifica que pip realmente exista antes de intentar instalar.
    $probe = Invoke-NativeCommand -FilePath $pythonExe -Arguments @('-m', 'pip', '--version') -Quiet
    if ($probe.ExitCode -ne 0) {
        Write-Log "pip no esta disponible; se omite la instalacion de paquetes" "ERROR"
        return
    }

    Write-Log "Instalando paquetes: $Packages"

    # pip no lee $env:HTTPS_PROXY en todas las versiones de Windows, asi que hay
    # que decirselo explicitamente. Se hace con PIP_PROXY y no con --proxy:
    #
    #   - PIP_PROXY es el mecanismo propio de pip (toda opcion larga tiene su
    #     PIP_<OPCION>), asi que es tan fiable como el argumento. No es el
    #     HTTPS_PROXY generico que interpreta requests, que es el que no siempre
    #     se respeta y el motivo de que exista este bloque.
    #   - Con --proxy la clave quedaba en la linea de comandos del proceso, y esa
    #     la lee cualquier proceso del equipo (Win32_Process, Administrador de
    #     tareas). El bloque de entorno de un proceso ajeno no se lee sin permiso
    #     para abrir su memoria.
    #
    # Verificado con pip 22.3: apuntando PIP_PROXY a un puerto cerrado la descarga
    # falla, y sin el funciona. Es decir, se honra de verdad.
    $proxy = Resolve-DownloadProxy -Uri ([Uri]"https://pypi.org")
    $previousPipProxy = $env:PIP_PROXY
    if ($proxy) {
        Write-Log "  Usando proxy para pip: $(Format-ProxyForDisplay $proxy)"
        $env:PIP_PROXY = $proxy
    }

    $packageList = $Packages -split ","
    $failed = @()

    try {
        foreach ($pkg in $packageList) {
            $pkg = $pkg.Trim()
            if ($pkg) {
                Write-Log "  Instalando: $pkg"
                # Ojo: no llamar a esta variable $args, que es una automatica de
                # PowerShell dentro de una funcion.
                $pipArgs = @('-m', 'pip', 'install', $pkg,
                             '--disable-pip-version-check', '--no-warn-script-location')
                $run = Invoke-NativeCommand -FilePath $pythonExe -Arguments $pipArgs
                if ($run.ExitCode -ne 0) {
                    Write-Log "  Fallo al instalar: $pkg" "ERROR"
                    $failed += $pkg
                }
            }
        }
    }
    finally {
        # Restore-EnvVar y no una asignacion directa: si PIP_PROXY no estaba
        # definida hay que ELIMINARLA, no dejarla vacia. Para pip no es lo mismo.
        if ($proxy) { Restore-EnvVar -Name 'PIP_PROXY' -Value $previousPipProxy }
    }

    if ($failed.Count -eq 0) {
        Write-Log "Paquetes instalados" "SUCCESS"
    }
    else {
        Write-Log "Paquetes con error: $($failed -join ', ')" "WARN"
    }
}

Write-Log "Version a instalar: $($EnvSetup.FullVersion)" "INFO"
Write-Log "Carpeta destino:    $($EnvSetup.PythonRoot)" "INFO"
Write-Log ""

Initialize-PythonDirectories | Out-Null

$pythonPath = Get-PythonPortable
if (-not $pythonPath) { exit 1 }

Enable-Pip -PythonPath $pythonPath
$pipReady = Install-Pip -PythonPath $pythonPath

if (-not [string]::IsNullOrWhiteSpace($InstallPackages)) {
    if ($pipReady) {
        Install-Packages -PythonPath $pythonPath -Packages $InstallPackages
    }
    else {
        Write-Log "No se instalan paquetes porque pip no quedo disponible" "ERROR"
    }
}

Show-PathConflicts -Root $EnvSetup.PythonRoot -Keep $pythonPath -Label "Python"
Add-UserPathEntry -Path @($pythonPath, (Join-Path $pythonPath "Scripts"))

Write-PythonShell -PythonPath $pythonPath -Version $EnvSetup.Version | Out-Null
Write-Log "Shell creado: $pythonPath\py$($EnvSetup.MinorTag)-shell.bat" "SUCCESS"

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  CONFIGURACION COMPLETADA" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Estructura creada:" -ForegroundColor Yellow
Write-Host "  $($EnvSetup.PythonRoot)"
Write-Host "  +-- $($EnvSetup.FolderName)\"
Write-Host "      +-- python.exe"
Write-Host "      +-- Scripts\"
Write-Host "      +-- py$($EnvSetup.Version -replace '\.', '')-shell.bat"
Write-Host ""
Write-Host "PATH actualizado." -ForegroundColor Green
Write-Host ""
Write-Host "Para comenzar:" -ForegroundColor Yellow
Write-Host "  Usa el shell: ..\Python\$($EnvSetup.FolderName)\py$($EnvSetup.Version -replace '\.', '')-shell.bat" -ForegroundColor White
Write-Host "  O copia el shell a tu escritorio para acceso rapido." -ForegroundColor Gray
Write-Host ""
