#Requires -Version 5.1
<#
.SYNOPSIS
    Start-JavaEnv.ps1 - Abre el shell del JDK mas reciente instalado.
.PARAMETER Version
    Abre esa version concreta en vez de la mas reciente (ej: -Version 17).
#>

param(
    [int]$Version
)

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Common.ps1")

$JavaRoot = Join-Path $WorkspaceRoot "Java"

function Get-JavaVersions {
    $versions = @()
    if (Test-Path $JavaRoot) {
        Get-ChildItem $JavaRoot -Directory | Where-Object { $_.Name -match '^jdk-(\d+)$' } | ForEach-Object {
            $ver = $_.Name -replace 'jdk-', ''
            $versions += [PSCustomObject]@{
                Version = $ver
                Path = $_.FullName
                Shell = Join-Path $_.FullName "java$ver-shell.bat"
            }
        }
    }
    return $versions
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Java Development Environment" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

$versions = @(Get-JavaVersions | Sort-Object { [int]$_.Version } -Descending)

if ($versions.Count -eq 0) {
    Write-Host "No hay versiones instaladas." -ForegroundColor Red
    Write-Host ""
    Write-Host "Ejecuta: .\bin\setup\Setup-JavaEnv.bat -JavaVersion 21" -ForegroundColor White
    Write-Host ""
    exit 1
}

Write-Host "Versiones instaladas:" -ForegroundColor Yellow
Write-Host ""

foreach ($v in $versions) {
    Write-Host "  JDK $($v.Version)" -ForegroundColor Green
    Write-Host "    $($v.Path)" -ForegroundColor Gray
}

$selected = $versions[0]

if ($PSBoundParameters.ContainsKey('Version')) {
    $match = $versions | Where-Object { [int]$_.Version -eq $Version }
    if (-not $match) {
        Write-Host ""
        Write-Host "JDK $Version no esta instalado." -ForegroundColor Red
        Write-Host ""
        exit 1
    }
    $selected = @($match)[0]
}

if (-not (Test-Path -LiteralPath $selected.Shell)) {
    Write-Host ""
    Write-Host "Falta el shell: $($selected.Shell)" -ForegroundColor Red
    Write-Host "Vuelve a ejecutar Setup-JavaEnv.bat para regenerarlo." -ForegroundColor White
    Write-Host ""
    exit 1
}

Write-Host ""
Write-Host "Abriendo shell del JDK $($selected.Version)..." -ForegroundColor Cyan
Write-Host ""

Start-Process cmd -ArgumentList "/k", """$($selected.Shell)"""
