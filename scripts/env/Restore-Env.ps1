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
.PARAMETER Lock
    En vez de instalar, escribe un devenv.lock.json con las versiones EXACTAS
    instaladas. El manifiesto dice "Python 3.12"; el lock dice "3.12.10". Es lo
    que hace que dos maquinas monten lo mismo y no dos parches distintos.
.PARAMETER NoLock
    Ignora el devenv.lock.json aunque exista, y usa solo el devenv.json.
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

    [switch]$Lock,

    [switch]$NoLock,

    [switch]$Force,

    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Common.ps1")

if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = Join-Path (Get-Location).Path "devenv.json"
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Restore-Env - Entorno desde devenv.json" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

$LockPath = Join-Path (Split-Path -Parent $Path) "devenv.lock.json"

# --------------------------------------------------------------------------
# -Lock: escribir el lockfile con las versiones exactas
# --------------------------------------------------------------------------

if ($Lock) {
    $runtimes = [ordered]@{}
    $noFijables = @()

    $ataduras = Get-BuildToolJavaBindings

    foreach ($e in (Get-RuntimeCatalog)) {
        $lineas = @(Get-InstalledRuntimeLines -Entrada $e)
        if ($lineas.Count -eq 0) { continue }

        # Todas las lineas, de menor a mayor. Antes se fijaba solo la mas alta:
        # un lock que dice "Java 25" no reproduce una maquina que tiene el 21 y
        # el 25, que es justo lo que se quiere fijar.
        $ordenadas = @($lineas | Sort-Object { try { [version]($_ -replace '^(\d+)$', '$1.0') } catch { [version]'0.0' } })

        $entradas = @()
        foreach ($linea in $ordenadas) {
            $exacta = Get-InstalledRuntimeVersion -Entrada $e -Linea $linea
            $sha    = Get-InstalledRuntimeSha256 -Entrada $e -Linea $linea

            $entrada = [ordered]@{ linea = $linea }
            if ($exacta) { $entrada['exacta'] = $exacta }
            if ($sha)    { $entrada['sha256'] = $sha }
            $entrada['fijable'] = [bool]$e.Fijable
            if ($ataduras.Contains($e.Clave)) { $entrada['java'] = $ataduras[$e.Clave] }

            $entradas += $entrada
        }

        $runtimes[$e.Clave] = if ($entradas.Count -eq 1) { $entradas[0] } else { $entradas }
        if (-not $e.Fijable) { $noFijables += $e.Nombre }
    }

    if ($runtimes.Count -eq 0) {
        Write-Log "No hay nada instalado por el kit que fijar." "ERROR"
        exit 1
    }

    $lockObj = [ordered]@{
        version  = 1
        generado = (Get-Date -Format "o")
        maquina  = $env:COMPUTERNAME
        _nota    = "Versiones exactas instaladas. Restore-Env lo usa antes que devenv.json. 'fijable' dice si el Setup de ese runtime admite fijar la version exacta o solo su linea."
        runtimes = $runtimes
    }

    if ($WhatIf) {
        Write-Host "Se escribiria en $LockPath :" -ForegroundColor Yellow
        Write-Host ""
        ($lockObj | ConvertTo-Json -Depth 5) -split "`n" | ForEach-Object { Write-Host "  $_" }
        Write-Host ""
        Write-Host "-WhatIf: no se ha tocado nada." -ForegroundColor Cyan
        Write-Host ""
        exit 0
    }

    ($lockObj | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $LockPath -Encoding UTF8
    Write-Log "Escrito: $LockPath" "SUCCESS"
    Write-Host ""
    foreach ($k in $runtimes.Keys) {
        foreach ($r in @($runtimes[$k])) {
            $ex = if ($r.exacta) { $r.exacta } else { '(sin determinar)' }
            $marca = if ($r.fijable) { '' } else { '   <- solo se puede fijar su linea' }
            Write-Host ("  {0,-10} {1,-18} {2}" -f $k, $ex, $marca) -ForegroundColor Gray
            if ($r.sha256) { Write-Host ("             sha256 {0}" -f $r.sha256) -ForegroundColor DarkGray }
            if ($r.java)   { Write-Host ("             su shell por defecto va al JDK {0}" -f $r.java) -ForegroundColor DarkGray }
        }
    }
    Write-Host ""
    if ($noFijables.Count -gt 0) {
        $verbo = if ($noFijables.Count -eq 1) { "no admite" } else { "no admiten" }
        Write-Host "Aviso honesto: $($noFijables -join ', ') $verbo fijar la version exacta." -ForegroundColor Yellow
        Write-Host "Su Setup solo acepta la linea (o el canal), asi que en otra maquina" -ForegroundColor Gray
        Write-Host "podria quedar en un parche distinto. Queda anotado en el lock para" -ForegroundColor Gray
        Write-Host "que al menos se vea la diferencia." -ForegroundColor Gray
        Write-Host ""
    }
    Write-Host "El checksum solo consta donde el kit lo anoto al instalar (hoy, Python)." -ForegroundColor DarkGray
    Write-Host "Los demas se verifican al descargar contra la fuente oficial, que es lo" -ForegroundColor DarkGray
    Write-Host "que garantiza la integridad; el lock garantiza la VERSION." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Guardalo junto al devenv.json, en el repositorio del proyecto." -ForegroundColor Gray
    Write-Host ""
    exit 0
}

# --------------------------------------------------------------------------
# -Save: escribir el manifiesto a partir de lo instalado
# --------------------------------------------------------------------------

if ($Save) {
    $runtimes = [ordered]@{}
    foreach ($e in (Get-RuntimeCatalog)) {
        $lineas = @(Get-InstalledRuntimeLines -Entrada $e)
        if ($lineas.Count -eq 0) { continue }

        # Se anotan TODAS, de menor a mayor. Antes se guardaba solo la mas alta,
        # y entonces una maquina con dos JDK -el caso de trabajar en proyectos
        # con Javas distintos- no se podia reproducir a partir de su manifiesto.
        $ordenadas = @($lineas | Sort-Object {
            try { [version]($_ -replace '^(\d+)$', '$1.0') } catch { [version]'0.0' }
        })

        # Una sola se escribe suelta: un array de un elemento seria ruido.
        $runtimes[$e.Clave] = if ($ordenadas.Count -eq 1) { $ordenadas[0] } else { $ordenadas }
    }

    if ($runtimes.Count -eq 0) {
        Write-Log "No hay nada instalado por el kit que anotar." "ERROR"
        Write-Log "  Instala algo primero, por ejemplo:  .\bin\Setup-PythonEnv.bat" "WARN"
        exit 1
    }

    $manifiesto = [ordered]@{
        version     = 1
        descripcion = "Entorno de desarrollo. Reproducelo con:  Restore-Env.bat"
        runtimes    = $runtimes
    }

    # A que JDK apunta hoy el shell por defecto de Maven y de Gradle. Se lee del
    # propio shell y no se supone: es el dato que decide con que Java compilan.
    $java = Get-BuildToolJavaBindings
    if ($java.Count -gt 0) { $manifiesto['java'] = $java }

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
    foreach ($k in $runtimes.Keys) {
        Write-Host ("  {0,-10} {1}" -f $k, (@($runtimes[$k]) -join ', ')) -ForegroundColor Gray
        if ($manifiesto.java -and $manifiesto.java.Contains($k)) {
            Write-Host ("             su shell por defecto va al JDK {0}" -f $manifiesto.java[$k]) -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    Write-Host "Guardalo en el repositorio del proyecto: la receta viaja con el." -ForegroundColor Gray
    Write-Host "En otra maquina, con el kit al lado:  .\bin\Restore-Env.bat" -ForegroundColor White
    Write-Host ""
    exit 0
}

# --------------------------------------------------------------------------
# Restaurar
# --------------------------------------------------------------------------

# El lock manda sobre el manifiesto cuando existe, igual que un package-lock
# sobre un package.json: es lo que hace que dos maquinas monten lo mismo. Con
# -NoLock se ignora a proposito.
$usandoLock = (-not $NoLock) -and (Test-Path -LiteralPath $LockPath)
$archivo    = if ($usandoLock) { $LockPath } else { $Path }

if (-not (Test-Path -LiteralPath $archivo)) {
    Write-Log "No existe el manifiesto: $Path" "ERROR"
    Write-Log "  Crea uno a partir de lo que ya tengas instalado:" "WARN"
    Write-Log "    .\bin\Restore-Env.bat -Save" "WARN"
    exit 1
}

if ($usandoLock) {
    Write-Log "Lock: $LockPath" "SUCCESS"
    Write-Log "  Manda sobre el devenv.json. Para ignorarlo:  -NoLock"
}
else {
    Write-Log "Manifiesto: $archivo"
    if ($NoLock -and (Test-Path -LiteralPath $LockPath)) {
        Write-Log "  -NoLock: hay un devenv.lock.json y se esta ignorando." "WARN"
    }
    elseif (-not (Test-Path -LiteralPath $LockPath)) {
        Write-Log "  Sin lock: se instalara la ultima version de cada linea."
        Write-Log "  Para fijar las exactas:  .\bin\Restore-Env.bat -Lock"
    }
}

try {
    $config = Get-Content -LiteralPath $archivo -Raw | ConvertFrom-Json
}
catch {
    Write-Log "El archivo no es JSON valido: $($_.Exception.Message)" "ERROR"
    exit 1
}

$plan = if ($usandoLock) { Read-DevEnvLock -Config $config } else { Read-DevEnvManifest -Config $config }

if ($plan.Errores.Count -gt 0) {
    Write-Log "$(if ($usandoLock) { 'El lock' } else { 'El manifiesto' }) tiene problemas:" "ERROR"
    foreach ($e in $plan.Errores) { Write-Log "  $e" "ERROR" }
    # Se para en vez de instalar lo que si se entiende: dejar el entorno a
    # medias sin decir por que es justo lo contrario de para lo que sirve esto.
    exit 1
}

foreach ($a in $plan.Avisos) { Write-Log "  $a" "WARN" }

if ($plan.Runtimes.Count -eq 0) {
    Write-Log "No pide ningun runtime." "WARN"
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
    $linea = if ($r.Linea) { $r.Linea } else { $r.Version }
    $estado = if ($yaHay -contains $linea) { "ya instalado" }
              elseif ($yaHay.Count -gt 0)  { "hay $($yaHay -join ', ')" }
              else                         { "" }

    Write-Host ("  {0,-12} {1,-14} {2}" -f $r.Nombre, $r.Version, $estado) -ForegroundColor White
    if ($usandoLock -and -not $r.Fijado) {
        # No se puede prometer un pin que el Setup no admite.
        Write-Host ("               el lock anota {0}, pero su Setup solo acepta la linea" -f $r.Exacta) -ForegroundColor DarkYellow
    }
    if ($r.Paquetes) { Write-Host ("               paquetes: {0}" -f $r.Paquetes) -ForegroundColor DarkGray }
    if ($r.Java)     { Write-Host ("               su shell por defecto ira al JDK {0}" -f $r.Java) -ForegroundColor DarkGray }
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

    # Por el resolutor y no pegando "scripts\": el catalogo guarda el nombre a
    # secas y quien lo lee no tiene por que saber en que subcarpeta vive.
    $script = Resolve-KitScript -Nombre $r.Entrada.Script
    if (-not $script -or -not (Test-Path -LiteralPath $script)) {
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
    # A que JDK va el shell por defecto de Maven o Gradle. Sin esto se quedaban
    # con el mas alto instalado, que no tiene por que ser el del proyecto.
    if ($r.Java -and $r.Entrada.ParamJava) {
        $argumentos[$r.Entrada.ParamJava] = $r.Java
    }

    try {
        # $LASTEXITCODE se pone a 0 ANTES de llamar. Un .ps1 que termina sin un
        # "exit" explicito no lo toca, asi que se quedaba el de la ultima orden
        # nativa que hubiera corrido dentro: Setup-JavaEnv instalaba bien y
        # Restore-Env lo daba por fallido con "termino con codigo " (vacio).
        $global:LASTEXITCODE = 0
        & $script @argumentos
        $rc = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
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
    Write-Host "Comprueba el resultado con:  .\bin\Doctor-Env.bat" -ForegroundColor Gray
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
