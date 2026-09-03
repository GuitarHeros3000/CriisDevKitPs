#Requires -Version 5.1
<#
.SYNOPSIS
    Run-Tests.ps1 - Ejecuta las pruebas del kit con Pester.
.DESCRIPTION
    Las pruebas estan escritas para Pester 3.4, que viene de fabrica en Windows.
    Es deliberado: pedir Install-Module obligaria a salir a PSGallery, que es
    justo lo que bloquea el proxy corporativo para el que existe este kit. Unas
    pruebas que no se pueden ejecutar en la maquina de destino no sirven de nada.

    Si ademas hay una Pester 5 instalada, se fuerza igualmente la 3.x: la sintaxis
    de asercion cambio ("Should Be" paso a "Should -Be") y con la 5 fallaria todo
    con errores que no dicen lo que pasa.

    Ninguna prueba toca el registro, el PATH real ni la red: las que cubren el
    PATH sustituyen sus dos puertas al sistema por mocks.
.PARAMETER Name
    Ejecuta solo los archivos cuyo nombre contenga este texto (ej: -Name Shells).
.PARAMETER Quiet
    Solo el resumen. Por defecto Pester 3 lista cada prueba.
.EXAMPLE
    .\Run-Tests.ps1
.EXAMPLE
    .\Run-Tests.ps1 -Name UserPath
#>

param(
    [string]$Name,
    [switch]$Quiet
)

$ProgressPreference = "SilentlyContinue"

# Sin registro en archivo: se ejecuta muchas veces mientras se desarrolla y sus
# logs desplazarian por rotacion a los de las ejecuciones reales, que son los que
# sirven para diagnosticar. Se define ANTES del dot-sourcing, que es cuando
# Common.ps1 abre el registro.
$env:ASSASSINSKIPADM_NOLOG = "1"

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Common.ps1")

$TestsDir = Join-Path $DevKitRoot "tests"

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Pruebas del kit" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path -LiteralPath $TestsDir)) {
    Write-Log "No existe la carpeta tests\: $TestsDir" "ERROR"
    exit 1
}

# --- Pester 3.x, explicitamente ---
$disponibles = @(Get-Module -ListAvailable -Name Pester -ErrorAction SilentlyContinue)
$pester3 = @($disponibles | Where-Object { $_.Version.Major -eq 3 } | Sort-Object Version -Descending)

if ($pester3.Count -eq 0) {
    Write-Log "No se encontro Pester 3.x." "ERROR"
    if ($disponibles.Count -gt 0) {
        Write-Log "  Hay instalada: $(($disponibles | ForEach-Object { $_.Version }) -join ', ')" "WARN"
        Write-Log "  Las pruebas usan la sintaxis de Pester 3 ('Should Be', sin guion)." "WARN"
    }
    Write-Log "  Pester 3.4 viene con Windows; si falta, instalalo sin admin con:" "WARN"
    Write-Log "  Install-Module Pester -RequiredVersion 3.4.0 -Scope CurrentUser -Force" "WARN"
    exit 1
}

Remove-Module Pester -Force -ErrorAction SilentlyContinue
Import-Module $pester3[0].Path -Force
Write-Log "Pester $($pester3[0].Version)" "SUCCESS"

$archivos = @(Get-ChildItem -LiteralPath $TestsDir -Filter '*.Tests.ps1' -File |
    Where-Object { [string]::IsNullOrWhiteSpace($Name) -or $_.Name -like "*$Name*" })

if ($archivos.Count -eq 0) {
    Write-Log "No hay archivos de prueba que coincidan con '$Name'" "WARN"
    exit 1
}

Write-Log "Archivos: $(($archivos | ForEach-Object { $_.Name }) -join ', ')"
Write-Host ""

$parametros = @{
    Path     = @($archivos | ForEach-Object { $_.FullName })
    PassThru = $true
}
# -Show no existe en Pester 3.4 (llego en la 4); el equivalente es -Quiet.
if ($Quiet) { $parametros.Quiet = $true }

$resultado = Invoke-Pester @parametros

Write-Host ""

# Comprobacion imprescindible: si Invoke-Pester no llego a ejecutarse, $resultado
# es $null y "$null.FailedCount -gt 0" es FALSO, con lo que este script anunciaba
# "pruebas OK" y salia con 0 sin haber probado nada. Un runner que miente asi es
# peor que no tenerlo.
if ($null -eq $resultado) {
    Write-Host "============================================" -ForegroundColor Red
    Write-Host "  LAS PRUEBAS NO LLEGARON A EJECUTARSE" -ForegroundColor Red
    Write-Host "============================================" -ForegroundColor Red
    Write-Host ""
    exit 1
}

if ($resultado.FailedCount -gt 0) {
    Write-Host "============================================" -ForegroundColor Red
    Write-Host "  $($resultado.FailedCount) PRUEBA(S) FALLIDA(S)" -ForegroundColor Red
    Write-Host "============================================" -ForegroundColor Red
    Write-Host ""
    exit 1
}

Write-Host "============================================" -ForegroundColor Green
Write-Host "  $($resultado.PassedCount) pruebas OK" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
exit 0
