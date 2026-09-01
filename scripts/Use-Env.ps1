#Requires -Version 5.1
<#
.SYNOPSIS
    Use-Env.ps1 - Hace que la version del kit responda tambien en terminales normales.
.DESCRIPTION
    El PATH de un proceso es MAQUINA + USUARIO, en ese orden, asi que lo que el
    kit escribe en el PATH de usuario nunca puede ganarle a algo instalado con
    admin (por ejemplo C:\Program Files\nodejs).

    Lo que si se puede sin admin es ejecutar codigo AL ABRIR cada terminal, que
    ocurre despues de que Windows haya compuesto el PATH. Ahi si se puede
    anteponer la version del kit y ganar.

    Se enganchan dos sitios, ambos de usuario:
      - PowerShell : un bloque marcado en el perfil CurrentUserAllHosts.
      - cmd.exe    : la clave HKCU\Software\Microsoft\Command Processor\AutoRun.

    Los scripts generados viven en %LOCALAPPDATA%\AssassinSkipAdm, fuera del kit.
    Toman las rutas del shell que ya genera el setup, para no duplicar criterios.
.PARAMETER Runtime
    Angular, Python, Java, Node o Git.
.PARAMETER Version
    Version a activar (ej: 22 para Angular, 3.12 para Python, 2.55 para Git).
.PARAMETER Off
    Desactiva. Sin -Runtime desactiva todo y retira los enganches.
.PARAMETER Force
    No pide confirmacion.
.EXAMPLE
    .\Use-Env.ps1
.EXAMPLE
    .\Use-Env.ps1 -Runtime Angular -Version 22
.EXAMPLE
    .\Use-Env.ps1 -Off
#>

param(
    [ValidateSet('Angular', 'Python', 'Java', 'Node', 'Git', 'Maven', 'Gradle', 'Dotnet', 'VSCode')]
    [string]$Runtime,

    [string]$Version,

    [switch]$Off,

    [switch]$Force
)

$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

$StateDir     = Join-Path $env:LOCALAPPDATA "AssassinSkipAdm"
$StateFile    = Join-Path $StateDir "active.json"
$ActivatePs1  = Join-Path $StateDir "activate.ps1"
$ActivateCmd  = Join-Path $StateDir "activate.cmd"

$MarkerStart  = '# >>> AssassinSkipAdm >>>'
$MarkerEnd    = '# <<< AssassinSkipAdm <<<'
$GuardVar     = 'ASSASSINSKIPADM_ACTIVE'

$ProfilePath  = $PROFILE.CurrentUserAllHosts
$AutoRunKey   = 'Software\Microsoft\Command Processor'

# --------------------------------------------------------------------------
# Estado
# --------------------------------------------------------------------------

function Get-State {
    if (-not (Test-Path -LiteralPath $StateFile)) { return @{} }
    try {
        $json = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
        $h = @{}
        foreach ($p in $json.PSObject.Properties) { $h[$p.Name] = [string]$p.Value }
        return $h
    }
    catch {
        return @{}
    }
}

function Save-State {
    param([hashtable]$State)

    if (-not (Test-Path -LiteralPath $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    }
    ($State | ConvertTo-Json) | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

# --------------------------------------------------------------------------
# Lectura del shell generado por el setup
# --------------------------------------------------------------------------

function Get-ShellEnvironment {
    <#
        Extrae del shell-vN.bat / pyXYZ-shell.bat las rutas que antepone y las
        variables que define. Se lee de ahi en vez de recalcularlo para que
        "activar" y "abrir el shell" den exactamente el mismo entorno.

        Las comillas del set van OPCIONALES en la expresion regular a proposito:
        los shells nuevos usan set "VAR=..." pero los generados por una version
        anterior del kit no llevan comillas, y seguirian en disco. Sin esa
        tolerancia, actualizar el kit dejaria de encontrar las rutas y Use-Env
        no activaria nada.

        El ConvertFrom-CmdLiteral deshace el %% con que se escapa el porcentaje
        al generar: sin el, una ruta con porcentaje se reescaparia en cada pasada.
    #>
    param([Parameter(Mandatory=$true)][string]$ShellBat)

    if (-not (Test-Path -LiteralPath $ShellBat)) { return $null }

    $paths = @()
    $vars  = @{}

    foreach ($line in (Get-Content -LiteralPath $ShellBat)) {
        if ($line -match '^\s*set\s+"?PATH=(.+?);?%PATH%"?\s*$') {
            $paths = @($Matches[1] -split ';' |
                Where-Object { $_.Trim() -ne '' } |
                ForEach-Object { ConvertFrom-CmdLiteral $_ })
        }
        elseif ($line -match '^\s*set\s+"?(NPM_CONFIG_[A-Z_]+|JAVA_HOME|DOTNET_ROOT|DOTNET_CLI_TELEMETRY_OPTOUT|VSCODE_PORTABLE)=(.+?)"?\s*$') {
            $vars[$Matches[1]] = ConvertFrom-CmdLiteral $Matches[2]
        }
    }

    if ($paths.Count -eq 0) { return $null }

    return [PSCustomObject]@{ Paths = $paths; Vars = $vars }
}

function Get-RuntimeShell {
    param([string]$Rt, [string]$Ver)

    if ($Rt -eq 'Angular') {
        return (Join-Path $WorkspaceRoot "Angular\angular-v$Ver\shell-v$Ver.bat")
    }
    if ($Rt -eq 'Java') {
        return (Join-Path $WorkspaceRoot "Java\jdk-$Ver\java$Ver-shell.bat")
    }
    if ($Rt -eq 'Node') {
        return (Join-Path $WorkspaceRoot "Node\node-$Ver\node$Ver-shell.bat")
    }
    if ($Rt -eq 'Git') {
        return (Join-Path $WorkspaceRoot "Git\git-$Ver\git$($Ver -replace '\.','')-shell.bat")
    }
    if ($Rt -eq 'Maven') {
        return (Join-Path $WorkspaceRoot "Maven\maven-$Ver\mvn$($Ver -replace '\.','')-shell.bat")
    }
    if ($Rt -eq 'Gradle') {
        return (Join-Path $WorkspaceRoot "Gradle\gradle-$Ver\gradle$($Ver -replace '\.','')-shell.bat")
    }
    if ($Rt -eq 'Dotnet') {
        return (Join-Path $WorkspaceRoot "Dotnet\dotnet-$Ver\dotnet$($Ver -replace '\.','')-shell.bat")
    }
    if ($Rt -eq 'VSCode') {
        return (Join-Path $WorkspaceRoot "VSCode\vscode-$Ver\code$($Ver -replace '\.','')-shell.bat")
    }
    $tag = $Ver -replace '\.', ''
    return (Join-Path $WorkspaceRoot "Python\python-$Ver\py$tag-shell.bat")
}

function Get-VersionEjemplo {
    # Solo para el mensaje de ayuda cuando falta -Version.
    param([string]$Rt)
    switch ($Rt) {
        'Angular' { return '22' }
        'Java'    { return '21' }
        'Node'    { return '22' }
        'Git'     { return '2.55' }
        'Maven'   { return '3.9' }
        'Gradle'  { return '9.7' }
        'Dotnet'  { return '10.0' }
        'VSCode'  { return '1.135' }
        default   { return '3.12' }
    }
}

# --------------------------------------------------------------------------
# Generacion de los scripts de activacion
# --------------------------------------------------------------------------

# ConvertTo-PsLiteral y ConvertTo-CmdLiteral viven en Common.ps1, junto a los
# generadores de shells que usan el mismo escapado.

function Write-ActivateScripts {
    param([hashtable]$State)

    $allPaths = @()
    $allVars  = @{}

    # Orden fijo y no el de las claves del estado: define QUE version gana
    # cuando dos runtimes aportan un binario del mismo nombre. Angular va
    # primero porque su carpeta trae su propia Node, que debe ganarle a la
    # suelta si ambas estan activadas.
    foreach ($rt in @('Angular', 'Python', 'Java', 'Node', 'Git', 'Maven', 'Gradle', 'Dotnet', 'VSCode')) {
        if (-not $State.ContainsKey($rt)) { continue }

        $shell = Get-RuntimeShell -Rt $rt -Ver $State[$rt]
        $env2  = Get-ShellEnvironment -ShellBat $shell
        if (-not $env2) {
            Write-Log "No se pudo leer el shell de $rt v$($State[$rt]): $shell" "WARN"
            continue
        }

        $allPaths += $env2.Paths
        foreach ($k in $env2.Vars.Keys) { $allVars[$k] = $env2.Vars[$k] }
    }

    if (-not (Test-Path -LiteralPath $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    }

    # --- PowerShell ---
    $ps = @()
    $ps += "# Generado por Use-Env.ps1 del kit AssassinSkipAdm. No editar a mano."
    $ps += "# Se regenera cada vez que se activa o desactiva una version."
    $ps += ""
    $ps += "# La guarda evita que el PATH crezca en cada shell anidado: los procesos"
    $ps += "# hijos heredan la variable y se saltan el bloque."
    $ps += "if (-not `$env:$GuardVar) {"
    $ps += "    `$env:$GuardVar = '1'"
    $ps += "    `$__paths = @("
    foreach ($p in $allPaths) { $ps += "        '$(ConvertTo-PsLiteral $p)'," }
    $ps += "        `$null"
    $ps += "    )"
    $ps += "    `$__ok = @(`$__paths | Where-Object { `$_ -and (Test-Path -LiteralPath `$_) })"
    $ps += "    if (`$__ok.Count -gt 0) { `$env:PATH = (`$__ok -join ';') + ';' + `$env:PATH }"
    foreach ($k in $allVars.Keys) { $ps += "    `$env:$k = '$(ConvertTo-PsLiteral $allVars[$k])'" }
    $ps += "    Remove-Variable __paths, __ok -ErrorAction SilentlyContinue"
    $ps += "}"
    Set-Content -LiteralPath $ActivatePs1 -Value ($ps -join "`r`n") -Encoding UTF8

    # --- cmd ---
    # Silencio absoluto: AutoRun corre en CADA cmd, incluidos los "cmd /c" que
    # lanzan npm y otras herramientas. Cualquier salida aqui corrompe lo que
    # esos procesos leen.
    $bat = @()
    $bat += "@echo off"
    $bat += "rem Generado por Use-Env.ps1 del kit AssassinSkipAdm. No editar a mano."
    $bat += "if not defined $GuardVar ("
    $bat += "    set `"$GuardVar=1`""
    if ($allPaths.Count -gt 0) {
        $escaped = @($allPaths | ForEach-Object { ConvertTo-CmdLiteral $_ })
        $bat += "    set `"PATH=$($escaped -join ';');%PATH%`""
    }
    foreach ($k in $allVars.Keys) { $bat += "    set `"$k=$(ConvertTo-CmdLiteral $allVars[$k])`"" }
    $bat += ")"
    Set-Content -LiteralPath $ActivateCmd -Value ($bat -join "`r`n") -Encoding ASCII

    return $allPaths
}

# --------------------------------------------------------------------------
# Enganche en PowerShell
# --------------------------------------------------------------------------

function Remove-ProfileHook {
    if (-not (Test-Path -LiteralPath $ProfilePath)) { return $false }

    $content = Get-Content -LiteralPath $ProfilePath -Raw
    if ($content -notlike "*$MarkerStart*") { return $false }

    $pattern = [regex]::Escape($MarkerStart) + '.*?' + [regex]::Escape($MarkerEnd) + '\r?\n?'
    $cleaned = [regex]::Replace($content, $pattern, '', 'Singleline')

    if ([string]::IsNullOrWhiteSpace($cleaned)) {
        Remove-Item -LiteralPath $ProfilePath -Force
        Write-Log "Perfil de PowerShell retirado (habia quedado vacio)" "SUCCESS"
    }
    else {
        # TrimEnd: al quitar el bloque quedaban las lineas en blanco que lo
        # separaban, y el perfil no volvia exactamente a como estaba.
        Set-Content -LiteralPath $ProfilePath -Value $cleaned.TrimEnd() -Encoding UTF8
        Write-Log "Bloque retirado del perfil de PowerShell" "SUCCESS"
    }
    return $true
}

function Add-ProfileHook {
    $dir = Split-Path -Parent $ProfilePath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if (Test-Path -LiteralPath $ProfilePath) {
        $backup = "$ProfilePath.assassinskipadm-backup"
        if (-not (Test-Path -LiteralPath $backup)) {
            Copy-Item -LiteralPath $ProfilePath -Destination $backup -Force
            Write-Log "  Copia del perfil previo: $backup"
        }
        Remove-ProfileHook | Out-Null

        # Hay que volver a comprobar que existe: si el perfil solo contenia
        # NUESTRO bloque, Remove-ProfileHook acaba de borrarlo por quedar vacio,
        # y este Get-Content reventaba el script entero. Se disparaba al activar
        # un SEGUNDO runtime, que es un flujo de lo mas normal.
        $content = if (Test-Path -LiteralPath $ProfilePath) {
            Get-Content -LiteralPath $ProfilePath -Raw
        } else { '' }
    }
    else {
        $content = ''
    }

    # El Test-Path deja el perfil funcionando aunque se borren los generados.
    #
    # Ojo con la construccion: dentro de @( ... ) la coma tiene MAS precedencia
    # que el "+", asi que 'a' + $b + 'c' se convierte en tres elementos sueltos
    # en vez de una cadena. Se usa -f entre parentesis para evitarlo.
    #
    # La ruta va en comillas SIMPLES y escapada. Con comillas dobles, un $ o una
    # tilde invertida en la ruta (ambos legales en Windows) los interpretaria
    # PowerShell al cargar el perfil, en vez de tomarlos como parte del nombre.
    $block = @(
        $MarkerStart,
        ("`$__assassinSkipAdm = '{0}'" -f (ConvertTo-PsLiteral $ActivatePs1)),
        'if (Test-Path -LiteralPath $__assassinSkipAdm) { . $__assassinSkipAdm }',
        'Remove-Variable __assassinSkipAdm -ErrorAction SilentlyContinue',
        $MarkerEnd
    ) -join "`r`n"

    $new = if ([string]::IsNullOrWhiteSpace($content)) { $block } else { $content.TrimEnd() + "`r`n`r`n" + $block }
    Set-Content -LiteralPath $ProfilePath -Value $new -Encoding UTF8

    Write-Log "Enganchado en el perfil de PowerShell" "SUCCESS"
    Write-Log "  $ProfilePath"
}

# --------------------------------------------------------------------------
# Enganche en cmd.exe (AutoRun)
# --------------------------------------------------------------------------

function Get-AutoRun {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($AutoRunKey, $false)
    if (-not $key) { return '' }
    try {
        $v = $key.GetValue('AutoRun', '')
        if ($null -eq $v) { return '' }
        return [string]$v
    }
    finally { $key.Dispose() }
}

function Set-AutoRun {
    param([AllowEmptyString()][string]$Value)

    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($AutoRunKey)
    try {
        if ([string]::IsNullOrWhiteSpace($Value)) {
            $key.DeleteValue('AutoRun', $false)
        }
        else {
            $key.SetValue('AutoRun', $Value, [Microsoft.Win32.RegistryValueKind]::String)
        }
    }
    finally { $key.Dispose() }
}

function Remove-AutoRunHook {
    $current = Get-AutoRun
    if ([string]::IsNullOrWhiteSpace($current)) { return $false }
    if ($current -notlike "*$ActivateCmd*") { return $false }

    # Se conserva lo que hubiera de otras herramientas: solo se quita el
    # fragmento nuestro y el separador que lo unia.
    $quoted  = [regex]::Escape("`"$ActivateCmd`"")
    $cleaned = $current
    $cleaned = [regex]::Replace($cleaned, '\s*&\s*' + $quoted, '')
    $cleaned = [regex]::Replace($cleaned, $quoted + '\s*&\s*', '')
    $cleaned = [regex]::Replace($cleaned, $quoted, '')
    $cleaned = $cleaned.Trim()

    Set-AutoRun -Value $cleaned
    if ([string]::IsNullOrWhiteSpace($cleaned)) {
        Write-Log "AutoRun de cmd retirado" "SUCCESS"
    }
    else {
        Write-Log "Fragmento retirado de AutoRun; se conserva: $cleaned" "SUCCESS"
    }
    return $true
}

function Add-AutoRunHook {
    $current = Get-AutoRun

    if ($current -like "*$ActivateCmd*") {
        Write-Log "AutoRun de cmd ya estaba enganchado" "SUCCESS"
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($current)) {
        $backupFile = Join-Path $StateDir "autorun-previo.txt"
        Set-Content -LiteralPath $backupFile -Value $current -Encoding UTF8
        Write-Log "  AutoRun previo respaldado en: $backupFile" "WARN"
        $new = "$current & `"$ActivateCmd`""
    }
    else {
        $new = "`"$ActivateCmd`""
    }

    Set-AutoRun -Value $new
    Write-Log "Enganchado en AutoRun de cmd.exe" "SUCCESS"
}

# --------------------------------------------------------------------------
# Estado actual
# --------------------------------------------------------------------------

function Show-Status {
    $state = Get-State

    Write-Host ""
    Write-Host "Versiones activadas globalmente:" -ForegroundColor Yellow
    if ($state.Count -eq 0) {
        Write-Host "  ninguna" -ForegroundColor Gray
    }
    else {
        foreach ($k in $state.Keys) {
            $shell = Get-RuntimeShell -Rt $k -Ver $state[$k]
            $ok = Test-Path -LiteralPath $shell
            $mark = if ($ok) { "" } else { "   <- ya no existe, desactivala" }
            Write-Host "  $k v$($state[$k])$mark" -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
        }
    }

    Write-Host ""
    Write-Host "Enganches:" -ForegroundColor Yellow
    $psHooked = (Test-Path -LiteralPath $ProfilePath) -and
                ((Get-Content -LiteralPath $ProfilePath -Raw) -like "*$MarkerStart*")
    $cmdHooked = (Get-AutoRun) -like "*$ActivateCmd*"
    Write-Host "  PowerShell : $(if ($psHooked) { 'si' } else { 'no' })"
    Write-Host "  cmd.exe    : $(if ($cmdHooked) { 'si' } else { 'no' })"

    Write-Host ""
    Write-Host "Uso:" -ForegroundColor Yellow
    Write-Host "  .\Use-Env.bat -Runtime Angular -Version 22    Activar"
    Write-Host "  .\Use-Env.bat -Off -Runtime Angular           Desactivar una"
    Write-Host "  .\Use-Env.bat -Off                            Desactivar todo"
    Write-Host ""
    Write-Host "Afecta a terminales NUEVAS, no a las ya abiertas." -ForegroundColor Gray
    Write-Host ""
}

# --------------------------------------------------------------------------
# Programa principal
# --------------------------------------------------------------------------

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Use-Env - Activacion global sin admin" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

if (-not $Off -and [string]::IsNullOrWhiteSpace($Runtime)) {
    Show-Status
    exit 0
}

# --- Desactivar ---
if ($Off) {
    $state = Get-State

    if (-not [string]::IsNullOrWhiteSpace($Runtime)) {
        if (-not $state.ContainsKey($Runtime)) {
            Write-Log "$Runtime no estaba activado." "WARN"
            exit 0
        }
        $state.Remove($Runtime)
        Save-State -State $state
        Write-Log "$Runtime desactivado" "SUCCESS"
    }
    else {
        $state = @{}
        Save-State -State $state
    }

    if ($state.Count -eq 0) {
        Write-Host ""
        Remove-ProfileHook | Out-Null
        Remove-AutoRunHook | Out-Null
        foreach ($f in @($ActivatePs1, $ActivateCmd, $StateFile)) {
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
        }
        Write-Log "Activacion global retirada por completo" "SUCCESS"
    }
    else {
        Write-ActivateScripts -State $state | Out-Null
        Write-Log "Regenerada la activacion con lo que queda" "SUCCESS"
    }

    Write-Host ""
    Write-Host "Afecta a terminales NUEVAS. Las abiertas conservan lo anterior." -ForegroundColor Gray
    Write-Host ""
    exit 0
}

# --- Activar ---
if ([string]::IsNullOrWhiteSpace($Version)) {
    Write-Log "Falta -Version." "ERROR"
    Write-Log "  Ejemplo:  .\Use-Env.bat -Runtime $Runtime -Version $(Get-VersionEjemplo -Rt $Runtime)" "WARN"
    exit 1
}

$shellBat = Get-RuntimeShell -Rt $Runtime -Ver $Version
if (-not (Test-Path -LiteralPath $shellBat)) {
    Write-Log "$Runtime v$Version no esta instalado (falta $shellBat)" "ERROR"
    Write-Log "  Instalalo con:  .\Setup-$($Runtime)Env.bat" "WARN"
    exit 1
}

$state = Get-State
$state[$Runtime] = $Version

Write-Host ""
Write-Host "Se va a activar $Runtime v$Version en TODAS las terminales nuevas." -ForegroundColor Yellow
Write-Host ""
Write-Host "Esto modifica dos cosas de tu perfil de usuario (nunca del sistema):" -ForegroundColor Yellow
Write-Host "  1. $ProfilePath"
Write-Host "  2. HKCU\$AutoRunKey  (valor AutoRun)"
Write-Host ""
Write-Host "Se puede revertir en cualquier momento con:  .\Use-Env.bat -Off" -ForegroundColor Gray
Write-Host ""

if (-not $Force) {
    $answer = Read-Host "Confirmas? (escribe SI)"
    if ($answer -ne 'SI') {
        Write-Host "Cancelado. No se ha tocado nada." -ForegroundColor Yellow
        exit 0
    }
    Write-Host ""
}

$paths = Write-ActivateScripts -State $state
Save-State -State $state
Add-ProfileHook
Add-AutoRunHook

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  ACTIVADO" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Rutas que se antepondran:" -ForegroundColor Yellow
foreach ($p in $paths) { Write-Host "  $p" }
Write-Host ""
Write-Host "Abre una terminal NUEVA y comprueba con:  .\Doctor-Env.bat" -ForegroundColor Gray
Write-Host ""
