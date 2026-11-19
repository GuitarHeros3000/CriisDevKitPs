#Requires -Version 5.1
<#
.SYNOPSIS
    Setup-AndroidEnv.ps1 - El SDK de Android, y si se pide el emulador, sin admin.
.DESCRIPTION
    Sin -Emulador, lo justo para compilar una app: adb (platform-tools), las
    build-tools y una plataforma. Unos 130 MB, sin virtualizacion.

    Con -Emulador, ademas el emulador, una imagen de Android y un telefono
    virtual ajustado para un equipo justo de recursos. Antes de bajar nada
    (son mas de 1 GB) comprueba que Windows deja acelerarlo: sin la
    "Plataforma del hipervisor de Windows" el emulador no arranca, y para
    activarla hace falta admin.

    Todo se baja del indice oficial de Google, contra el SHA-1 que publica para
    cada paquete, con el proxy de la empresa y la cache del kit. El JDK es el
    del kit (17 o superior; si no hay, se instala el 21).

    Instalar el SDK supone aceptar su licencia, la de Google: se pide
    confirmacion, o -AceptarLicencias.
.PARAMETER Emulador
    Instala tambien el emulador, la imagen de -Api y su telefono virtual.
.PARAMETER Api
    La version de Android del telefono virtual. Por defecto 34 (Android 14).
    26 es Android 8: mas ligera, y la minima que soporta la app.
.PARAMETER Tipo
    default (sin servicios de Google, la mas ligera) o google_apis (con ellos:
    hace falta si la app usa Maps, Firebase o el inicio de sesion de Google).
.PARAMETER Plataforma
    La plataforma para compilar (el compileSdk del proyecto). Por defecto, la
    estable mas reciente.
.PARAMETER BuildTools
    Las build-tools (el buildToolsVersion del proyecto, si lo dice). Por
    defecto, las que usa el plugin de Android para Gradle sin que se le diga.
.PARAMETER Jdk
    El JDK con el que el proyecto ejecuta Gradle, si no es uno de 17 o mas:
    8 para un plugin de Android de antes de la 7, 11 para la 7. Se instala
    si falta, y se usa con "android-shell.bat 8".
.PARAMETER AceptarLicencias
    No pregunta por la licencia del SDK.
.PARAMETER Force
    Reinstala lo que ya esta, y pone ANDROID_HOME aunque apunte a otro SDK.
.PARAMETER WhatIf
    Dice que instalaria, y cuanto pesa, sin tocar nada.
.PARAMETER Quitar
    Quita el SDK, los telefonos virtuales, ANDROID_HOME y sus rutas del PATH.
.EXAMPLE
    .\Setup-AndroidEnv.ps1
.EXAMPLE
    .\Setup-AndroidEnv.ps1 -Emulador
.EXAMPLE
    .\Setup-AndroidEnv.ps1 -Emulador -Api 26
#>

param(
    [switch]$Emulador,

    [string]$Api = '34',

    [ValidateSet('default', 'google_apis')]
    [string]$Tipo = 'default',

    [string]$Plataforma,

    [string]$BuildTools,

    [int]$Jdk,

    [switch]$AceptarLicencias,

    [switch]$Force,

    [switch]$WhatIf,

    [switch]$Quitar
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Common.ps1")
# El SDK de Android (ver su cabecera: no lo carga Common).
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Android.ps1")

Write-Log "========================================" "INFO"
Write-Log "  Android: SDK y emulador, sin admin" "INFO"
Write-Log "========================================" "INFO"
Write-Log ""

# --------------------------------------------------------------------------
# -Quitar
# --------------------------------------------------------------------------

if ($Quitar) {
    $avds = @(Get-AndroidAvds)
    Write-Host "Se va a quitar:" -ForegroundColor Yellow
    Write-Host "  $AndroidRoot"
    if ($avds.Count) { Write-Host "  los telefonos virtuales: $($avds -join ', ')  ($AndroidAvdHome)" }
    Write-Host "  ANDROID_HOME de usuario, si apunta aqui, y sus rutas del PATH"
    Write-Host ""
    if (-not $Force) {
        if ((Read-Host "Confirmas? (escribe SI)") -ne 'SI') { Write-Host "Cancelado." -ForegroundColor Yellow; exit 0 }
    }
    Remove-UserPathEntry -UnderFolder $AndroidRoot | Out-Null
    if ((Get-AndroidUserHome) -like "$AndroidRoot*") {
        [Environment]::SetEnvironmentVariable('ANDROID_HOME', $null, 'User')
        Write-Log "ANDROID_HOME de usuario retirado" "SUCCESS"
    }
    foreach ($d in @($AndroidRoot, $AndroidAvdHome)) {
        if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force; Write-Log "Borrado: $d" "SUCCESS" }
    }
    exit 0
}

# --------------------------------------------------------------------------
# El JDK
# --------------------------------------------------------------------------

# Con -Jdk, el que pide el proyecto; si no, uno de 17 o mas, que es lo que
# pide el plugin de Android desde la 8. El de android-shell.bat por defecto es
# el mas moderno que haya: el otro se elige con "android-shell.bat 8".
$jdkShell = Get-KitJdkForAndroid
if ($Jdk) {
    $jdkProyecto = Get-KitJdkForAndroid -Mayor $Jdk
    if (-not $jdkProyecto) {
        Write-Log "El proyecto ejecuta Gradle con el JDK $Jdk, y el kit no lo tiene."
        if ($WhatIf) { Write-Log "  Se instalaria con Setup-JavaEnv." }
        else {
            Write-Log "  Se instala..."
            $global:LASTEXITCODE = 0
            & (Resolve-KitScript -Nombre 'Setup-JavaEnv.ps1') -JavaVersion $Jdk -SinResumen
            $jdkProyecto = Get-KitJdkForAndroid -Mayor $Jdk
            if (-not $jdkProyecto) { Write-Log "No se pudo instalar el JDK $Jdk; sin el no se puede compilar ese proyecto." "ERROR"; exit 1 }
        }
    }
    if ($jdkProyecto) { Write-Log "JDK del proyecto: $jdkProyecto" "SUCCESS" }
    if (-not $jdkShell) { $jdkShell = $jdkProyecto }
}
elseif (-not $jdkShell -and ($previo = @(Get-AndroidShellJdks | ForEach-Object { Get-KitJdkForAndroid -Mayor $_ } | Where-Object { $_ }))) {
    # Ya hay un proyecto con su JDK (el 8 de uno de antes): para el emulador,
    # o para otra plataforma, no hace falta bajar el 21. Llegara el dia que un
    # proyecto lo pida.
    $jdkShell = $previo[-1]
    Write-Log "No hay un JDK 17 o superior, pero si el de tus proyectos: no se baja otro hasta que un proyecto lo pida."
}
elseif (-not $jdkShell) {
    Write-Log "No hay un JDK 17 o superior del kit (el plugin de Android para Gradle lo pide)."
    if ($WhatIf) { Write-Log "  Se instalaria el 21 con Setup-JavaEnv." }
    else {
        Write-Log "  Se instala el 21..."
        $global:LASTEXITCODE = 0
        & (Resolve-KitScript -Nombre 'Setup-JavaEnv.ps1') -JavaVersion 21 -SinResumen
        $jdkShell = Get-KitJdkForAndroid
        if (-not $jdkShell) { Write-Log "No se pudo instalar el JDK; sin el no se puede compilar." "ERROR"; exit 1 }
    }
}
if ($jdkShell) { Write-Log "JDK de android-shell.bat: $jdkShell" "SUCCESS" }

# --------------------------------------------------------------------------
# Que instalar
# --------------------------------------------------------------------------

Write-Log "Leyendo el indice del SDK de Google..."
$xml = Get-AndroidIndex -Lista 'repository2-3.xml'
if (-not $xml) {
    Write-Log "No se pudo leer el indice del SDK (dl.google.com)." "ERROR"
    Write-Log "  Diagnostico de la red:  .\bin\kit\Doctor-Env.bat" "WARN"
    exit 1
}
$paquetes = @(ConvertFrom-AndroidIndex -Xml $xml)
$licencias = Get-AndroidIndexLicenses -Xml $xml

$plan = @()
$plan += Select-AndroidPackage -Paquetes $paquetes -Path 'platform-tools'
$bt = Select-AndroidBuildTools -Paquetes $paquetes -Version $(if ($BuildTools) { $BuildTools } else { $AndroidBuildToolsAgp })
if ($BuildTools -and $bt -and $bt.Path -ne "build-tools;$($BuildTools.Trim())") {
    Write-Log "No hay build-tools $BuildTools en el indice; se instalan las $($bt.Version)." "WARN"
}
$plan += $bt
$plat = Select-AndroidPlatform -Paquetes $paquetes -Api $Plataforma
if (-not $plat) {
    Write-Log "No hay ninguna plataforma estable $(if ($Plataforma) { "android-$Plataforma" }) en el indice." "ERROR"
    exit 1
}
$plan += $plat

$conEmulador = $false
$imagen = $null
if ($Emulador) {
    $hv = Get-HypervisorPlatformState
    if (-not $hv.Activada -or -not $hv.Hipervisor) {
        Write-Log "El emulador no podria arrancar en este equipo:" "WARN"
        if (-not $hv.Activada) { Write-Log "  la 'Plataforma del hipervisor de Windows' esta desactivada." "WARN" }
        if (-not $hv.Hipervisor) { Write-Log "  el hipervisor de Windows no esta en marcha." "WARN" }
        Write-Log "  Activarla pide admin: es una casilla en 'Caracteristicas de Windows' y un reinicio." "WARN"
        Write-Log "  Se instala solo lo necesario para compilar; el emulador no se descarga." "WARN"
    }
    else {
        $listaImg = Get-AndroidSystemImageList -Tipo $Tipo
        $sys = Get-AndroidIndex -Lista $listaImg
        if ($sys) {
            $imgs = @(ConvertFrom-AndroidIndex -Xml $sys -Lista $listaImg)
            foreach ($k in (Get-AndroidIndexLicenses -Xml $sys).Keys) { if (-not $licencias.ContainsKey($k)) { $licencias[$k] = (Get-AndroidIndexLicenses -Xml $sys)[$k] } }
            $imagen = Select-AndroidSystemImage -Paquetes $imgs -Api $Api -Tipo $Tipo
        }
        if (-not $imagen) {
            Write-Log "No hay imagen '$Tipo' estable para Android API $Api." "ERROR"
            exit 1
        }
        $plan += Select-AndroidPackage -Paquetes $paquetes -Path 'emulator'
        $plan += $imagen
        $conEmulador = $true
    }
}
$plan = @($plan | Where-Object { $_ })

$instalados = @{}
foreach ($i in @(Get-InstalledAndroidPackages -Sdk $AndroidSdk)) { $instalados[$i.Path] = $i.Version }
$falta = @($plan | Where-Object { $Force -or -not $instalados.ContainsKey($_.Path) -or ([version]((($instalados[$_.Path] -split '\.') + @('0', '0'))[0..2] -join '.')) -lt $_.Orden })

Write-Host ""
Write-Host "SDK de Android en $AndroidSdk" -ForegroundColor Yellow
foreach ($p in $plan) {
    $estado = if ($falta -contains $p) { "{0,7:N0} MB" -f ($p.Bytes / 1MB) } else { "  ya esta" }
    Write-Host ("  {0}  {1,-44} {2}" -f $estado, $p.Path, $p.Version)
}
$total = ($falta | Measure-Object Bytes -Sum).Sum
Write-Host ("  Total a descargar: {0:N0} MB" -f ($total / 1MB)) -ForegroundColor Gray
if ($conEmulador) { Write-Host "  Telefono virtual: kit-api$Api$(if ($Tipo -ne 'default') { "-$Tipo" }) (1,5 GB de RAM, 720x1280)" }
Write-Host ""

if ($WhatIf) {
    Write-Host "-WhatIf: no se ha tocado nada." -ForegroundColor Cyan
    exit 0
}

# --------------------------------------------------------------------------
# La licencia
# --------------------------------------------------------------------------

if ($falta.Count -gt 0 -and -not $AceptarLicencias) {
    $ids = @($falta | ForEach-Object { $_.Licencia } | Select-Object -Unique)
    Write-Host "Para usar el SDK de Android hay que aceptar la licencia de Google ($($ids -join ', '))." -ForegroundColor Yellow
    Write-Host "  https://developer.android.com/studio/terms" -ForegroundColor Gray
    Write-Host "  Se puede leer entera en sdk\licenses tras instalar, o en esa pagina." -ForegroundColor Gray
    $r = $null
    try { $r = Read-Host "La aceptas? (escribe SI)" } catch { }
    if ($r -ne 'SI') {
        Write-Log "Sin aceptar la licencia no se instala nada. Para no preguntar:  -AceptarLicencias" "WARN"
        exit 1
    }
}

# --------------------------------------------------------------------------
# Instalar
# --------------------------------------------------------------------------

$fallos = @()
foreach ($p in $falta) {
    Write-Log "$($p.Nombre), version $($p.Version)..."
    if (Install-AndroidPackage -Paquete $p -Sdk $AndroidSdk -Licencias $licencias) { Write-Log "  instalado" "SUCCESS" }
    else { $fallos += $p.Path }
}

$lic = Write-AndroidLicenses -Sdk $AndroidSdk -Licencias $licencias -Ids @($plan | ForEach-Object { $_.Licencia })
if ($lic.Cambiadas.Count -gt 0) {
    Write-Log "Google ha cambiado el texto de: $($lic.Cambiadas -join ', ')." "WARN"
    Write-Log "  El kit no escribe una aceptacion que ya no corresponde. Si Gradle la pide, acepta la licencia" "WARN"
    Write-Log "  desde Android Studio, o avisa para actualizar el kit." "WARN"
}

$e = Get-AndroidEnvironment -Sdk $AndroidSdk -Jdk $jdkShell
foreach ($k in $e.Variables.Keys) { Set-Item -LiteralPath "Env:\$k" -Value $e.Variables[$k] }

if ($conEmulador -and ($fallos -notcontains 'emulator') -and ($fallos -notcontains $imagen.Path)) {
    $acc = Test-AndroidEmulatorAccel -Sdk $AndroidSdk
    if ($acc.Ok) { Write-Log "Aceleracion del emulador: $($acc.Texto)" "SUCCESS" }
    else {
        Write-Log "El emulador dice que no puede acelerar: $($acc.Texto)" "WARN"
        Write-Log "  Sin aceleracion no arranca. Lo que hay que activar pide admin (ver Doctor)." "WARN"
    }
    $avd = "kit-api$Api$(if ($Tipo -ne 'default') { "-$Tipo" })"
    if ((Get-AndroidAvds) -notcontains $avd -or $Force) {
        $tagNombre = $imagen.Nodo.'type-details'.tag.display
        New-AndroidAvd -Nombre $avd -AvdHome $AndroidAvdHome -ImagePath $imagen.Path -TagNombre $tagNombre | Out-Null
        Write-Log "Telefono virtual creado: $avd" "SUCCESS"
    }
    else { Write-Log "Telefono virtual $avd ya existe" "SUCCESS" }
}

# Las android-javaN-shell.bat que ya habia se conservan, y se anade la del
# JDK del proyecto. Tambien cuando hoy coincide con el de la consola por
# defecto (un equipo sin ningun JDK moderno): Setup-Project dice que se abra
# esa, y el dia que llegue un JDK 21 la de por defecto cambia y esta no.
$otrosJdk = @(Get-AndroidShellJdks)
if ($Jdk -and $jdkProyecto) { $otrosJdk += $Jdk }
$shell = Write-AndroidShell -Sdk $AndroidSdk -Jdk $jdkShell -OtrosJdk $otrosJdk
$env2 = Set-AndroidUserEnv -Sdk $AndroidSdk -Force:$Force
if ($env2.Puesto) { Write-Log "ANDROID_HOME de usuario: $AndroidSdk" "SUCCESS" }
else {
    Write-Log "ANDROID_HOME ya apunta a otro SDK ($($env2.Habia)); se deja. Para cambiarlo: -Force" "WARN"
}
Add-UserPathEntry -Path @((Join-Path $AndroidSdk 'platform-tools'), (Join-Path $AndroidSdk 'emulator'))

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
if ($fallos.Count -eq 0) { Write-Host "  ANDROID LISTO" -ForegroundColor Cyan }
else { Write-Host "  A medias: fallo $($fallos -join ', ')" -ForegroundColor Red }
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Consola con todo puesto (y Gradle con tope de memoria), con doble clic:" -ForegroundColor Yellow
if ($Jdk -and $jdkProyecto) {
    Write-Host "  $(Join-Path (Split-Path -Parent $shell) "android-java$Jdk-shell.bat")   (la de este proyecto: JDK $Jdk)" -ForegroundColor White
}
else { Write-Host "  $shell" -ForegroundColor White }
Write-Host "  En la carpeta del proyecto:  gradlew assembleDebug" -ForegroundColor White
if ($conEmulador) {
    Write-Host "Arrancar el telefono e instalarle la app:" -ForegroundColor Yellow
    Write-Host "  .\bin\start\Start-AndroidEmulator.bat -Apk app\build\outputs\apk\debug\app-debug.apk" -ForegroundColor White
}
Write-Host ""
if ($fallos.Count -gt 0) { exit 1 }
exit 0
