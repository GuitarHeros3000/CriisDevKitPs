#Requires -Version 5.1
<#
.SYNOPSIS
    Uninstall-Env.ps1 - Retira una version instalada por el kit y limpia el PATH.
.DESCRIPTION
    Cierra el ciclo de vida: hasta ahora el kit sabia instalar pero no desinstalar,
    y borrar la carpeta a mano dejaba entradas muertas en el PATH del usuario.

    Solo toca lo que el propio kit creo: las carpetas bajo Angular\ o Python\ y
    las entradas de PATH que apuntan ahi dentro. Nunca toca el PATH de maquina,
    ni instalaciones que el usuario tuviera por su cuenta.

    Siempre pide confirmacion y siempre deja una copia del PATH previo.
.PARAMETER Runtime
    Angular o Python.
.PARAMETER Version
    Version a retirar (ej: 20 para Angular, 3.12 para Python).
.PARAMETER Node
    Solo Angular: retira ademas una version concreta de Node (ej: 24.19.0).
.PARAMETER All
    Retira TODO lo que el kit instalo de ese runtime, incluidas todas las Node.
.PARAMETER WhatIf
    Muestra lo que haria sin tocar nada.
.PARAMETER Force
    No pide confirmacion.
.EXAMPLE
    .\Uninstall-Env.ps1 -Runtime Python -Version 3.12
.EXAMPLE
    .\Uninstall-Env.ps1 -Runtime Angular -Version 20 -WhatIf
.EXAMPLE
    .\Uninstall-Env.ps1 -Runtime Angular -All -Force
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Angular', 'Python', 'Java', 'Node')]
    [string]$Runtime,

    [string]$Version,

    [string]$Node,

    [switch]$All,

    [switch]$WhatIf,

    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

$RuntimeRoot = Join-Path $WorkspaceRoot $Runtime

function Get-InstalledItems {
    <#
        Devuelve las carpetas que el kit creo para este runtime, con su tipo.
        Se identifican por el patron de nombre que usan los scripts de setup:
        cualquier otra carpeta que el usuario haya puesto ahi se ignora.
    #>
    if (-not (Test-Path $RuntimeRoot)) { return @() }

    $items = @()
    foreach ($dir in (Get-ChildItem $RuntimeRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($Runtime -eq 'Angular') {
            if ($dir.Name -match '^angular-v(\d+)$') {
                $items += [PSCustomObject]@{ Kind = 'Angular'; Version = $Matches[1]; Path = $dir.FullName; Name = $dir.Name }
            }
            elseif ($dir.Name -match '^node-v(.+)-win-x64$') {
                $items += [PSCustomObject]@{ Kind = 'Node'; Version = $Matches[1]; Path = $dir.FullName; Name = $dir.Name }
            }
            elseif ($dir.Name -eq 'npm-cache') {
                $items += [PSCustomObject]@{ Kind = 'Cache'; Version = ''; Path = $dir.FullName; Name = $dir.Name }
            }
        }
        elseif ($Runtime -eq 'Python') {
            if ($dir.Name -match '^python-(\d+\.\d+)$') {
                $items += [PSCustomObject]@{ Kind = 'Python'; Version = $Matches[1]; Path = $dir.FullName; Name = $dir.Name }
            }
        }
        elseif ($Runtime -eq 'Node') {
            # Solo la Node SUELTA, la de Node\ y con nombre node-<mayor>. La que
            # vive dentro de Angular\ se llama node-vX.Y.Z-win-x64 y la gestiona
            # -Runtime Angular: son instalaciones independientes.
            if ($dir.Name -match '^node-(\d+)$') {
                $items += [PSCustomObject]@{ Kind = 'Node'; Version = $Matches[1]; Path = $dir.FullName; Name = $dir.Name }
            }
        }
        else {
            if ($dir.Name -match '^jdk-(\d+)$') {
                $items += [PSCustomObject]@{ Kind = 'Java'; Version = $Matches[1]; Path = $dir.FullName; Name = $dir.Name }
            }
        }
    }
    return $items
}

function Get-FolderSize {
    param([string]$Path)
    try {
        $bytes = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
        if (-not $bytes) { return "0 MB" }
        return "{0:N0} MB" -f ($bytes / 1MB)
    }
    catch { return "?" }
}

# --------------------------------------------------------------------------

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Uninstall-Env - $Runtime" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $RuntimeRoot)) {
    Write-Log "No hay nada instalado: $RuntimeRoot no existe." "WARN"
    exit 0
}

$installed = @(Get-InstalledItems)
if ($installed.Count -eq 0) {
    Write-Log "No se encontro nada instalado por el kit en $RuntimeRoot" "WARN"
    exit 0
}

if (-not $All -and [string]::IsNullOrWhiteSpace($Version) -and [string]::IsNullOrWhiteSpace($Node)) {
    Write-Host "Instalado actualmente:" -ForegroundColor Yellow
    Write-Host ""
    foreach ($i in $installed) {
        Write-Host ("  {0,-10} {1,-12} {2,10}  {3}" -f $i.Kind, $i.Version, (Get-FolderSize -Path $i.Path), $i.Name)
    }
    Write-Host ""
    Write-Host "Indica que retirar:" -ForegroundColor Yellow
    Write-Host "  .\Uninstall-Env.bat -Runtime $Runtime -Version <version>"
    if ($Runtime -eq 'Angular') {
        Write-Host "  .\Uninstall-Env.bat -Runtime Angular -Node <version>"
    }
    Write-Host "  .\Uninstall-Env.bat -Runtime $Runtime -All"
    Write-Host ""
    exit 0
}

# --- Seleccion de lo que se va a retirar ---
$targets = @()

if ($All) {
    $targets = $installed
}
else {
    if (-not [string]::IsNullOrWhiteSpace($Version)) {
        $match = @($installed | Where-Object { $_.Kind -eq $Runtime -and $_.Version -eq $Version })
        if ($match.Count -eq 0) {
            $have = @($installed | Where-Object { $_.Kind -eq $Runtime } | ForEach-Object { $_.Version })
            Write-Log "$Runtime v$Version no esta instalado." "ERROR"
            Write-Log "  Instalado: $(if ($have.Count) { $have -join ', ' } else { '(ninguna version)' })" "WARN"
            exit 1
        }
        $targets += $match
    }

    if (-not [string]::IsNullOrWhiteSpace($Node)) {
        $match = @($installed | Where-Object { $_.Kind -eq 'Node' -and $_.Version -eq $Node.TrimStart('v') })
        if ($match.Count -eq 0) {
            $have = @($installed | Where-Object { $_.Kind -eq 'Node' } | ForEach-Object { $_.Version })
            Write-Log "Node v$Node no esta instalado." "ERROR"
            Write-Log "  Instalado: $(if ($have.Count) { $have -join ', ' } else { '(ninguna version)' })" "WARN"
            exit 1
        }
        $targets += $match
    }
}

# --- Entradas de PATH afectadas ---
$pathEntries = @(Split-UserPath -Value (Get-RawUserPath))
$affected = @()
foreach ($t in $targets) {
    $tp = $t.Path.TrimEnd('\')
    foreach ($e in $pathEntries) {
        $expanded = [Environment]::ExpandEnvironmentVariables($e).TrimEnd('\')
        if ($expanded -ieq $tp -or $expanded.StartsWith($tp + '\', [StringComparison]::OrdinalIgnoreCase)) {
            if ($affected -notcontains $e) { $affected += $e }
        }
    }
}

# --- Resumen ---
Write-Host "Se va a retirar:" -ForegroundColor Yellow
Write-Host ""
foreach ($t in $targets) {
    Write-Host ("  [carpeta] {0,-34} {1,10}" -f $t.Name, (Get-FolderSize -Path $t.Path)) -ForegroundColor White
    Write-Host ("            {0}" -f $t.Path) -ForegroundColor DarkGray
}
if ($affected.Count -gt 0) {
    Write-Host ""
    foreach ($a in $affected) {
        Write-Host "  [PATH]    $a" -ForegroundColor White
    }
}
else {
    Write-Host ""
    Write-Host "  (ninguna entrada de PATH apunta ahi)" -ForegroundColor DarkGray
}
Write-Host ""

if ($WhatIf) {
    Write-Host "-WhatIf: no se ha tocado nada." -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

if (-not $Force) {
    $answer = Read-Host "Confirmas? (escribe SI)"
    if ($answer -ne 'SI') {
        Write-Host "Cancelado. No se ha tocado nada." -ForegroundColor Yellow
        exit 0
    }
    Write-Host ""
}

# --- PATH primero: si algo falla al borrar, es mejor un PATH limpio y una
#     carpeta de sobra que al reves. ---
if ($affected.Count -gt 0) {
    $removed = 0
    foreach ($t in $targets) {
        $removed += Remove-UserPathEntry -UnderFolder $t.Path
    }
    Write-Log "Entradas de PATH retiradas: $removed" "SUCCESS"
}

# --- Carpetas ---
$failed = @()
foreach ($t in $targets) {
    try {
        Remove-Item -LiteralPath $t.Path -Recurse -Force -Confirm:$false -ErrorAction Stop
        Write-Log "Borrado: $($t.Name)" "SUCCESS"
    }
    catch {
        Write-Log "No se pudo borrar $($t.Name): $($_.Exception.Message)" "ERROR"
        Write-Log "  Cierra las ventanas que lo esten usando y reintenta." "WARN"
        $failed += $t.Name
    }
}

# --- JAVA_HOME: si apuntaba a lo que acabamos de borrar, se retira ---
if ($Runtime -eq 'Java') {
    $javaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'User')
    if ($javaHome) {
        $jh = $javaHome.TrimEnd('\')
        $apuntaBorrado = $false
        foreach ($t in $targets) {
            $tp = $t.Path.TrimEnd('\')
            if ($jh -ieq $tp -or $jh.StartsWith($tp + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $apuntaBorrado = $true
            }
        }
        if ($apuntaBorrado) {
            # Dejarlo apuntando a una carpeta inexistente romperia Maven, Gradle
            # y los IDE con un error dificil de relacionar con esta desinstalacion.
            [Environment]::SetEnvironmentVariable('JAVA_HOME', $null, 'User')
            Write-Log "JAVA_HOME de usuario retirado (apuntaba a lo borrado)" "SUCCESS"
            Write-Log "  Si tenias uno de maquina, vuelve a ser el que manda." "WARN"
        }
    }
}

# --- Si la carpeta madre queda vacia, tambien se retira ---
$left = @(Get-ChildItem $RuntimeRoot -Force -ErrorAction SilentlyContinue)
if ($left.Count -eq 0) {
    Remove-Item -LiteralPath $RuntimeRoot -Force -Recurse -ErrorAction SilentlyContinue
    Write-Log "Carpeta $Runtime vacia: tambien retirada" "SUCCESS"
}
elseif ($Runtime -eq 'Angular') {
    # Cada Angular trae su propia Node, pero pueden compartirla. Al quitar solo
    # el Angular, su Node se queda: hay que decirlo, o el usuario se deja
    # gigabytes ocupados sin saberlo.
    $remaining = @(Get-InstalledItems)
    $angulars  = @($remaining | Where-Object { $_.Kind -eq 'Angular' })
    $nodes     = @($remaining | Where-Object { $_.Kind -eq 'Node' })

    if ($nodes.Count -gt 0 -and $angulars.Count -eq 0) {
        Write-Host ""
        Write-Log "Quedan versiones de Node sin ningun Angular que las use:" "WARN"
        foreach ($n in $nodes) {
            Write-Log "  Node $($n.Version)   ($(Get-FolderSize -Path $n.Path))" "WARN"
        }
        Write-Log "  Para retirarlas:  .\Uninstall-Env.bat -Runtime Angular -All" "WARN"
    }
    elseif ($nodes.Count -gt $angulars.Count) {
        Write-Host ""
        Write-Log "Hay mas versiones de Node ($($nodes.Count)) que de Angular ($($angulars.Count))." "WARN"
        Write-Log "  Puede que alguna ya no se use:  .\Uninstall-Env.bat -Runtime Angular" "WARN"
    }
}

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "  DESINSTALACION COMPLETADA" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Las ventanas ya abiertas conservan el PATH viejo." -ForegroundColor Gray
    Write-Host "Comprueba el estado con:  .\Doctor-Env.bat" -ForegroundColor Gray
    Write-Host ""
    exit 0
}
else {
    Write-Host "Quedaron carpetas sin borrar: $($failed -join ', ')" -ForegroundColor Red
    Write-Host "El PATH si se limpio." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}
