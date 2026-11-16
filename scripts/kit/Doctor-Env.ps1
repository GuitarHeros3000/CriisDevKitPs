#Requires -Version 5.1
<#
.SYNOPSIS
    Doctor-Env.ps1 - Diagnostico del entorno de desarrollo sin admin.
.DESCRIPTION
    Responde de un vistazo: que hay instalado, si el PATH esta sano, si se llega
    a internet (y por que proxy), y que herramientas opcionales faltan.
    Es lo primero que conviene ejecutar cuando algo falla o al llegar a un equipo
    nuevo. No modifica nada: solo lee.
.PARAMETER SkipNetwork
    Omite las pruebas de conectividad (util sin red o para ir mas rapido).
.PARAMETER Fix
    Repara lo que se pueda arreglar sin descargar nada: shells que faltan,
    ._pth sin parchear, entradas muertas o duplicadas del PATH y JAVA_HOME
    apuntando a una carpeta borrada. SIN este parametro, Doctor no toca nada.
.PARAMETER Force
    Con -Fix, no pide confirmacion.
.PARAMETER Lock
    Compara lo instalado contra ese devenv.lock.json y senala los desvios. Sin
    este parametro se busca uno en la carpeta actual; si no hay, no se dice nada.
.PARAMETER Report
    Ademas de mostrarlo, guarda el diagnostico en un archivo markdown listo para
    adjuntar a un ticket. La clave del proxy va enmascarada, como en pantalla.
.PARAMETER ReportPath
    Donde guardarlo. Por defecto, junto a los registros, en
    %LOCALAPPDATA%\CriisDevKit\informes.
.PARAMETER Json
    Guarda el mismo diagnostico como JSON, para leerlo con otra herramienta:
    comprobar el entorno en un pipeline, o juntar los informes de varias
    maquinas. -Report es para que lo lea una persona; esto, para que no.
    El codigo de salida sigue siendo 1 si hay algo grave, asi que en un
    pipeline se puede fallar por el codigo y mirar el JSON solo si falla.
.PARAMETER JsonPath
    Donde guardarlo. Por defecto, junto a los informes.
.EXAMPLE
    .\Doctor-Env.ps1
.EXAMPLE
    .\Doctor-Env.ps1 -Fix
.EXAMPLE
    .\Doctor-Env.ps1 -Fix -SkipUseEnv
.EXAMPLE
    .\Doctor-Env.ps1 -Report
.EXAMPLE
    .\Doctor-Env.ps1 -Report -ReportPath D:\ticket-4821.md
.EXAMPLE
    .\Doctor-Env.ps1 -Json -JsonPath D:\equipo.json
#>

param(
    [switch]$SkipNetwork,

    [switch]$Fix,

    # Deja fuera la unica reparacion que sale de las carpetas del kit: activar
    # Use-Env, que se engancha al perfil de PowerShell y al AutoRun de cmd.
    [switch]$SkipUseEnv,

    [switch]$Force,

    [switch]$Report,

    [string]$ReportPath,

    [switch]$Json,

    [string]$JsonPath,

    [string]$Lock
)

$ProgressPreference = "SilentlyContinue"

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Common.ps1")

# Las comprobaciones y la salida viven en lib\Doctor.ps1 (ver su cabecera).
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Doctor.ps1")

# --------------------------------------------------------------------------

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Doctor-Env - Diagnostico del entorno" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

Test-KitIntegrity
Test-Host
Test-Network
Test-AngularInstall
Test-PythonInstall
Test-JavaInstall
Test-NodeInstall
Test-GitInstall
Test-BuildToolInstall -Titulo "Maven" -Root $MavenRoot -Prefijo 'maven' `
                      -ExeRel 'bin\mvn.cmd' -ShellPrefijo 'mvn' `
                      -JarGlob 'lib\maven-core-*.jar' -JarRegex 'maven-core-([\d.]+)\.jar' `
                      -SetupBat '.\bin\setup\Setup-MavenEnv.bat'
Test-BuildToolInstall -Titulo "Gradle" -Root $GradleRoot -Prefijo 'gradle' `
                      -ExeRel 'bin\gradle.bat' -ShellPrefijo 'gradle' `
                      -JarGlob 'lib\gradle-launcher-*.jar' -JarRegex 'gradle-launcher-([\d.]+)\.jar' `
                      -SetupBat '.\bin\setup\Setup-GradleEnv.bat'
Test-DotnetInstall
Test-VSCodeInstall
Test-VSCodeJavaRuntimes
Test-CorpNet
Test-InstalledSignatures
Test-LockDrift
Test-PortableApps
Test-VCRuntimes
Test-UserPath
Test-PathConflicts

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
if ($script:Problems -eq 0 -and $script:Warnings -eq 0) {
    Write-Host "  Todo correcto." -ForegroundColor Green
}
elseif ($script:Problems -eq 0) {
    Write-Host "  $($script:Warnings) aviso(s), ningun problema grave." -ForegroundColor Yellow
}
else {
    Write-Host "  $($script:Problems) problema(s) y $($script:Warnings) aviso(s)." -ForegroundColor Red
}
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""


if ($Report) {
    $archivo = Save-DoctorReport -Destino $ReportPath
    if ($archivo) {
        Write-Host "Informe guardado en:" -ForegroundColor Green
        Write-Host "  $archivo"
        Write-Host ""
        Write-Host "Se puede adjuntar tal cual a un ticket: la clave del proxy va enmascarada." -ForegroundColor Gray
        Write-Host ""
    }
}

if ($Json) {
    $archivoJson = Save-DoctorJson -Destino $JsonPath
    if ($archivoJson) {
        Write-Host "JSON guardado en:" -ForegroundColor Green
        Write-Host "  $archivoJson"
        Write-Host ""
    }
}

# --------------------------------------------------------------------------
# Reparaciones
# --------------------------------------------------------------------------

if ($script:Fixes.Count -eq 0) {
    if ($Fix) {
        Write-Host "No hay nada reparable automaticamente." -ForegroundColor Gray
        Write-Host "Lo que quede arriba necesita reinstalar o decidirlo tu." -ForegroundColor Gray
        Write-Host ""
    }
    if ($script:Problems -gt 0) { exit 1 }
    exit 0
}

# -SkipUseEnv deja fuera lo unico que sale de las carpetas del kit. Existe
# porque -Force se salta el aviso de mas abajo, y entonces "arreglame los
# archivos" y "engancha algo a mi perfil" iban en el mismo paquete.
$aplicables = @($script:Fixes | Where-Object { -not ($SkipUseEnv -and $_.TocaPerfil) })
$omitidas   = @($script:Fixes | Where-Object { $SkipUseEnv -and $_.TocaPerfil })

Write-Host "Reparable automaticamente ($($aplicables.Count)):" -ForegroundColor Yellow
foreach ($f in $aplicables) { Write-Host "  - $($f.Description)" }
foreach ($f in $omitidas)   { Write-Host "  - $($f.Description)" -ForegroundColor DarkGray }
if ($omitidas.Count -gt 0) {
    Write-Host "    (en gris: fuera por -SkipUseEnv)" -ForegroundColor DarkGray
}
Write-Host ""

if (-not $Fix) {
    Write-Host "Para arreglarlo:  .\bin\kit\Doctor-Env.bat -Fix" -ForegroundColor Cyan
    if (@($script:Fixes | Where-Object { $_.TocaPerfil }).Count -gt 0 -and -not $SkipUseEnv) {
        Write-Host "Sin tocar tu perfil:  .\bin\kit\Doctor-Env.bat -Fix -SkipUseEnv" -ForegroundColor Cyan
    }
    Write-Host ""
    if ($script:Problems -gt 0) { exit 1 }
    exit 0
}

if ($aplicables.Count -eq 0) {
    Write-Host "Con -SkipUseEnv no queda nada que aplicar." -ForegroundColor Gray
    Write-Host ""
    if ($script:Problems -gt 0) { exit 1 }
    exit 0
}

if (-not $Force) {
    Write-Host "Se modificara tu PATH de usuario y/o archivos del kit." -ForegroundColor Yellow
    Write-Host "Cada cambio del PATH deja copia en %LOCALAPPDATA%\CriisDevKit." -ForegroundColor Gray
    if ($script:HayFixUseEnv -and -not $SkipUseEnv) {
        Write-Host ""
        Write-Host "ADEMAS, activar Use-Env toca dos cosas de tu perfil de usuario:" -ForegroundColor Yellow
        Write-Host "  1. $($PROFILE.CurrentUserAllHosts)" -ForegroundColor Gray
        Write-Host "  2. HKCU\Software\Microsoft\Command Processor  (valor AutoRun)" -ForegroundColor Gray
        Write-Host "Nunca del sistema, y se revierte con:  .\bin\env\Use-Env.bat -Off" -ForegroundColor Gray
        Write-Host "Para dejarlo fuera:  -SkipUseEnv" -ForegroundColor Gray
    }
    Write-Host ""
    $answer = Read-Host "Confirmas? (escribe SI)"
    if ($answer -ne 'SI') {
        Write-Host "Cancelado. No se ha tocado nada." -ForegroundColor Yellow
        exit 0
    }
    Write-Host ""
}

$hechas = 0
$fallidas = 0
foreach ($f in $aplicables) {
    try {
        $fixArgs = $f.Arguments
        & $f.Action @fixArgs
        Write-Log $f.Description "SUCCESS"
        $hechas++
    }
    catch {
        Write-Log "fallo: $($f.Description)" "ERROR"
        Write-Log "  $($_.Exception.Message)" "ERROR"
        $fallidas++
    }
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  $hechas reparada(s), $fallidas con error" -ForegroundColor $(if ($fallidas -eq 0) { 'Cyan' } else { 'Red' })
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Vuelve a ejecutar .\bin\kit\Doctor-Env.bat para comprobar." -ForegroundColor Gray
Write-Host ""

if ($fallidas -gt 0) { exit 1 }
exit 0
