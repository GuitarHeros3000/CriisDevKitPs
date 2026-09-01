#Requires -Version 5.1
<#
.SYNOPSIS
    Start-MavenEnv.ps1 - Abre un shell con el Maven instalado por Setup-MavenEnv.
.PARAMETER Version
    Linea a abrir (ej: 3.9). Si se omite, la mas reciente instalada.
.EXAMPLE
    .\Start-MavenEnv.ps1
#>

param([string]$Version)

$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

$MavenRoot = Join-Path $WorkspaceRoot "Maven"

function Get-MavenVersions {
    if (-not (Test-Path $MavenRoot)) { return @() }

    $result = @()
    foreach ($dir in (Get-ChildItem $MavenRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($dir.Name -notmatch '^maven-(\d+\.\d+)$') { continue }
        $linea = $Matches[1]

        # La version exacta se lee del jar que trae dentro, no ejecutando mvn:
        # mvn necesita JAVA_HOME y aqui puede no estar puesto.
        $ver = $linea
        $jar = @(Get-ChildItem -Path (Join-Path $dir.FullName "lib\maven-core-*.jar") -ErrorAction SilentlyContinue)
        if ($jar.Count -gt 0 -and $jar[0].Name -match 'maven-core-([\d.]+)\.jar') { $ver = $Matches[1] }

        $result += [PSCustomObject]@{
            Version = $ver
            Linea   = $linea
            Path    = $dir.FullName
            Shell   = Join-Path $dir.FullName ("mvn$($linea -replace '\.','')-shell.bat")
        }
    }
    return $result
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Apache Maven Environment" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

$versions = @(Get-MavenVersions | Sort-Object { [version]$_.Linea } -Descending)

if ($versions.Count -eq 0) {
    Write-Host "No hay versiones instaladas." -ForegroundColor Red
    Write-Host ""
    Write-Host "Ejecuta: .\Setup-MavenEnv.bat" -ForegroundColor White
    Write-Host ""
    exit 1
}

Write-Host "Versiones instaladas:" -ForegroundColor Yellow
Write-Host ""
foreach ($v in $versions) {
    Write-Host "  Maven $($v.Version)" -ForegroundColor Green
    Write-Host "    $($v.Path)" -ForegroundColor Gray
}

$selected = $versions[0]

if (-not [string]::IsNullOrWhiteSpace($Version)) {
    $match = $versions | Where-Object { $_.Version -eq $Version -or $_.Linea -eq $Version }
    if (-not $match) {
        Write-Host ""
        Write-Host "Maven $Version no esta instalado." -ForegroundColor Red
        Write-Host ""
        exit 1
    }
    $selected = @($match)[0]
}

if (-not (Get-KitJavaHome)) {
    Write-Host ""
    Write-Host "AVISO: no hay ningun JDK del kit; Maven no arrancara sin uno." -ForegroundColor Yellow
    Write-Host "  Instalalo con .\Setup-JavaEnv.bat y reejecuta .\Setup-MavenEnv.bat" -ForegroundColor Gray
}

if (-not (Test-Path -LiteralPath $selected.Shell)) {
    Write-Host ""
    Write-Host "Falta el shell: $($selected.Shell)" -ForegroundColor Red
    Write-Host "Vuelve a ejecutar Setup-MavenEnv.bat para regenerarlo." -ForegroundColor White
    Write-Host ""
    exit 1
}

Write-Host ""
Write-Host "Abriendo shell de Maven $($selected.Version)..." -ForegroundColor Cyan
Write-Host ""

Start-Process cmd -ArgumentList "/k", """$($selected.Shell)"""
