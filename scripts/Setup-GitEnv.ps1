#Requires -Version 5.1
<#
.SYNOPSIS
    Setup-GitEnv.ps1 - Instala Git sin permisos de administrador.
.DESCRIPTION
    Git es el caso que dejo sin salida a Install-NoAdmin: su instalador ignora
    /CURRENTUSER, pide admin y se instala para toda la maquina; y tampoco se
    puede extraer, porque usa un Inno Setup mas nuevo del que sabe leer
    innoextract (7-Zip tampoco reconoce el formato).

    La salida es oficial y se llama PortableGit: un 7-Zip autoextraible que Git
    for Windows publica en cada release. No es un instalador. No toca el
    registro, no pide admin y trae Git Bash entero.

    Se verifica el SHA-256 contra el que la propia release publica en su tabla
    "Filename | SHA-256".
.PARAMETER GitVersion
    Version concreta (ej: 2.55.0.5). Si se omite, la ultima publicada.
.PARAMETER Force
    Reinstala aunque ya exista esa linea.
.PARAMETER WhatIf
    Muestra el plan y no toca nada.
.EXAMPLE
    .\Setup-GitEnv.ps1
.EXAMPLE
    .\Setup-GitEnv.ps1 -GitVersion 2.55.0.5 -Force
#>

param(
    [string]$GitVersion,

    [switch]$Force,

    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

$GitRoot = Join-Path $WorkspaceRoot "Git"

Write-Log "========================================" "INFO"
Write-Log "  Git Environment Setup (portable)" "INFO"
Write-Log "========================================" "INFO"
Write-Log ""

function Get-InstalledGitVersion {
    param([string]$GitExe)

    $run = Invoke-NativeCommand -FilePath $GitExe -Arguments @('--version') -Quiet
    if ($run.ExitCode -ne 0) { return $null }
    return (ConvertFrom-GitVersionOutput -Output $run.Output)
}

function Get-GitPortable {
    param([PSCustomObject]$Release, [string]$FolderName)

    $gitPath = Join-Path $GitRoot $FolderName
    $gitExe  = Join-Path $gitPath "cmd\git.exe"

    if (Test-Path $gitExe) {
        $instalada = Get-InstalledGitVersion -GitExe $gitExe

        if ($Force) {
            Write-Log "-Force: se reinstala $FolderName desde cero" "WARN"
            if ($instalada) { Write-Log "  habia: $instalada  ->  se pondra: $($Release.Version)" }
            Remove-Item -LiteralPath $gitPath -Recurse -Force
        }
        elseif ($instalada -eq $Release.Version) {
            Write-Log "Git $instalada ya esta instalado y al dia" "SUCCESS"
            return $gitPath
        }
        elseif ($instalada) {
            Write-Log "Ya hay Git $instalada instalado en $FolderName" "WARN"
            Write-Log "  Disponible: $($Release.Version)" "WARN"
            Write-Log "  Para actualizarlo:  .\Setup-GitEnv.bat -GitVersion $($Release.Version) -Force" "WARN"
            return $gitPath
        }
        else {
            Write-Log "Hay un git.exe que no arranca en $FolderName" "ERROR"
            Write-Log "  Instalacion corrupta. Reinstala con:  -Force" "WARN"
            return $null
        }
    }

    if (-not (Test-Path $GitRoot)) {
        New-Item -ItemType Directory -Path $GitRoot -Force | Out-Null
    }

    $sfx = Join-Path $GitRoot $Release.FileName

    if (-not $Release.Sha256) {
        Write-Log "La release no publica el SHA-256 de $($Release.FileName); se continua sin verificar hash" "WARN"
    }

    Write-Log "Descargando PortableGit $($Release.Version)..."
    Write-Log "  (unos 56 MB)"
    # PortableGit lo firma el mantenedor de Git for Windows. Si algun dia firma
    # otro, conviene enterarse; el kit lo dice y sigue.
    if (-not (Invoke-Download -Uri $Release.Url -OutFile $sfx -Sha256 $Release.Sha256 `
                              -FirmanteEsperado 'Johannes Schindelin' `
                              -Description "PortableGit $($Release.Version)")) {
        return $null
    }

    # El autoextraible acepta -o<destino> -y para descomprimir sin preguntar.
    # Start-Process -Wait y no el operador &: es una aplicacion grafica y
    # PowerShell no espera a esas, devolviendo un codigo de salida vacio.
    Write-Log "Extrayendo (unos 9.500 archivos, tarda medio minuto)..."
    $proc = Start-Process -FilePath $sfx -ArgumentList @("-o`"$gitPath`"", '-y') -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Write-Log "El autoextraible fallo (codigo $($proc.ExitCode))" "ERROR"
        Remove-Item -LiteralPath $sfx -Force -ErrorAction SilentlyContinue
        return $null
    }

    Remove-Item -LiteralPath $sfx -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path $gitExe)) {
        Write-Log "Tras extraer no hay cmd\git.exe en $gitPath" "ERROR"
        return $null
    }

    Invoke-GitPostInstall -GitPath $gitPath | Out-Null

    Write-Log "Git instalado en $gitPath" "SUCCESS"
    return $gitPath
}

# --------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($GitVersion)) {
    Write-Log "Consultando la ultima release de Git for Windows..."
}
else {
    Write-Log "Buscando PortableGit $($GitVersion.TrimStart('v'))..."
}

$release = Get-GitPortableRelease -Version $GitVersion
if (-not $release) {
    Write-Log "No se pudo determinar que PortableGit instalar." "ERROR"
    if ([string]::IsNullOrWhiteSpace($GitVersion)) {
        Write-Log "  No se pudo leer la API de GitHub. Reintenta, o indica la version:" "WARN"
        Write-Log "    .\Setup-GitEnv.bat -GitVersion 2.55.0.5" "WARN"
    }
    else {
        Write-Log "  Esa version no aparece entre las ultimas 30 releases publicadas." "WARN"
        Write-Log "  Ejecutalo sin -GitVersion para coger la mas reciente." "WARN"
    }
    exit 1
}

Write-Log "  Version: $($release.Version)  (release $($release.Tag))" "SUCCESS"

$line       = Get-GitLine -Version $release.Version
$FolderName = "git-$line"
$shellName  = "git$($line -replace '\.','')-shell.bat"

Write-Log "Carpeta destino: $GitRoot" "INFO"
Write-Log ""

if ($WhatIf) {
    $destino = Join-Path $GitRoot $FolderName
    $yaHay = if (Test-Path (Join-Path $destino "cmd\git.exe")) {
        Get-InstalledGitVersion -GitExe (Join-Path $destino "cmd\git.exe")
    } else { $null }

    Write-Host ""
    Write-Host "Se va a instalar:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host ("  [version]  Git {0}" -f $release.Version)
    $hashTxt = if ($release.Sha256) { "SHA-256 verificado" } else { "SIN checksum publicado" }
    Write-Host ("  [descarga] {0}  ({1})" -f $release.Url, $hashTxt) -ForegroundColor DarkGray
    Write-Host ("  [carpeta]  {0}" -f $destino)
    if ($yaHay) {
        if ($Force) { Write-Host ("             -Force BORRARIA la actual ({0})" -f $yaHay) -ForegroundColor Red }
        else        { Write-Host ("             ya hay {0}; sin -Force no se tocaria" -f $yaHay) -ForegroundColor Yellow }
    }
    Write-Host ("  [PATH]     {0}\cmd" -f $destino)
    Write-Host ("  [shell]    {0}" -f $shellName)
    Write-Host ""
    Write-Host "No es un instalador: es el autoextraible oficial PortableGit." -ForegroundColor DarkGray
    Write-Host "No toca el registro ni pide administrador." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "-WhatIf: no se ha tocado nada." -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

$gitPath = Get-GitPortable -Release $release -FolderName $FolderName
if (-not $gitPath) { exit 1 }

Show-PathConflicts -Root $GitRoot -Keep (Join-Path $gitPath "cmd") -Label "Git"

# Solo cmd\, que es lo que pone el instalador oficial por defecto. bin\ trae
# bash, sh y compania, que taparian los comandos del sistema del mismo nombre.
Add-UserPathEntry -Path (Join-Path $gitPath "cmd")

Write-GitShell -GitPath $gitPath -Version $release.Version | Out-Null
Write-Log "Shell creado: $gitPath\$shellName" "SUCCESS"
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
Write-Host "  $GitRoot"
Write-Host "  +-- $FolderName\"
Write-Host "      +-- cmd\git.exe"
Write-Host "      +-- git-bash.exe"
Write-Host "      +-- $shellName"
Write-Host ""
Write-Host "Git $($release.Version) agregado al PATH, sin administrador." -ForegroundColor Green
Write-Host ""
Write-Host "Para comenzar:" -ForegroundColor Yellow
Write-Host "  Usa el shell: ..\Git\$FolderName\$shellName" -ForegroundColor White
Write-Host "  O Git Bash:   ..\Git\$FolderName\git-bash.exe" -ForegroundColor White
Write-Host "  Comprueba con: .\Doctor-Env.bat" -ForegroundColor Gray
Write-Host ""
