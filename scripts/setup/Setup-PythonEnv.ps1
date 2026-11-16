#Requires -Version 5.1
<#
.SYNOPSIS
    Setup-PythonEnv.ps1 - Configura entorno Python sin permisos de administrador
.DESCRIPTION
    Instala CPython completo y portable, de python-build-standalone: con venv,
    tkinter y pip, sin instalador ni registro. La estructura se crea en una
    carpeta 'Python' junto a la raiz del kit, una por linea (python-3.12).

    Antes era el zip "embeddable" de python.org, que no trae venv ni tkinter
    (ver el comentario de lib\Catalog.ps1). Una instalacion vieja asi se
    detecta, y se cambia por la completa con -Force.
.PARAMETER PythonVersion
    Version de Python a instalar: una linea (3.12, la ultima 3.12.x) o una
    version exacta (3.12.10).
.PARAMETER InstallPackages
    Paquetes pip a instalar separados por coma (ej: django,flask)
.PARAMETER Force
    Reinstala aunque ya exista esa version menor. Necesario para actualizar el
    patch (3.12.9 -> 3.12.10), porque la carpeta se llama solo python-3.12, y
    para cambiar un Python embeddable por el completo.
    Borra la carpeta: se pierden los paquetes pip instalados ahi.
.PARAMETER WhatIf
    Muestra el plan y no toca nada. Resuelve la version por red (solo lectura),
    asi que dice la version EXACTA que se instalaria antes de bajar nada.
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

    [switch]$Force,

    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Common.ps1")

$PythonRoot = Join-Path $WorkspaceRoot "Python"

# El SHA-256 del archivo instalado, ya comprobado contra SHA256SUMS, y de donde
# salio. Doctor y Verify-Env los leen.
$ShaMarker    = ".criisdevkit-sha256"
$OrigenMarker = ".criisdevkit-origen"

function Resolve-PythonBuild {
    <#
        Convierte "3.12" en la ultima 3.12.x de python-build-standalone, o
        encuentra "3.12.10" exacta. Devuelve $null si no se pudo, despues de
        explicar por que. El exit vive en el cuerpo del script, no aqui: asi se
        puede probar y reutilizar.
    #>
    param([string]$Requested)

    $r = $Requested.Trim()
    if ($r -notmatch '^\d+\.\d+(\.\d+)?$') {
        Write-Log "Version no valida: $Requested. Usa una linea (3.12) o una version exacta (3.12.10)." "ERROR"
        return $null
    }

    if ($r -match '^\d+\.\d+$') { Write-Log "Buscando la ultima $r.x..." }
    else { Write-Log "Buscando Python $r..." }

    $build = Find-PythonBuild -Requested $r
    if (-not $build) {
        Write-Log "No se encontro Python $r en python-build-standalone." "ERROR"
        Write-Log "  Puede que no haya red hasta github.com, o que esa version no exista" "WARN"
        Write-Log "  para Windows (las lineas muy viejas dejan de publicarse)." "WARN"
        Write-Log "  Diagnostico de la red:  .\bin\kit\Doctor-Env.bat" "WARN"
        return $null
    }

    Write-Log "  Elegida: $($build.Version) (build $($build.Tag))" "SUCCESS"
    return $build
}

Write-Log "========================================" "INFO"
Write-Log "  Python Environment Setup" "INFO"
Write-Log "========================================" "INFO"
Write-Log ""

$build = Resolve-PythonBuild -Requested $PythonVersion
if (-not $build) { exit 1 }

$EnvSetup = @{
    PythonRoot  = $PythonRoot
    Version     = $build.Linea
    FullVersion = $build.Version
    MinorTag    = $build.Linea -replace '\.', ''
    FolderName  = "python-$($build.Linea)"
    Build       = $build
}

function Get-InstalledPythonVersion {
    param([string]$PythonExe)

    $run = Invoke-NativeCommand -FilePath $PythonExe -Arguments @('--version') -Quiet
    if ($run.ExitCode -ne 0) { return $null }
    if ($run.Output -match '(\d+\.\d+\.\d+)') { return $Matches[1] }
    return $null
}

function Test-PythonEmbeddable {
    <# El embeddable de python.org es el unico que trae un ._pth en la raiz. #>
    param([string]$PythonPath)
    return [bool](Get-ChildItem -LiteralPath $PythonPath -Filter 'python*._pth' -File -ErrorAction SilentlyContinue)
}

function Get-PythonPortable {
    $pythonFolderPath = Join-Path $EnvSetup.PythonRoot $EnvSetup.FolderName
    $pythonExe = Join-Path $pythonFolderPath "python.exe"

    if (Test-Path $pythonExe) {
        # La carpeta lleva solo mayor.menor (python-3.12), asi que una version
        # ya instalada tapa a cualquier patch posterior. Se compara el patch real
        # para no dejar al usuario con parches viejos sin enterarse.
        $installed = Get-InstalledPythonVersion -PythonExe $pythonExe
        $embeddable = Test-PythonEmbeddable -PythonPath $pythonFolderPath

        if ($Force) {
            Write-Log "-Force: se reinstala $($EnvSetup.FolderName) desde cero" "WARN"
            if ($installed) { Write-Log "  habia: $installed  ->  se pondra: $($EnvSetup.FullVersion)" }
            Remove-Item -LiteralPath $pythonFolderPath -Recurse -Force
        }
        elseif ($embeddable) {
            Write-Log "Ya hay Python $installed en $($EnvSetup.FolderName), pero es el EMBEDDABLE de python.org:" "WARN"
            Write-Log "  no trae venv ni tkinter, asi que 'python -m venv' falla." "WARN"
            Write-Log "  Para cambiarlo por el completo:  .\bin\setup\Setup-PythonEnv.bat -PythonVersion $($EnvSetup.Version) -Force" "WARN"
            Write-Log "  (-Force borra la carpeta; anota antes tus paquetes con:  pip freeze > requirements.txt)" "WARN"
            return $pythonFolderPath
        }
        elseif ($installed -eq $EnvSetup.FullVersion) {
            Write-Log "Python $installed ya esta instalado y al dia" "SUCCESS"
            return $pythonFolderPath
        }
        elseif ($installed) {
            Write-Log "Ya hay Python $installed instalado en $($EnvSetup.FolderName)" "WARN"
            Write-Log "  Disponible: $($EnvSetup.FullVersion)" "WARN"
            Write-Log "  Para actualizarlo:  .\bin\setup\Setup-PythonEnv.bat -PythonVersion $($EnvSetup.Version) -Force" "WARN"
            Write-Log "  (-Force borra la carpeta y reinstala; perderias los paquetes pip)" "WARN"
            return $pythonFolderPath
        }
        else {
            Write-Log "Hay un python.exe que no arranca en $($EnvSetup.FolderName)" "ERROR"
            Write-Log "  Instalacion corrupta. Reinstala con:  -PythonVersion $($EnvSetup.Version) -Force" "WARN"
            return $null
        }
    }

    if (-not (Test-Path -LiteralPath $EnvSetup.PythonRoot)) {
        New-Item -ItemType Directory -Path $EnvSetup.PythonRoot -Force | Out-Null
    }

    $b = $EnvSetup.Build
    $archivo = Join-Path $EnvSetup.PythonRoot $b.FileName

    Write-Log "Descargando Python $($b.Version)..."
    $ok = Invoke-Download -Uri $b.Url -OutFile $archivo -Sha256 $b.Sha256 `
                          -Description "Python $($b.Version) (python-build-standalone)"
    if (-not $ok) { return $null }

    Write-Log "Extrayendo (son unos 3.500 archivos)..."
    try {
        Expand-TarArchive -Path $archivo -Destino $pythonFolderPath -QuitarEnvoltorio
    }
    catch {
        Write-Log "No se pudo extraer: $($_.Exception.Message)" "ERROR"
        return $null
    }
    finally {
        Remove-Item -LiteralPath $archivo -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path -LiteralPath $pythonExe)) {
        Write-Log "Tras extraer no hay python.exe en $pythonFolderPath" "ERROR"
        return $null
    }

    Set-Content -LiteralPath (Join-Path $pythonFolderPath $ShaMarker) -Value $b.Sha256 -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $pythonFolderPath $OrigenMarker) -Value "python-build-standalone $($b.Tag)" -Encoding ASCII

    Write-Log "Python instalado en $pythonFolderPath" "SUCCESS"
    Write-Log "  SHA-256 comprobado: $($b.Sha256)"

    return $pythonFolderPath
}

function Test-Pip {
    <#
        python-build-standalone ya trae pip. Si faltara (alguien lo desinstalo),
        se repone con ensurepip, que va DENTRO de Python y no necesita red.
    #>
    param([string]$PythonPath)

    $pythonExe = Join-Path $PythonPath "python.exe"

    # En una instalacion sin pip escribe "No module named pip" en stderr, por
    # eso va con Invoke-NativeCommand.
    $probe = Invoke-NativeCommand -FilePath $pythonExe -Arguments @('-m', 'pip', '--version') -Quiet
    if ($probe.ExitCode -eq 0) {
        Write-Log "pip disponible" "SUCCESS"
        return $true
    }

    if (Test-PythonEmbeddable -PythonPath $PythonPath) {
        Write-Log "Este Python es el embeddable y no trae pip. Reinstala con -Force para tener el completo." "ERROR"
        return $false
    }

    Write-Log "Falta pip; se repone con ensurepip (sin red)..."
    $run = Invoke-NativeCommand -FilePath $pythonExe -Arguments @('-m', 'ensurepip', '--default-pip') -Quiet
    if ($run.ExitCode -eq 0) {
        Write-Log "pip repuesto" "SUCCESS"
        return $true
    }
    Write-Log "ensurepip fallo (codigo $($run.ExitCode))" "ERROR"
    return $false
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

if ($WhatIf) {
    # El plan se imprime DESPUES de resolver la version por red (solo lectura) y
    # ANTES de crear ninguna carpeta: lo que interesa saber antes de bajar 45 MB
    # por un proxy lento es que version exacta va a caer y donde.
    $destino = Join-Path $EnvSetup.PythonRoot $EnvSetup.FolderName
    $exe = Join-Path $destino "python.exe"
    $yaHay = if (Test-Path $exe) { Get-InstalledPythonVersion -PythonExe $exe } else { $null }

    Write-Host ""
    Write-Host "Se va a instalar:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host ("  [version]  Python {0}  (completo: venv, tkinter y pip)" -f $EnvSetup.FullVersion)
    Write-Host ("  [descarga] {0}" -f $EnvSetup.Build.Url) -ForegroundColor DarkGray
    Write-Host ("  [sha-256]  {0}" -f $EnvSetup.Build.Sha256) -ForegroundColor DarkGray
    Write-Host ("  [carpeta]  {0}" -f $destino)
    if ($yaHay) {
        if ($Force) {
            Write-Host ("             -Force BORRARIA la actual ({0}) y con ella sus paquetes pip" -f $yaHay) -ForegroundColor Red
        }
        elseif (Test-PythonEmbeddable -PythonPath $destino) {
            Write-Host ("             ya hay {0}, pero embeddable; sin -Force no se tocaria" -f $yaHay) -ForegroundColor Yellow
        }
        elseif ($yaHay -eq $EnvSetup.FullVersion) {
            Write-Host ("             ya esta instalada esa misma version: no se descargaria nada") -ForegroundColor Green
        }
        else {
            Write-Host ("             ya hay {0}; sin -Force no se tocaria" -f $yaHay) -ForegroundColor Yellow
        }
    }
    Write-Host ("  [PATH]     {0}" -f $destino)
    Write-Host ("  [PATH]     {0}" -f (Join-Path $destino "Scripts"))
    Write-Host ("  [shell]    py{0}-shell.bat" -f $EnvSetup.MinorTag)
    if (-not [string]::IsNullOrWhiteSpace($InstallPackages)) {
        Write-Host ("  [pip]      {0}" -f (($InstallPackages -split ',' | ForEach-Object { $_.Trim() }) -join ', '))
    }
    Write-Host ""
    Write-Host "-WhatIf: no se ha tocado nada." -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

$pythonPath = Get-PythonPortable
if (-not $pythonPath) { exit 1 }

$scripts = Join-Path $pythonPath "Scripts"
if (-not (Test-Path -LiteralPath $scripts)) { New-Item -ItemType Directory -Path $scripts -Force | Out-Null }

$pipReady = Test-Pip -PythonPath $pythonPath

if (-not [string]::IsNullOrWhiteSpace($InstallPackages)) {
    if ($pipReady) {
        Install-Packages -PythonPath $pythonPath -Packages $InstallPackages
    }
    else {
        Write-Log "No se instalan paquetes porque pip no quedo disponible" "ERROR"
    }
}

Show-PathConflicts -Root $EnvSetup.PythonRoot -Keep $pythonPath -Label "Python"
Add-UserPathEntry -Path @($pythonPath, $scripts)

Write-PythonShell -PythonPath $pythonPath -Version $EnvSetup.Version | Out-Null
Write-Log "Shell creado: $pythonPath\py$($EnvSetup.MinorTag)-shell.bat" "SUCCESS"
# La CA de la empresa y el proxy, si los hay guardados. Una herramienta recien
# instalada nace sin ellos y falla con un error de certificado o de red que no
# menciona nada de esto.
foreach ($linea in @(Sync-CorpNet)) { Write-Log $linea "SUCCESS" }


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
Write-Host "      +-- py$($EnvSetup.MinorTag)-shell.bat"
Write-Host ""
Write-Host "PATH actualizado." -ForegroundColor Green
Write-Host ""
Write-Host "Para comenzar:" -ForegroundColor Yellow
Write-Host "  Usa el shell: ..\Python\$($EnvSetup.FolderName)\py$($EnvSetup.MinorTag)-shell.bat" -ForegroundColor White
Write-Host "  En un proyecto, su propio entorno:  python -m venv .venv" -ForegroundColor White
Write-Host "  O copia el shell a tu escritorio para acceso rapido." -ForegroundColor Gray
Write-Host ""
