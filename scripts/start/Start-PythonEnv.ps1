#Requires -Version 5.1
<#
.SYNOPSIS
    Start-PythonEnv.ps1 - Abre el shell de la version de Python mas reciente instalada.
.PARAMETER Version
    Abre esa version concreta en vez de la mas reciente (ej: -Version 3.11).
#>

param(
    [string]$Version
)

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Common.ps1")

$PythonRoot = Join-Path $WorkspaceRoot "Python"

function Get-PythonVersions {
    $versions = @()
    if (Test-Path $PythonRoot) {
        Get-ChildItem $PythonRoot -Directory | Where-Object { $_.Name -match '^python-\d+\.\d+$' } | ForEach-Object {
            $ver = $_.Name -replace 'python-', ''
            $versionClean = $ver -replace '\.', ''
            $versions += [PSCustomObject]@{
                Version = $ver
                Path = $_.FullName
                ScriptsPath = Join-Path $_.FullName "Scripts"
                Shell = Join-Path $_.FullName "py$versionClean-shell.bat"
            }
        }
    }
    return $versions
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Python Development Environment" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

$versions = @(Get-PythonVersions | Sort-Object { [version]$_.Version } -Descending)

if ($versions.Count -eq 0) {
    Write-Host "No hay versiones instaladas." -ForegroundColor Red
    Write-Host ""
    Write-Host "Ejecuta: .\bin\setup\Setup-PythonEnv.bat -PythonVersion 3.12" -ForegroundColor White
    Write-Host ""
    exit 1
}

Write-Host "Versiones instaladas:" -ForegroundColor Yellow
Write-Host ""

foreach ($v in $versions) {
    Write-Host "  Python v$($v.Version)" -ForegroundColor Green
    Write-Host "    $($v.Path)" -ForegroundColor Gray
}

$selected = $versions[0]

if (-not [string]::IsNullOrWhiteSpace($Version)) {
    $match = $versions | Where-Object { $_.Version -eq $Version }
    if (-not $match) {
        Write-Host ""
        Write-Host "Python v$Version no esta instalado." -ForegroundColor Red
        Write-Host ""
        exit 1
    }
    $selected = @($match)[0]
}

if (-not (Test-Path -LiteralPath $selected.Shell)) {
    Write-Host ""
    Write-Host "Falta el shell: $($selected.Shell)" -ForegroundColor Red
    Write-Host "Vuelve a ejecutar Setup-PythonEnv.bat para regenerarlo." -ForegroundColor White
    Write-Host ""
    exit 1
}

Write-Host ""
Write-Host "Abriendo shell de Python v$($selected.Version)..." -ForegroundColor Cyan
Write-Host ""

Start-Process cmd -ArgumentList "/k", """$($selected.Shell)"""
