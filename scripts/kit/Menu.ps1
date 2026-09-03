#Requires -Version 5.1
<#
.SYNOPSIS
    Menu.ps1 - Menu de consola del kit.
.DESCRIPTION
    El kit tiene 21 comandos y nadie se los sabe de memoria. Esto los reune en
    una pantalla que ademas dice QUE HAY INSTALADO, que es la pregunta con la
    que uno llega.

    No reimplementa nada: cada opcion llama al mismo .bat que se usaria a mano,
    asi que hereda su salida, sus confirmaciones y sus codigos de error. Si
    manana cambia un Setup, el menu no se entera y sigue funcionando.

    La lista de runtimes sale del CATALOGO, no de una lista escrita aqui: uno
    nuevo aparece en el menu por el hecho de estar en el catalogo.

    Es de consola a proposito. Una ventana tendria que capturar y repintar la
    salida del kit -que lleva color, progreso y el informe de Doctor- y eso es
    la mayor parte del trabajo, no la ventana.
.PARAMETER Once
    Ejecuta una opcion y sale, en vez de volver al menu. Util para probarlo.
.EXAMPLE
    .\Menu.ps1
#>

param([switch]$Once)

$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Common.ps1")

# --------------------------------------------------------------------------
# Estado: que hay instalado ahora mismo
# --------------------------------------------------------------------------

function Get-EstadoRuntimes {
    <#
        Devuelve una tabla clave -> version instalada (o $null). Se lee del
        disco en cada vuelta al menu, para que despues de instalar algo se vea
        reflejado sin tener que salir y volver a entrar.
    #>
    $estado = @{}
    foreach ($e in (Get-RuntimeCatalog)) {
        $lineas = @(Get-InstalledRuntimeLines -Entrada $e)
        if ($lineas.Count -eq 0) { $estado[$e.Clave] = $null; continue }
        $estado[$e.Clave] = ($lineas | Sort-Object) -join ', '
    }
    return $estado
}

# --------------------------------------------------------------------------
# Opciones
# --------------------------------------------------------------------------

function Get-Opciones {
    <#
        Cada opcion es: numero, texto, el .bat al que llama y si necesita que le
        pidamos argumentos. Los Setup salen del catalogo; el resto van a mano
        porque no son uno por runtime.
    #>
    $ops = @()
    $n = 1
    foreach ($e in (Get-RuntimeCatalog)) {
        $ops += [PSCustomObject]@{
            Num = $n; Grupo = 'INSTALAR'; Texto = $e.Nombre
            Bat = "Setup-$($e.Carpeta)Env.bat"; Clave = $e.Clave; Pide = 'version'
        }
        $n++
    }

    $ops += [PSCustomObject]@{ Num = 20; Grupo = 'ABRIR';     Texto = 'Abrir un shell';            Bat = $null;                 Clave = $null; Pide = 'runtime' }
    $ops += [PSCustomObject]@{ Num = 21; Grupo = 'ABRIR';     Texto = 'Activar en toda terminal';  Bat = 'Use-Env.bat';         Clave = $null; Pide = 'useenv' }
    $ops += [PSCustomObject]@{ Num = 22; Grupo = 'ABRIR';     Texto = 'Desactivar todo (Use-Env)'; Bat = 'Use-Env.bat';         Clave = $null; Pide = 'off' }
    $ops += [PSCustomObject]@{ Num = 23; Grupo = 'ABRIR';     Texto = 'Dar los JDK a VS Code';     Bat = 'Use-VSCodeJava.bat';  Clave = $null; Pide = $null }
    $ops += [PSCustomObject]@{ Num = 24; Grupo = 'ABRIR';     Texto = 'CA de la empresa en Java';  Bat = 'Use-CorpCert.bat';    Clave = $null; Pide = $null }

    $ops += [PSCustomObject]@{ Num = 30; Grupo = 'MANTENER';  Texto = 'Diagnostico';               Bat = 'Doctor-Env.bat';      Clave = $null; Pide = $null }
    $ops += [PSCustomObject]@{ Num = 31; Grupo = 'MANTENER';  Texto = 'Diagnostico y reparar';     Bat = 'Doctor-Env.bat';      Clave = $null; Pide = 'fix' }
    $ops += [PSCustomObject]@{ Num = 32; Grupo = 'MANTENER';  Texto = 'Informe para un ticket';    Bat = 'Doctor-Env.bat';      Clave = $null; Pide = 'report' }
    $ops += [PSCustomObject]@{ Num = 33; Grupo = 'MANTENER';  Texto = 'Ver actualizaciones';       Bat = 'Update-Env.bat';      Clave = $null; Pide = $null }
    $ops += [PSCustomObject]@{ Num = 34; Grupo = 'MANTENER';  Texto = 'Desinstalar';               Bat = 'Uninstall-Env.bat';   Clave = $null; Pide = 'desinstalar' }

    # Empezar va aparte y con el 0: es lo primero que hace falta en un equipo
    # nuevo, y enterrado en ENTORNO no lo encontraba nadie. Ademas, meterlo con
    # el 39 delante del 40 dejaba esa decena empezando en un numero raro.
    $ops += [PSCustomObject]@{ Num = 0;  Grupo = 'PRIMERO';   Texto = 'Empezar en un equipo nuevo'; Bat = 'Empezar.bat';        Clave = $null; Pide = $null }

    $ops += [PSCustomObject]@{ Num = 40; Grupo = 'ENTORNO';   Texto = 'Reproducir un devenv.json'; Bat = 'Restore-Env.bat';     Clave = $null; Pide = 'ruta' }
    $ops += [PSCustomObject]@{ Num = 41; Grupo = 'ENTORNO';   Texto = 'Guardar devenv.json';       Bat = 'Restore-Env.bat';     Clave = $null; Pide = 'save' }
    $ops += [PSCustomObject]@{ Num = 42; Grupo = 'ENTORNO';   Texto = 'Fijar versiones (lock)';    Bat = 'Restore-Env.bat';     Clave = $null; Pide = 'lock' }
    $ops += [PSCustomObject]@{ Num = 43; Grupo = 'ENTORNO';   Texto = 'Llevar a otra maquina';     Bat = 'Export-Env.bat';      Clave = $null; Pide = $null }
    $ops += [PSCustomObject]@{ Num = 44; Grupo = 'ENTORNO';   Texto = 'Traer de otra maquina';     Bat = 'Import-Env.bat';      Clave = $null; Pide = 'ruta-zip' }

    $ops += [PSCustomObject]@{ Num = 50; Grupo = 'OTROS';     Texto = 'Instalar software sin admin'; Bat = 'Install-NoAdmin.bat'; Clave = $null; Pide = 'instalador' }
    $ops += [PSCustomObject]@{ Num = 51; Grupo = 'OTROS';     Texto = 'Pruebas del kit';           Bat = 'Run-Tests.bat';       Clave = $null; Pide = $null }

    return $ops
}

# --------------------------------------------------------------------------
# Pintado
# --------------------------------------------------------------------------

function Show-Menu {
    param($Opciones, $Estado)

    Clear-Host
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "   CriisDevKit v$KitVersion" -NoNewline -ForegroundColor Cyan
    Write-Host "   -   entornos de desarrollo sin admin" -ForegroundColor DarkGray
    Write-Host "  ============================================================" -ForegroundColor Cyan

    # Lo instalado, arriba del todo: es la pregunta con la que uno llega.
    $puestos = @($Estado.Keys | Where-Object { $Estado[$_] } | Sort-Object)
    Write-Host ""
    if ($puestos.Count -eq 0) {
        Write-Host "   Instalado: nada todavia" -ForegroundColor DarkGray
    }
    else {
        Write-Host "   Instalado: " -NoNewline -ForegroundColor DarkGray
        Write-Host (($puestos | ForEach-Object { "$_ $($Estado[$_])" }) -join "   ") -ForegroundColor Green
    }

    # El arranque guiado, antes que nada: en un equipo nuevo es lo unico que
    # hace falta saber, y el resto del menu se puede ignorar.
    foreach ($o in ($Opciones | Where-Object { $_.Grupo -eq 'PRIMERO' })) {
        Write-Host ""
        Write-Host ("    {0,2}  {1}" -f $o.Num, $o.Texto) -ForegroundColor Cyan
    }

    $setup = @($Opciones | Where-Object { $_.Grupo -eq 'INSTALAR' })
    Write-Host ""
    Write-Host "   INSTALAR" -ForegroundColor Yellow

    # Dos columnas: nueve runtimes en una sola lista dejan media pantalla vacia.
    $mitad = [math]::Ceiling($setup.Count / 2)
    for ($i = 0; $i -lt $mitad; $i++) {
        $linea = "    " + (Format-Opcion -Op $setup[$i] -Estado $Estado)
        if ($i + $mitad -lt $setup.Count) {
            $linea = $linea.PadRight(34) + (Format-Opcion -Op $setup[$i + $mitad] -Estado $Estado)
        }
        Write-Host $linea
    }

    foreach ($g in @('ABRIR', 'MANTENER', 'ENTORNO', 'OTROS')) {
        Write-Host ""
        Write-Host "   $g" -ForegroundColor Yellow
        foreach ($o in ($Opciones | Where-Object { $_.Grupo -eq $g })) {
            Write-Host ("    {0,2}  {1}" -f $o.Num, $o.Texto)
        }
    }

    Write-Host ""
    Write-Host "    q  Salir" -ForegroundColor DarkGray
    Write-Host ""
}

function Format-Opcion {
    param($Op, $Estado)

    $marca = if ($Op.Clave -and $Estado[$Op.Clave]) { "[$($Estado[$Op.Clave])]" } else { '' }
    return ("{0,2}  {1} {2}" -f $Op.Num, $Op.Texto.PadRight(10), $marca)
}

# --------------------------------------------------------------------------
# Ejecucion
# --------------------------------------------------------------------------

function Read-Texto {
    param([string]$Prompt, [string]$PorDefecto)

    $t = if ($PorDefecto) { Read-Host "$Prompt [$PorDefecto]" } else { Read-Host $Prompt }
    if ([string]::IsNullOrWhiteSpace($t)) { return $PorDefecto }
    return $t.Trim()
}

function Invoke-Opcion {
    <#
        Ejecuta la opcion elegida. NO devuelve nada, y es a proposito: lo que
        imprime el .bat sale por el flujo de salida de esta funcion, asi que
        cualquier cosa que capture ese flujo -un "| Out-Null", o asignar la
        llamada a una variable- se lleva por delante toda la salida del comando.
        Paso: se veia la linea "> Doctor-Env.bat" (que es Write-Host, y por eso
        sobrevivia) y despues nada.
    #>
    param($Op, $Estado)

    # $DevKitRoot y no contar Split-Path: este archivo vive en scripts\kit\ y el
    # calculo a mano se rompe en cuanto cambia de sitio.
    $raiz = $DevKitRoot
    $argumentos = @()

    switch ($Op.Pide) {
        'version' {
            $e = @(Get-RuntimeCatalog | Where-Object { $_.Clave -eq $Op.Clave })[0]
            Write-Host ""
            Write-Host "   Version: vacio = la ultima. Admite la linea o la exacta." -ForegroundColor DarkGray
            $v = Read-Texto -Prompt "   $($e.Nombre)"
            if ($v) { $argumentos = @("-$($e.ParamVersion)", $v) }
        }
        'runtime' {
            $conShell = @(Get-RuntimeCatalog | Where-Object { $Estado[$_.Clave] })
            if ($conShell.Count -eq 0) {
                Write-Host ""
                Write-Host "   No hay nada instalado que abrir." -ForegroundColor Yellow
                return
            }
            Write-Host ""
            for ($i = 0; $i -lt $conShell.Count; $i++) {
                Write-Host ("    {0}  {1} {2}" -f ($i + 1), $conShell[$i].Nombre, $Estado[$conShell[$i].Clave])
            }
            $s = Read-Texto -Prompt "   Cual"
            $idx = 0
            if (-not [int]::TryParse($s, [ref]$idx) -or $idx -lt 1 -or $idx -gt $conShell.Count) { return }
            $Op = [PSCustomObject]@{ Bat = "Start-$($conShell[$idx - 1].Carpeta)Env.bat" }
        }
        'useenv' {
            $puestos = @(Get-RuntimeCatalog | Where-Object { $Estado[$_.Clave] })
            if ($puestos.Count -eq 0) {
                Write-Host ""
                Write-Host "   No hay nada instalado que activar." -ForegroundColor Yellow
                return
            }
            Write-Host ""
            for ($i = 0; $i -lt $puestos.Count; $i++) {
                Write-Host ("    {0}  {1} {2}" -f ($i + 1), $puestos[$i].Nombre, $Estado[$puestos[$i].Clave])
            }
            $s = Read-Texto -Prompt "   Cual"
            $idx = 0
            if (-not [int]::TryParse($s, [ref]$idx) -or $idx -lt 1 -or $idx -gt $puestos.Count) { return }
            $e = $puestos[$idx - 1]
            # Si hay varias lineas instaladas se toma la primera; el usuario
            # siempre puede llamar a Use-Env a mano para elegir otra.
            $ver = ($Estado[$e.Clave] -split ',')[0].Trim()
            $argumentos = @('-Runtime', $e.Carpeta, '-Version', $ver)
        }
        'off'          { $argumentos = @('-Off') }
        'fix'          { $argumentos = @('-Fix') }
        'report'       { $argumentos = @('-Report') }
        'save'         { $argumentos = @('-Save') }
        'lock'         { $argumentos = @('-Lock') }
        'ruta'         { $r = Read-Texto -Prompt "   Ruta del devenv.json (vacio = carpeta actual)"; if ($r) { $argumentos = @('-Path', $r) } }
        'ruta-zip'     { $r = Read-Texto -Prompt "   Ruta del .zip"; if (-not $r) { return }; $argumentos = @('-Path', $r) }
        'instalador'   { $r = Read-Texto -Prompt "   Ruta del instalador"; if (-not $r) { return }; $argumentos = @('-Path', $r) }
        'desinstalar'  {
            Write-Host ""
            Write-Host "   Vacio = TODO lo que instalo el kit." -ForegroundColor DarkGray
            $r = Read-Texto -Prompt "   Runtime"
            $argumentos = if ($r) { @('-Runtime', $r, '-All') } else { @('-Everything') }
        }
    }

    # Por el resolutor: la tabla de opciones nombra los .bat a secas, y estan
    # repartidos entre la raiz (Empezar, Menu) y bin\ (los otros 29).
    $bat = Resolve-KitCommand -Nombre $Op.Bat
    if (-not $bat) { $bat = Join-Path $raiz $Op.Bat }
    if (-not (Test-Path -LiteralPath $bat)) {
        Write-Host ""
        Write-Host "   Falta $($Op.Bat) en el kit." -ForegroundColor Red
        return
    }

    Write-Host ""
    Write-Host "   > $($Op.Bat) $($argumentos -join ' ')" -ForegroundColor DarkGray
    Write-Host ""

    # Se llama al .bat y no al .ps1 para que el comando sea EXACTAMENTE el que
    # se usaria a mano: mismo pause, mismo codigo de salida, misma salida.
    # CRIISDEVKIT_NOPAUSE no se define: aqui el pause es util, deja leer.
    & $bat @argumentos
}

# --------------------------------------------------------------------------

$opciones = Get-Opciones

while ($true) {
    $estado = Get-EstadoRuntimes
    Show-Menu -Opciones $opciones -Estado $estado

    $sel = Read-Host "   Opcion"
    if ([string]::IsNullOrWhiteSpace($sel)) { continue }
    $sel = $sel.Trim()

    if ($sel -in @('q', 'Q', 'salir', 'exit')) {
        Write-Host ""
        break
    }

    $num = 0
    if (-not [int]::TryParse($sel, [ref]$num)) {
        Write-Host ""
        Write-Host "   '$sel' no es una opcion." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        continue
    }

    $op = @($opciones | Where-Object { $_.Num -eq $num })
    if ($op.Count -eq 0) {
        Write-Host ""
        Write-Host "   No hay opcion $num." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        continue
    }

    Invoke-Opcion -Op $op[0] -Estado $estado

    if ($Once) { break }

    Write-Host ""
    Read-Host "   Pulsa Intro para volver al menu" | Out-Null
}
