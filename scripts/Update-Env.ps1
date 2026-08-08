#Requires -Version 5.1
<#
.SYNOPSIS
    Update-Env.ps1 - Dice que actualizaciones hay para lo que tienes instalado.
.DESCRIPTION
    Hasta ahora solo te enterabas de que existia un patch nuevo si reejecutabas
    el setup correspondiente. Este comando compara lo instalado contra lo que
    publican las fuentes oficiales y te lo dice de una vez.

    NO instala nada nunca. Es de solo lectura, como Doctor: se limita a decirte
    el comando exacto que actualizaria cada cosa. Actualizar implica -Force, que
    en Python borra los paquetes pip, asi que esa decision es siempre tuya.

    Sale con codigo 1 si hay alguna actualizacion disponible, para poder
    encadenarlo ("avisame si hay algo nuevo"). Codigo 0 si esta todo al dia.
.PARAMETER Runtime
    Comprueba solo uno: Angular, Python, Java o Node.
.EXAMPLE
    .\Update-Env.ps1
.EXAMPLE
    .\Update-Env.ps1 -Runtime Java
#>

param(
    [ValidateSet('Angular', 'Python', 'Java', 'Node')]
    [string]$Runtime
)

$ProgressPreference = "SilentlyContinue"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

$AngularRoot = Join-Path $WorkspaceRoot "Angular"
$PythonRoot  = Join-Path $WorkspaceRoot "Python"
$JavaRoot    = Join-Path $WorkspaceRoot "Java"
$NodeRoot    = Join-Path $WorkspaceRoot "Node"

# Cada fila: que es, que hay, que se publica, y como actualizarlo.
$script:Filas = @()
$script:SinRed = $false

function Add-Fila {
    param(
        [string]$Que,
        [string]$Instalado,
        [string]$Disponible,
        [string]$Comando
    )

    $estado = if (-not $Disponible)                 { 'desconocido' }
              elseif ($Disponible -eq $Instalado)   { 'al dia' }
              else                                  { 'actualizable' }

    $script:Filas += [PSCustomObject]@{
        Que        = $Que
        Instalado  = $Instalado
        Disponible = if ($Disponible) { $Disponible } else { '?' }
        Estado     = $estado
        Comando    = $Comando
    }
    if ($estado -eq 'desconocido') { $script:SinRed = $true }
}

function Get-VersionDe {
    <#
        Lee la version que reporta un binario. Devuelve $null si no arranca, que
        Doctor ya trata como instalacion corrupta; aqui simplemente no se compara.
    #>
    param([string]$Exe, [string[]]$Args_ = @('--version'), [string]$Patron = '(\d+\.\d+\.\d+)')

    if (-not (Test-Path $Exe)) { return $null }
    $run = Invoke-NativeCommand -FilePath $Exe -Arguments $Args_ -Quiet
    if ($run.ExitCode -ne 0) { return $null }
    if ($run.Output -match $Patron) { return $Matches[1] }
    return $null
}

# --------------------------------------------------------------------------

function Test-PythonUpdates {
    if (-not (Test-Path $PythonRoot)) { return }

    foreach ($d in (Get-ChildItem $PythonRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -notmatch '^python-(\d+\.\d+)$') { continue }
        $serie = $Matches[1]

        $instalada = Get-VersionDe -Exe (Join-Path $d.FullName "python.exe")
        if (-not $instalada) { continue }

        Write-Host "  consultando python.org ($serie)..." -ForegroundColor DarkGray
        $ultima = Get-LatestPythonPatch -MinorPrefix $serie

        Add-Fila -Que "Python $serie" -Instalado $instalada `
                 -Disponible $(if ($ultima) { $ultima.Version } else { $null }) `
                 -Comando ".\Setup-PythonEnv.bat -PythonVersion $serie -Force"
    }
}

function Test-JavaUpdates {
    if (-not (Test-Path $JavaRoot)) { return }

    foreach ($d in (Get-ChildItem $JavaRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -notmatch '^jdk-(\d+)$') { continue }
        $major = $Matches[1]

        # Se compara la marca de release que deja el setup, no lo que dice
        # "java -version": los formatos no coinciden entre familias y comparar
        # como texto da falsos positivos.
        $marca = Join-Path $d.FullName ".assassinskipadm-release"
        $instalada = if (Test-Path $marca) { (Get-Content -LiteralPath $marca -Raw).Trim() } else { $null }
        if (-not $instalada) {
            $v = Get-VersionDe -Exe (Join-Path $d.FullName "bin\java.exe") -Args_ @('-version') -Patron 'version "([^"]+)"'
            Add-Fila -Que "Java $major" -Instalado $(if ($v) { "$v (sin marca)" } else { '?' }) `
                     -Disponible $null -Comando ".\Setup-JavaEnv.bat -JavaVersion $major -Force"
            continue
        }

        Write-Host "  consultando api.adoptium.net ($major)..." -ForegroundColor DarkGray
        $bin = Get-JavaArchiveInfo -Major ([int]$major)

        Add-Fila -Que "Java $major" -Instalado $instalada `
                 -Disponible $(if ($bin) { $bin.Release } else { $null }) `
                 -Comando ".\Setup-JavaEnv.bat -JavaVersion $major -Force"
    }
}

function Test-NodeUpdates {
    if (-not (Test-Path $NodeRoot)) { return }

    $dirs = @(Get-ChildItem $NodeRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^node-(\d+)$' })
    if ($dirs.Count -eq 0) { return }

    Write-Host "  consultando nodejs.org..." -ForegroundColor DarkGray
    $lts = @(Get-NodeLtsReleases)

    foreach ($d in $dirs) {
        $null = $d.Name -match '^node-(\d+)$'
        $major = [int]$Matches[1]
        $instalada = Get-VersionDe -Exe (Join-Path $d.FullName "node.exe") -Patron 'v?(\d+\.\d+\.\d+)'
        if (-not $instalada) { continue }

        # Se compara contra la ultima de SU MISMA linea: saltar de major es una
        # decision distinta, no una actualizacion.
        $suLinea = @($lts | Where-Object { $_.Major -eq $major })
        $disponible = if ($suLinea.Count -gt 0) { $suLinea[0].Version } elseif ($lts.Count -eq 0) { $null } else { $instalada }

        # El comando lleva la version CONCRETA, no un marcador: la gracia de esta
        # pantalla es poder copiar y pegar la linea tal cual.
        $cmd = if ($disponible) { ".\Setup-NodeEnv.bat -NodeVersion $disponible -Force" }
               else             { ".\Setup-NodeEnv.bat -Force" }

        Add-Fila -Que "Node $major (suelto)" -Instalado $instalada -Disponible $disponible -Comando $cmd
    }
}

function Test-AngularUpdates {
    if (-not (Test-Path $AngularRoot)) { return }

    foreach ($d in (Get-ChildItem $AngularRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -notmatch '^angular-v(\d+)$') { continue }
        $major = [int]$Matches[1]

        $pkg = Join-Path $d.FullName "npm-global\node_modules\@angular\cli\package.json"
        $instalada = $null
        if (Test-Path $pkg) {
            try { $instalada = (Get-Content $pkg -Raw | ConvertFrom-Json).version } catch { }
        }
        if (-not $instalada) { continue }

        Write-Host "  consultando registry.npmjs.org (v$major)..." -ForegroundColor DarkGray
        $ultima = Get-LatestAngularCliVersion -Major $major

        Add-Fila -Que "Angular CLI $major" -Instalado $instalada `
                 -Disponible $(if ([string]::IsNullOrEmpty($ultima)) { $null } else { $ultima }) `
                 -Comando ".\Setup-AngularEnv.bat -AngularVersion $major"
    }

    # La Node que Angular instala para si mismo, que es distinta de la suelta.
    foreach ($d in (Get-ChildItem $AngularRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -notmatch '^node-v(\d+)\.') { continue }
        $major = [int]$Matches[1]
        $instalada = Get-VersionDe -Exe (Join-Path $d.FullName "node.exe") -Patron 'v?(\d+\.\d+\.\d+)'
        if (-not $instalada) { continue }

        $lts = @(Get-NodeLtsReleases | Where-Object { $_.Major -eq $major })
        $disponible = if ($lts.Count -gt 0) { $lts[0].Version } else { $null }

        Add-Fila -Que "Node $major (de Angular)" -Instalado $instalada -Disponible $disponible `
                 -Comando "la elige el CLI: .\Setup-AngularEnv.bat -AngularVersion <n>"
    }
}

# --------------------------------------------------------------------------

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Update-Env - Actualizaciones disponibles" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

if (Test-RuntimeSelected -Name 'Python'  -Selected $Runtime) { Test-PythonUpdates }
if (Test-RuntimeSelected -Name 'Java'    -Selected $Runtime) { Test-JavaUpdates }
if (Test-RuntimeSelected -Name 'Node'    -Selected $Runtime) { Test-NodeUpdates }
if (Test-RuntimeSelected -Name 'Angular' -Selected $Runtime) { Test-AngularUpdates }

Write-Host ""

if ($script:Filas.Count -eq 0) {
    Write-Host "No hay nada instalado por el kit$(if ($Runtime) { " de $Runtime" })." -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

$anchoQue = ([int](($script:Filas | ForEach-Object { $_.Que.Length } | Measure-Object -Maximum).Maximum)) + 2
Write-Host ("  {0}{1,-16}{2,-16}" -f "Runtime".PadRight($anchoQue), "Instalado", "Disponible") -ForegroundColor Gray
Write-Host ("  " + ("-" * ($anchoQue + 32 + 14))) -ForegroundColor DarkGray

foreach ($f in $script:Filas) {
    $color = switch ($f.Estado) {
        'actualizable' { 'Yellow' }
        'al dia'       { 'Green' }
        default        { 'DarkGray' }
    }
    Write-Host ("  {0}{1,-16}{2,-16}{3}" -f $f.Que.PadRight($anchoQue), $f.Instalado, $f.Disponible, $f.Estado) -ForegroundColor $color
}

$actualizables = @($script:Filas | Where-Object { $_.Estado -eq 'actualizable' })

Write-Host ""
if ($script:SinRed) {
    Write-Host "Algunas no se pudieron comprobar: revisa la red o el proxy con .\Doctor-Env.bat" -ForegroundColor DarkGray
    Write-Host ""
}

if ($actualizables.Count -eq 0) {
    Write-Host "Todo al dia." -ForegroundColor Green
    Write-Host ""
    exit 0
}

Write-Host "Para actualizar:" -ForegroundColor Yellow
foreach ($f in $actualizables) {
    Write-Host ("  {0,-24} {1}" -f $f.Que, $f.Comando)
}
Write-Host ""
Write-Host "Ojo: -Force reinstala desde cero. En Python eso borra los paquetes pip" -ForegroundColor DarkGray
Write-Host "de esa version; anotalos antes con  pip freeze > requirements.txt" -ForegroundColor DarkGray
Write-Host ""

# Codigo 1 = hay algo que actualizar, para poder encadenarlo. Mismo criterio que
# Doctor, que sale con 1 cuando encuentra algo que mirar.
exit 1
