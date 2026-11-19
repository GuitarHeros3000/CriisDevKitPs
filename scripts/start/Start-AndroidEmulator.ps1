#Requires -Version 5.1
<#
.SYNOPSIS
    Start-AndroidEmulator.ps1 - Arranca el telefono virtual y, si se le da, instala y abre la app.
.DESCRIPTION
    Arranca el emulador con lo minimo (sin animacion de arranque ni audio, y
    reanudando desde la ultima vez si se puede), espera a que Android termine
    de arrancar, y con -Apk instala la app y la abre.

    Si el emulador ya esta abierto, lo reutiliza: instalar otra version de la
    app no necesita volver a arrancarlo, que es lo que mas tarda.
.PARAMETER Api
    Que telefono virtual: el de esa API (kit-api34, kit-api26...). Por
    defecto, el unico que haya, o el de la API mas alta.
.PARAMETER Avd
    El telefono virtual por su nombre, en vez de por la API.
.PARAMETER Apk
    La app que instalar y abrir al terminar de arrancar.
.PARAMETER EnFrio
    Arranca desde cero en vez de reanudar (si algo se quedo raro).
.PARAMETER Borrar
    Borra los datos del telefono virtual: queda como recien creado.
.PARAMETER Espera
    Segundos maximos esperando a que arranque. Por defecto 300.
.EXAMPLE
    .\Start-AndroidEmulator.ps1
.EXAMPLE
    .\Start-AndroidEmulator.ps1 -Apk app\build\outputs\apk\debug\app-debug.apk
.EXAMPLE
    .\Start-AndroidEmulator.ps1 -Api 26
#>

param(
    [string]$Api,

    [string]$Avd,

    [string]$Apk,

    [switch]$EnFrio,

    [switch]$Borrar,

    [int]$Espera = 300
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Common.ps1")
# El SDK de Android (ver su cabecera: no lo carga Common).
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Android.ps1")

Write-Log "========================================" "INFO"
Write-Log "  Emulador de Android" "INFO"
Write-Log "========================================" "INFO"

$emu = Join-Path $AndroidSdk 'emulator\emulator.exe'
$adb = Join-Path $AndroidSdk 'platform-tools\adb.exe'
if (-not (Test-Path -LiteralPath $emu) -or -not (Test-Path -LiteralPath $adb)) {
    Write-Log "El emulador no esta instalado." "ERROR"
    Write-Log "  Instalalo con:  .\bin\setup\Setup-AndroidEnv.bat -Emulador" "WARN"
    exit 1
}

if ($Apk) {
    $Apk = $Apk.Trim().Trim('"')
    if (-not (Test-Path -LiteralPath $Apk -PathType Leaf)) { Write-Log "No existe la app: $Apk" "ERROR"; exit 1 }
    $Apk = (Resolve-Path -LiteralPath $Apk).ProviderPath
}

# Las mismas variables que el shell del kit: el emulador busca la imagen en
# ANDROID_SDK_ROOT y los telefonos en ANDROID_AVD_HOME.
$e = Get-AndroidEnvironment -Sdk $AndroidSdk -Jdk (Get-KitJdkForAndroid)
foreach ($k in $e.Variables.Keys) { Set-Item -LiteralPath "Env:\$k" -Value $e.Variables[$k] }

$avds = @(Get-AndroidAvds)
if (-not $Avd) {
    if ($Api) { $Avd = @($avds | Where-Object { $_ -match "^kit-api$([regex]::Escape($Api))(-|$)" })[0] }
    else { $Avd = @($avds | Sort-Object { if ($_ -match 'api(\d+)') { [int]$Matches[1] } else { 0 } } -Descending)[0] }
}
if (-not $Avd -or $avds -notcontains $Avd) {
    Write-Log "No hay telefono virtual$(if ($Api) { " de la API $Api" }). Hay: $(if ($avds.Count) { $avds -join ', ' } else { 'ninguno' })" "ERROR"
    Write-Log "  Crealo con:  .\bin\setup\Setup-AndroidEnv.bat -Emulador$(if ($Api) { " -Api $Api" })" "WARN"
    exit 1
}

function Get-EmuladorEnMarcha {
    $l = (Invoke-NativeCommand -FilePath $adb -Arguments @('devices') -Quiet).Output
    return @([regex]::Matches($l, '(?m)^(emulator-\d+)\s+device') | ForEach-Object { $_.Groups[1].Value })[0]
}

$serie = Get-EmuladorEnMarcha
if ($serie -and ($EnFrio -or $Borrar)) {
    Write-Log "Ya hay un emulador abierto ($serie): cierralo para arrancar en frio o borrar sus datos." "WARN"
    exit 1
}

if ($serie) {
    Write-Log "Ya estaba abierto: $serie" "SUCCESS"
}
else {
    $args_ = @('-avd', $Avd, '-no-boot-anim', '-no-audio', '-netdelay', 'none', '-netspeed', 'full')
    if ($EnFrio) { $args_ += '-no-snapshot-load' }
    if ($Borrar) { $args_ += '-wipe-data' }
    Write-Log "Arrancando $Avd..."
    Start-Process -FilePath $emu -ArgumentList $args_ -WorkingDirectory (Split-Path -Parent $emu) | Out-Null

    $limite = (Get-Date).AddSeconds($Espera)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Seconds 3
        $serie = Get-EmuladorEnMarcha
        $listo = $false
        if ($serie) {
            $listo = ((Invoke-NativeCommand -FilePath $adb -Arguments @('-s', $serie, 'shell', 'getprop', 'sys.boot_completed') -Quiet).Output.Trim() -eq '1')
        }
        Write-Host ("`r  esperando a Android... {0} s " -f [int]$sw.Elapsed.TotalSeconds) -NoNewline -ForegroundColor DarkGray
    } while (-not $listo -and (Get-Date) -lt $limite)
    Write-Host ""

    if (-not $listo) {
        Write-Log "No termino de arrancar en $Espera s." "ERROR"
        Write-Log "  Si la ventana del emulador dio un error, el diagnostico:  .\bin\kit\Doctor-Env.bat" "WARN"
        Write-Log "  Si se quedo a medias, prueba en frio:  -EnFrio" "WARN"
        exit 1
    }
    Write-Log ("Listo en {0:N0} s: {1}" -f $sw.Elapsed.TotalSeconds, $serie) "SUCCESS"
}

if ($Apk) {
    Write-Log "Instalando $(Split-Path -Leaf $Apk)..."
    $r = Invoke-NativeCommand -FilePath $adb -Arguments @('-s', $serie, 'install', '-r', '-t', $Apk) -Quiet
    if ($r.ExitCode -ne 0 -or $r.Output -notmatch 'Success') {
        Write-Log "No se pudo instalar: $($r.Output.Trim())" "ERROR"
        exit 1
    }
    Write-Log "Instalada" "SUCCESS"

    $info = Get-AndroidApkInfo -Apk $Apk -Sdk $AndroidSdk
    if ($info -and $info.Paquete) {
        # monkey con la categoria LAUNCHER abre la actividad principal sin
        # tener que saber como se llama.
        $r = Invoke-NativeCommand -FilePath $adb -Arguments @('-s', $serie, 'shell', 'monkey', '-p', $info.Paquete, '-c', 'android.intent.category.LAUNCHER', '1') -Quiet
        if ($r.ExitCode -eq 0) { Write-Log "Abierta: $($info.Paquete)" "SUCCESS" }
        else { Write-Log "Instalada, pero no se pudo abrir sola: abrela desde el telefono." "WARN" }
    }
    # Antes se callaba, y parecia que habia ido todo bien.
    else { Write-Log "Instalada, pero no se sabe como se llama para abrirla sola: abrela desde el telefono." "WARN" }
}
exit 0
