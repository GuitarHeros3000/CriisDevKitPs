#Requires -Version 5.1
<#
.SYNOPSIS
    Menu-Android.ps1 - El menu del paquete de Android de CriisDevKit.
.DESCRIPTION
    Lo de Android y nada mas: compilar una app y abrirla en el telefono
    virtual, abrir solo el telefono, ver lo que escribe la app, depurarla en
    VS Code, y quitar todo lo que el paquete instalo (Android y el Java que
    trajo para compilar).

    Cada opcion llama al mismo script que el kit completo, en su propio
    proceso: lo que ese script cambie de su entorno no se queda en el menu.

    Vive en tools\paquete-android del kit, y Build-PaqueteAndroid lo pone en
    scripts\kit\ del paquete: de ahi que suba dos carpetas para llegar a lib.
#>

$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Common.ps1")
# El SDK de Android, y donde recuerda el ultimo proyecto (tampoco lo carga Common).
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Android.ps1")

function Invoke-PaqueteScript {
    param([Parameter(Mandatory=$true)][string]$Nombre, [string[]]$Argumentos = @())
    $ps = Resolve-KitScript -Nombre $Nombre
    if (-not $ps) { Write-Host "   Falta $Nombre en el paquete." -ForegroundColor Red; return }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ps @Argumentos
}

while ($true) {
    $ultimo = Get-AndroidLastProject
    $avds = @(Get-AndroidAvds)

    # Sin ventana de verdad (la salida redirigida, como al comprobar el
    # paquete) Clear-Host falla, y con Stop se llevaria el menu por delante.
    try { Clear-Host } catch { }
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "   CriisDevKit - Android   v$KitVersion" -ForegroundColor Cyan
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host ("   Telefono : " + $(if ($avds.Count) { $avds -join ', ' } else { 'todavia ninguno (se crea la primera vez)' })) -ForegroundColor DarkGray
    Write-Host ("   Proyecto : " + $(if ($ultimo) { $ultimo } else { 'ninguno todavia' })) -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    1  Compilar y probar una app"
    Write-Host "    2  Abrir el telefono"
    Write-Host "    3  Ver el registro de la app"
    Write-Host "    4  Depurar la app en VS Code"
    Write-Host ""
    Write-Host "    5  Quitar Android (y el Java que instalo)"
    Write-Host ""
    Write-Host "    q  Salir" -ForegroundColor DarkGray
    Write-Host ""

    $op = ([string](Read-Host "   Opcion")).Trim()
    if ($op -in @('q', 'Q', 'salir', 'exit')) { break }

    switch ($op) {
        { $_ -in '1', '4' } {
            Write-Host ""
            Write-Host "   La carpeta del proyecto: la que tiene gradlew.bat." -ForegroundColor DarkGray
            Write-Host "   La primera vez instala lo que falte (puede ser 1 GB); despues, solo compila y abre." -ForegroundColor DarkGray
            $p = if ($ultimo) { Read-Host "   Carpeta del proyecto [$ultimo]" } else { Read-Host "   Carpeta del proyecto" }
            if ([string]::IsNullOrWhiteSpace($p)) { $p = $ultimo }
            if ($p) {
                $a = @('-Path', $p.Trim().Trim('"'))
                if ($op -eq '4') { $a += '-Depurar' }
                Invoke-PaqueteScript -Nombre 'Start-AndroidApp.ps1' -Argumentos $a
            }
        }
        '2' { Invoke-PaqueteScript -Nombre 'Start-AndroidEmulator.ps1' }
        '3' {
            Write-Host "   Ctrl+C para volver al menu." -ForegroundColor DarkGray
            Invoke-PaqueteScript -Nombre 'Start-AndroidLog.ps1'
        }
        '5' { Invoke-PaqueteScript -Nombre 'Setup-AndroidEnv.ps1' -Argumentos @('-Quitar', '-ConJava') }
        default { Write-Host "   '$op' no es una opcion." -ForegroundColor Yellow }
    }

    Write-Host ""
    Read-Host "   Pulsa Intro para volver al menu" | Out-Null
}
