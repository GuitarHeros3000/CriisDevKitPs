#Requires -Version 5.1
<#
.SYNOPSIS
    Restore-Env.ps1 - Reproduce un entorno completo desde un devenv.json.
.DESCRIPTION
    Un devenv.json describe que necesita un proyecto: Python 3.12, Java 21,
    Node 22, y los paquetes que hagan falta. Este comando lo lee y lo instala
    todo, sin admin.

    Para que sirve: hoy montar el entorno es acordarse de que comandos y que
    versiones. Con un devenv.json dentro del repositorio, la receta viaja con el
    proyecto: en un portatil nuevo, tras una reinstalacion, o para otra persona,
    es UN comando. Y como es un archivo de texto, se versiona: cuando subes de
    version, el cambio queda registrado y al resto le llega solo.

    No descarga nada por su cuenta: llama a los mismos Setup-*Env.bat que
    usarias a mano, asi que hereda el proxy, el espejo interno, los checksums y
    las copias de seguridad del PATH.

    Con -Save hace lo contrario: mira lo que ya tienes instalado y escribe el
    devenv.json. Es la forma comoda de empezar.
.PARAMETER Path
    Ruta del devenv.json. Por defecto, devenv.json en la carpeta actual.
.PARAMETER Save
    En vez de instalar, escribe un devenv.json con lo que hay instalado ahora.
.PARAMETER Force
    No pide confirmacion.
.PARAMETER WhatIf
    Muestra el plan y no toca nada.
.EXAMPLE
    .\Restore-Env.ps1 -Save
.EXAMPLE
    .\Restore-Env.ps1 -WhatIf
.EXAMPLE
    .\Restore-Env.ps1 -Path C:\proyectos\mi-app\devenv.json
#>

param(
    [string]$Path,

    [switch]$Save,

    [switch]$Force,

    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = Join-Path (Get-Location).Path "devenv.json"
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Restore-Env - Entorno desde devenv.json" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# --------------------------------------------------------------------------
# -Save: escribir el manifiesto a partir de lo instalado
# --------------------------------------------------------------------------

if ($Save) {
    $runtimes = [ordered]@{}
    foreach ($e in (Get-RuntimeCatalog)) {
        $lineas = @(Get-InstalledRuntimeLines -Entrada $e)
        if ($lineas.Count -eq 0) { continue }

        # Si hay varias lineas de un mismo runtime se anota la mas alta: un
        # manifiesto describe UN entorno, no todo lo que llegaste a instalar.
        $elegida = @($lineas | Sort-Object {
            try { [version]($_ -replace '^(\d+)$', '$1.0') } catch { [version]'0.0' }
        } -Descending)[0]

        $runtimes[$e.Clave] = $elegida
        if ($lineas.Count -gt 1) {
            Write-Log "$($e.Nombre): hay $($lineas.Count) lineas ($($lineas -join ', ')); se anota $elegida" "WARN"
        }
    }

    if ($runtimes.Count -eq 0) {
        Write-Log "No hay nada instalado por el kit que anotar." "ERROR"
        Write-Log "  Instala algo primero, por ejemplo:  .\Setup-PythonEnv.bat" "WARN"
        exit 1
    }

    $manifiesto = [ordered]@{
        version     = 1
        descripcion = "Entorno de desarrollo. Reproducelo con:  Restore-Env.bat"
        runtimes    = $runtimes
    }

    if ($WhatIf) {
        Write-Host "Se escribiria en $Path :" -ForegroundColor Yellow
        Write-Host ""
        ($manifiesto | ConvertTo-Json -Depth 5) -split "`n" | ForEach-Object { Write-Host "  $_" }
        Write-Host ""
        Write-Host "-WhatIf: no se ha tocado nada." -ForegroundColor Cyan
        Write-Host ""
        exit 0
    }

    if ((Test-Path -LiteralPath $Path) -and -not $Force) {
        Write-Host "Ya existe $Path" -ForegroundColor Yellow
        $r = Read-Host "Lo sobrescribo? (escribe SI)"
        if ($r -ne 'SI') {
            Write-Host "Cancelado. No se ha tocado nada." -ForegroundColor Yellow
            exit 0
        }
    }

    ($manifiesto | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $Path -Encoding UTF8
    Write-Log "Escrito: $Path" "SUCCESS"
    Write-Host ""
    foreach ($k in $runtimes.Keys) { Write-Host ("  {0,-10} {1}" -f $k, $runtimes[$k]) -ForegroundColor Gray }
    Write-Host ""
    Write-Host "Guardalo en el repositorio del proyecto: la receta viaja con el." -ForegroundColor Gray
    Write-Host "En otra maquina, con el kit al lado:  .\Restore-Env.bat" -ForegroundColor White
    Write-Host ""
    exit 0
}

# --------------------------------------------------------------------------
# Restaurar
# --------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Log "No existe el manifiesto: $Path" "ERROR"
    Write-Log "  Crea uno a partir de lo que ya tengas instalado:" "WARN"
    Write-Log "    .\Restore-Env.bat -Save" "WARN"
    exit 1
}

Write-Log "Manifiesto: $Path"

try {
    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}
catch {
    Write-Log "El manifiesto no es JSON valido: $($_.Exception.Message)" "ERROR"
    exit 1
}

$plan = Read-DevEnvManifest -Config $config

if ($plan.Errores.Count -gt 0) {
    Write-Log "El manifiesto tiene problemas:" "ERROR"
    foreach ($e in $plan.Errores) { Write-Log "  $e" "ERROR" }
    # Se para en vez de instalar lo que si se entiende: dejar el entorno a
    # medias sin decir por que es justo lo contrario de para lo que sirve esto.
    exit 1
}

if ($plan.Runtimes.Count -eq 0) {
    Write-Log "El manifiesto no pide ningun runtime." "WARN"
    exit 0
}

if ($config.descripcion) {
    Write-Host ""
    Write-Host "  $($config.descripcion)" -ForegroundColor Gray
}

Write-Host ""
Write-Host "Se va a instalar:" -ForegroundColor Yellow
Write-Host ""
foreach ($r in $plan.Runtimes) {
    $yaHay = @(Get-InstalledRuntimeLines -Entrada $r.Entrada)
    $estado = if ($yaHay -contains $r.Version) { "ya instalado" }
              elseif ($yaHay.Count -gt 0)      { "hay $($yaHay -join ', ')" }
              else                             { "" }

    Write-Host ("  {0,-12} {1,-10} {2}" -f $r.Nombre, $r.Version, $estado) -ForegroundColor White
    if ($r.Paquetes) { Write-Host ("               paquetes: {0}" -f $r.Paquetes) -ForegroundColor DarkGray }
}
Write-Host ""
Write-Host "Cada uno se instala con su propio Setup-*Env, asi que hereda el proxy," -ForegroundColor DarkGray
Write-Host "el espejo interno, los checksums y la copia del PATH." -ForegroundColor DarkGray
Write-Host ""

if ($WhatIf) {
    Write-Host "-WhatIf: no se ha tocado nada." -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

if (-not $Force) {
    $answer = Read-Host "Continuo? (escribe SI)"
    if ($answer -ne 'SI') {
        Write-Host "Cancelado. No se ha tocado nada." -ForegroundColor Yellow
        exit 0
    }
    Write-Host ""
}

$ok = @()
$fallidos = @()

foreach ($r in $plan.Runtimes) {
    Write-Host ""
    Write-Host "--- $($r.Nombre) $($r.Version) ---" -ForegroundColor Cyan

    $script = Join-Path $PSScriptRoot $r.Entrada.Script
    if (-not (Test-Path -LiteralPath $script)) {
        Write-Log "Falta $($r.Entrada.Script) en el kit" "ERROR"
        $fallidos += $r.Nombre
        continue
    }

    $argumentos = @{}
    # 'latest' significa "la que decida el propio Setup": se omite el parametro.
    if ($r.Entrada.ParamVersion -and $r.Version -and $r.Version -ne 'latest') {
        $argumentos[$r.Entrada.ParamVersion] = $r.Version
    }
    if ($r.Paquetes -and $r.Entrada.ParamPaquetes) {
        $argumentos[$r.Entrada.ParamPaquetes] = $r.Paquetes
    }

    try {
        & $script @argumentos
        $rc = $LASTEXITCODE
    }
    catch {
        Write-Log "$($r.Nombre) fallo: $($_.Exception.Message)" "ERROR"
        $rc = 1
    }

    if ($rc -eq 0) { $ok += $r.Nombre }
    else {
        $fallidos += $r.Nombre
        # Se sigue con los demas a proposito: es mas util quedarse con cuatro de
        # cinco y saber cual falta, que parar en el primer tropiezo.
        Write-Log "$($r.Nombre) termino con codigo $rc; se continua con el resto" "WARN"
    }
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
if ($fallidos.Count -eq 0) {
    Write-Host "  ENTORNO REPRODUCIDO" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Instalados: $($ok -join ', ')" -ForegroundColor Green
    Write-Host ""
    Write-Host "Comprueba el resultado con:  .\Doctor-Env.bat" -ForegroundColor Gray
    Write-Host ""
    exit 0
}

Write-Host "  ENTORNO INCOMPLETO" -ForegroundColor Yellow
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
if ($ok.Count -gt 0) { Write-Host "Instalados: $($ok -join ', ')" -ForegroundColor Green }
Write-Host "Fallaron:   $($fallidos -join ', ')" -ForegroundColor Red
Write-Host ""
Write-Host "Mira arriba el motivo de cada uno. Puedes reintentar solo los que" -ForegroundColor Gray
Write-Host "fallaron con su propio Setup-*Env.bat, o volver a lanzar este comando:" -ForegroundColor Gray
Write-Host "lo que ya esta instalado no se vuelve a descargar." -ForegroundColor Gray
Write-Host ""
exit 1
