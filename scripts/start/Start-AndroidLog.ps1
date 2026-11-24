#Requires -Version 5.1
<#
.SYNOPSIS
    Start-AndroidLog.ps1 - Lo que escribe tu app en el telefono, en directo y sin el resto de Android.
.DESCRIPTION
    El registro de Android (logcat) mezcla lo de todas las apps y el sistema:
    cientos de lineas por segundo. Esto ensena solo las de tu app, en color
    segun la gravedad (errores en rojo, avisos en amarillo), con sus
    Log.d / Log.e y sus errores (los "FATAL EXCEPTION" incluidos).

    La sigue aunque se cierre y se vuelva a abrir, que cambia de proceso: se
    entera por los avisos del propio sistema. Empieza ensenando lo ultimo que
    escribio, por si lo que buscas acaba de pasar.

    Ctrl+C para salir.
.PARAMETER Path
    El proyecto, para saber como se llama la app. Por defecto, el ultimo que
    se compilo con Start-AndroidApp.
.PARAMETER Paquete
    El nombre de la app (com.empresa.app), en vez de sacarlo del proyecto.
.PARAMETER Todo
    Todo el registro, sin filtrar por la app.
.EXAMPLE
    .\Start-AndroidLog.ps1
.EXAMPLE
    .\Start-AndroidLog.ps1 -Paquete com.empresa.app
#>

param(
    [string]$Path,

    [string]$Paquete,

    [switch]$Todo
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Common.ps1")
# El SDK de Android y lo que lee el proyecto (ver sus cabeceras: no los carga Common).
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Android.ps1")
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Project.ps1")

$adb = Join-Path $AndroidSdk 'platform-tools\adb.exe'
if (-not (Test-Path -LiteralPath $adb)) { Write-Log "No esta adb: compila y abre la app primero (Start-AndroidApp)." "ERROR"; exit 1 }
$e = Get-AndroidEnvironment -Sdk $AndroidSdk
foreach ($k in $e.Variables.Keys) { Set-Item -LiteralPath "Env:\$k" -Value $e.Variables[$k] }

# Como se llama la app: lo dice su APK, que es lo mismo que se instala.
if (-not $Paquete -and -not $Todo) {
    if (-not $Path) { $Path = Get-AndroidLastProject }
    $info = if ($Path) { Get-AndroidProjectInfo -Ruta $Path } else { $null }
    $apk = if ($info) { Get-AndroidBuiltApk -Proyecto $Path -Modulo (Split-Path -Parent $info.Fuente) } else { $null }
    $datos = if ($apk) { Get-AndroidApkInfo -Apk $apk.FullName -Sdk $AndroidSdk } else { $null }
    if ($datos) { $Paquete = $datos.Paquete }
}
if (-not $Paquete -and -not $Todo) {
    Write-Log "No se sabe que app mirar: compilala primero (Start-AndroidApp), o di cual con -Paquete com.empresa.app." "ERROR"
    exit 1
}

# Que telefono: uno de los del kit si hay alguno abierto (con otros al lado,
# el primero de la lista no tiene por que ser el bueno), y de esos, el que
# tenga la app en marcha.
$emus = @(Get-AndroidEmulators -Adb $adb)
if (-not $emus.Count) { Write-Log "No hay ningun telefono abierto: abrelo primero (Start-AndroidEmulator, o Start-AndroidApp con la app)." "ERROR"; exit 1 }
$casa = $AndroidAvdHome.TrimEnd('\') + '\'
$nuestros = @($emus | Where-Object { $_.Avd -and $_.Avd.StartsWith($casa, [StringComparison]::OrdinalIgnoreCase) })
$candidatos = if ($nuestros.Count) { $nuestros } else { $emus }
$serie = $candidatos[0].Serie
if (-not $Todo -and $candidatos.Count -gt 1) {
    foreach ($c in $candidatos) {
        if ((Invoke-NativeCommand -FilePath $adb -Arguments @('-s', $c.Serie, 'shell', 'pidof', $Paquete) -Quiet).Output -match '\d') { $serie = $c.Serie; break }
    }
}

# Los procesos de la app que ya esten en marcha. Los que vengan despues los
# anuncia el propio sistema en el registro.
$procesos = @{}
if (-not $Todo) {
    $o = (Invoke-NativeCommand -FilePath $adb -Arguments @('-s', $serie, 'shell', 'pidof', $Paquete) -Quiet).Output
    foreach ($m in [regex]::Matches([string]$o, '\d+')) { $procesos[[int]$m.Value] = $true }
}

Write-Host ""
Write-Host "  Registro de $(if ($Todo) { 'todo el telefono' } else { $Paquete }) en $serie   (Ctrl+C para salir)" -ForegroundColor Cyan
if (-not $Todo -and -not $procesos.Count) { Write-Host "  La app no esta abierta: en cuanto se abra, sale aqui." -ForegroundColor DarkGray }
Write-Host ""

$colores = @{ 'V' = 'DarkGray'; 'D' = 'Gray'; 'I' = 'White'; 'W' = 'Yellow'; 'E' = 'Red'; 'F' = 'Red'; 'A' = 'Red' }

# Continue y no Stop: si adb escribe algo por su salida de error, con Stop
# cortaria el registro.
$ErrorActionPreference = 'Continue'
& $adb -s $serie logcat -v threadtime -T 300 2>&1 | ForEach-Object {
    $l = ConvertFrom-LogcatLine -Linea "$_"
    if (-not $l) { return }
    if (-not $Todo) {
        $ev = Get-LogcatAppProcess -Mensaje $l.Mensaje -Paquete $Paquete
        if ($ev -and $ev.Evento -eq 'arranca') { $procesos[$ev.Pid] = $true; Write-Host "  --- la app arranca (proceso $($ev.Pid)) ---" -ForegroundColor Cyan; return }
        if ($ev -and $ev.Evento -eq 'muere') { $procesos.Remove($ev.Pid); Write-Host "  --- la app se cerro (proceso $($ev.Pid)) ---" -ForegroundColor Cyan; return }
        if (-not $procesos.ContainsKey($l.Pid)) { return }
    }
    Write-Host ("{0} {1} {2}: {3}" -f $l.Hora, $l.Nivel, $l.Etiqueta, $l.Mensaje) -ForegroundColor $colores[$l.Nivel]
}
exit 0
