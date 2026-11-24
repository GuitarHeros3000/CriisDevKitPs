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
.PARAMETER Depurar
    Con -Apk: la abre parada, esperando a que se conecte un depurador, y deja
    un puente desde localhost:-Puerto hasta ella (adb forward, que solo
    escucha en este equipo: sin avisos del firewall). Lo usa Start-AndroidApp
    -Depurar, que ademas prepara VS Code.
.PARAMETER Puerto
    El puerto del puente para el depurador. Por defecto 5005.
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

    [int]$Espera = 300,

    [switch]$Depurar,

    [int]$Puerto = 5005
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
    <#
        El emulador abierto que es ESTE telefono, o $null. Antes valia el
        primero que hubiera: con el de Android 8 abierto y pidiendo el de 14,
        instalaba en el de 8. Cada emulador dice que carpeta de telefono esta
        usando (emu avd path), y esa es la que se compara.
    #>
    $quiero = (Join-Path $AndroidAvdHome "$Avd.avd").TrimEnd('\')
    return @(Get-AndroidEmulators -Adb $adb | Where-Object { $_.Avd -eq $quiero })[0].Serie
}

$serie = Get-EmuladorEnMarcha
if ($serie -and ($EnFrio -or $Borrar)) {
    Write-Log "Ya hay un emulador abierto ($serie): cierralo para arrancar en frio o borrar sus datos." "WARN"
    exit 1
}

if ($serie) {
    Write-Log "Ya estaba abierto: $Avd ($serie)" "SUCCESS"
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
        # El telefono esta abierto pero su Android se ha caido por dentro
        # (paso con uno encendido horas, con otro al lado): no hay servicio que
        # instale nada hasta que se reinicie.
        if ($r.Output -match "Can't find service") {
            Write-Log "El Android del telefono no responde por dentro: cierralo (la X de su ventana) y vuelve a intentarlo." "ERROR"
            Write-Log "  Si sigue igual, arrancalo de cero:  -EnFrio" "WARN"
            exit 1
        }
        Write-Log "No se pudo instalar: $($r.Output.Trim())" "ERROR"
        exit 1
    }
    Write-Log "Instalada" "SUCCESS"

    $info = Get-AndroidApkInfo -Apk $Apk -Sdk $AndroidSdk

    if ($Depurar) {
        if (-not $info -or -not $info.Actividad) {
            Write-Log "No se sabe con que pantalla arranca la app: no se puede abrir esperando al depurador." "ERROR"
            exit 1
        }
        # -D: arranca parada hasta que se conecta un depurador, para que se
        # pueda parar incluso en lo primero que hace. -S: cierra antes la que
        # hubiera abierta. --activity-clear-task: empieza con la pila limpia;
        # sin el, si arriba quedo un dialogo de Android (el de los permisos,
        # que sale la primera vez), Android lo traia al frente y la app no
        # llegaba a arrancar ("Activity not started, its current task has
        # been brought to the front").
        $r = Invoke-NativeCommand -FilePath $adb -Arguments @('-s', $serie, 'shell', 'am', 'start', '-D', '-S', '--activity-clear-task', '-n', "$($info.Paquete)/$($info.Actividad)") -Quiet
        if ($r.ExitCode -ne 0 -or $r.Output -match '(?m)^Error|Activity not started') { Write-Log "No se pudo abrir para depurar: $($r.Output.Trim())" "ERROR"; exit 1 }
        $proceso = $null
        $limite = (Get-Date).AddSeconds(20)
        while (-not $proceso -and (Get-Date) -lt $limite) {
            Start-Sleep -Milliseconds 500
            $o = (Invoke-NativeCommand -FilePath $adb -Arguments @('-s', $serie, 'shell', 'pidof', $info.Paquete) -Quiet).Output
            if ($o -match '(\d+)') { $proceso = $Matches[1] }
        }
        if (-not $proceso) { Write-Log "La app no llego a arrancar para depurarla." "ERROR"; exit 1 }
        # "am start -D" deja la app marcada para esperar al depurador, y la
        # marca se queda: las siguientes veces que se abriera (a mano o con
        # la opcion normal) se quedaria en "Waiting For Debugger". Se borra en
        # cuanto esta ya esperando, que es cuando esta vez ya no le afecta.
        $limite = (Get-Date).AddSeconds(15)
        do {
            Start-Sleep -Milliseconds 400
            $foco = (Invoke-NativeCommand -FilePath $adb -Arguments @('-s', $serie, 'shell', 'dumpsys', 'window', 'windows') -Quiet).Output
        } while ($foco -notmatch 'mCurrentFocus=[^\r\n]*Waiting For Debugger' -and (Get-Date) -lt $limite)
        Invoke-NativeCommand -FilePath $adb -Arguments @('-s', $serie, 'shell', 'am', 'clear-debug-app') -Quiet | Out-Null
        # El puente de la vez anterior apuntaria a un proceso que ya no existe.
        Invoke-NativeCommand -FilePath $adb -Arguments @('-s', $serie, 'forward', '--remove', "tcp:$Puerto") -Quiet | Out-Null
        $r = Invoke-NativeCommand -FilePath $adb -Arguments @('-s', $serie, 'forward', "tcp:$Puerto", "jdwp:$proceso") -Quiet
        if ($r.ExitCode -ne 0) { Write-Log "No se pudo hacer el puente al puerto ${Puerto}: $($r.Output.Trim())" "ERROR"; exit 1 }
        Write-Log "Abierta y esperando al depurador en localhost:${Puerto}: $($info.Paquete) (proceso $proceso)" "SUCCESS"
        exit 0
    }

    if ($info -and $info.Paquete) {
        # Por si una depuracion de antes la dejo marcada para esperar al
        # depurador: abierta normal, no tiene que esperar a nadie.
        Invoke-NativeCommand -FilePath $adb -Arguments @('-s', $serie, 'shell', 'am', 'clear-debug-app') -Quiet | Out-Null
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
