#Requires -Version 5.1
<#
.SYNOPSIS
    Start-AndroidApp.ps1 - Compila una app de Android y la abre en el telefono virtual.
.DESCRIPTION
    Todo de una vez, desde la carpeta del proyecto:

      1. Lee el proyecto: con que version del plugin de Android (AGP) se
         compila, y de ahi que JDK, plataforma y build-tools pide.
      2. Si en este equipo falta algo de eso, o el emulador y su telefono, lo
         instala (Setup-AndroidEnv). Solo la primera vez: las siguientes no
         descarga nada, ni lee nada de internet.
      3. Compila (gradlew assembleDebug), sin el ruido que sueltan los
         proyectos antiguos y sin daemon de Gradle, que es lo que hacia saltar
         el aviso del firewall.
      4. Arranca el telefono, o reutiliza el que ya este abierto, instala la
         app y la abre.

    Se acuerda del proyecto: la siguiente vez basta con ejecutarlo sin nada.
    El ciclo de trabajo es cambiar el codigo y volver a ejecutar esto.
.PARAMETER Path
    La carpeta del proyecto (la que tiene gradlew.bat). Por defecto, la de la
    ultima vez.
.PARAMETER Api
    La version de Android del telefono. Por defecto 26 (Android 8), o la
    minima de la app si pide una mas alta.
.PARAMETER SoloCompilar
    Compila y dice donde esta la app, sin el telefono.
.EXAMPLE
    .\Start-AndroidApp.ps1 -Path C:\proyectos\mi-app
.EXAMPLE
    .\Start-AndroidApp.ps1
#>

param(
    [string]$Path,

    [string]$Api,

    [switch]$SoloCompilar
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Common.ps1")
# El SDK de Android y lo que lee el proyecto (ver sus cabeceras: no los carga Common).
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Android.ps1")
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Project.ps1")

Write-Log "========================================" "INFO"
Write-Log "  Compilar y probar una app de Android" "INFO"
Write-Log "========================================" "INFO"

if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Get-AndroidLastProject }
if ([string]::IsNullOrWhiteSpace($Path)) {
    Write-Log "Dime la carpeta del proyecto:  .\bin\start\Start-AndroidApp.bat -Path C:\ruta\del\proyecto" "ERROR"
    exit 1
}
$Path = $Path.Trim().Trim('"')
if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Write-Log "No existe la carpeta: $Path" "ERROR"; exit 1 }
$Path = (Resolve-Path -LiteralPath $Path).ProviderPath

$info = Get-AndroidProjectInfo -Ruta $Path
if (-not $info) {
    Write-Log "No parece un proyecto de Android: no encuentro un build.gradle con el plugin com.android.application." "ERROR"
    Write-Log "  Es la carpeta que tiene gradlew.bat y settings.gradle." "WARN"
    exit 1
}

# Android 8 (API 26) es el minimo con el que se trabaja; si la app pide uno
# mas alto, el telefono tiene que ser ese o no la podria instalar.
if (-not $Api) { $Api = if ($info.MinSdk -and [int]$info.MinSdk -gt 26) { $info.MinSdk } else { '26' } }

$plan = Get-AndroidAppPlan -Info $info -Api $Api -SoloCompilar:$SoloCompilar
Write-Host ""
Write-Host "  Proyecto : $Path" -ForegroundColor White
Write-Host ("  Pide     : {0}JDK {1}, android-{2}{3}" -f $(if ($info.Agp) { "AGP $($info.Agp), " } else { '' }), $plan.JdkMayor, $(if ($info.CompileSdk) { $info.CompileSdk } else { '(la mas reciente)' }), $(if ($plan.BuildTools) { ", build-tools $($plan.BuildTools)" } else { '' })) -ForegroundColor Gray
if (-not $SoloCompilar) { Write-Host "  Telefono : Android API $Api (kit-api$Api)" -ForegroundColor Gray }
Write-Host ""

# --------------------------------------------------------------------------
# 1. Lo que falte, solo la primera vez
# --------------------------------------------------------------------------

if ($plan.Faltan.Count -gt 0) {
    Write-Log "Primera vez con esto: falta $($plan.Faltan -join ', ')." "INFO"
    Write-Log "  Se instala ahora; las siguientes veces ya no." "INFO"
    $global:LASTEXITCODE = 0
    $a = $plan.SetupArgs
    & (Resolve-KitScript -Nombre 'Setup-AndroidEnv.ps1') @a
    if ($LASTEXITCODE -ne 0) { Write-Log "No se pudo instalar lo que falta (arriba esta por que)." "ERROR"; exit 1 }
    $plan = Get-AndroidAppPlan -Info $info -Api $Api -SoloCompilar:$SoloCompilar
}
if (-not $plan.Jdk) { Write-Log "Sigue faltando el JDK $($plan.JdkMayor); sin el no se compila." "ERROR"; exit 1 }

# --------------------------------------------------------------------------
# 2. Compilar
# --------------------------------------------------------------------------

Write-Host ""
Write-Log "Compilando (gradlew assembleDebug, con el JDK $($plan.JdkMayor))..."
if (-not (Test-Path -LiteralPath (Join-Path $Path 'build')) -and -not (Test-Path -LiteralPath (Join-Path $Path 'app\build'))) {
    Write-Log "  La primera vez Gradle baja su version y las librerias del proyecto: unos minutos, a ratos sin escribir nada." "INFO"
}
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Invoke-AndroidBuild -Proyecto $Path -Jdk $plan.Jdk
if (-not $r) { Write-Log "El proyecto no trae gradlew.bat, y es lo que fija su version de Gradle." "ERROR"; exit 1 }
if (-not $r.Ok) {
    Write-Log "No compilo (codigo $($r.Codigo)). Arriba, tras 'What went wrong', esta el motivo." "ERROR"
    exit 1
}
Set-AndroidLastProject -Ruta $Path

$modulo = Split-Path -Parent $info.Fuente
$apk = Get-AndroidBuiltApk -Proyecto $Path -Modulo $modulo
if (-not $apk) { Write-Log "Compilo, pero no encuentro la app (.apk) en $modulo\build\outputs\apk." "ERROR"; exit 1 }
Write-Log ("Compilada en {0:N0} s: {1}" -f $sw.Elapsed.TotalSeconds, $apk.FullName) "SUCCESS"

if ($SoloCompilar) { exit 0 }

# --------------------------------------------------------------------------
# 3. Al telefono
# --------------------------------------------------------------------------

if ($plan.Faltan.Count -gt 0) {
    Write-Log "El telefono no esta listo ($($plan.Faltan -join ', ')): la app esta compilada, pero no se puede abrir." "WARN"
    exit 1
}
Write-Host ""
$global:LASTEXITCODE = 0
& (Resolve-KitScript -Nombre 'Start-AndroidEmulator.ps1') -Avd "kit-api$Api" -Apk $apk.FullName
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ""
Write-Host "Para probar otra version: cambia el codigo y vuelve a ejecutar esto (Menu.bat, opcion 60)." -ForegroundColor Cyan
Write-Host "El telefono se queda abierto, asi que la proxima vez solo compila e instala." -ForegroundColor Gray
exit 0
