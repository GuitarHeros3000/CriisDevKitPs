#Requires -Version 5.1
<#
.SYNOPSIS
    Start-AngularEnv.ps1 - Abre el shell de la version de Angular mas reciente instalada.
.PARAMETER Version
    Abre esa version concreta en vez de la mas reciente (ej: -Version 18).
#>

param(
    [int]$Version
)

. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

$AngularRoot = Join-Path $WorkspaceRoot "Angular"

function Get-AngularVersions {
    $versions = @()
    if (Test-Path $AngularRoot) {
        Get-ChildItem $AngularRoot -Directory | Where-Object { $_.Name -match '^angular-v\d+$' } | ForEach-Object {
            $ver = $_.Name -replace 'angular-v', ''
            $versions += [PSCustomObject]@{
                Version = $ver
                Path = $_.FullName
                Shell = Join-Path $_.FullName "shell-v$ver.bat"
            }
        }
    }
    return $versions
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Angular Development Environment" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

$versions = @(Get-AngularVersions | Sort-Object { [int]$_.Version } -Descending)

if ($versions.Count -eq 0) {
    Write-Host "No hay versiones instaladas." -ForegroundColor Red
    Write-Host ""
    Write-Host "Ejecuta: .\bin\Setup-AngularEnv.bat -AngularVersion 20" -ForegroundColor White
    Write-Host ""
    exit 1
}

Write-Host "Versiones instaladas:" -ForegroundColor Yellow
Write-Host ""

foreach ($v in $versions) {
    Write-Host "  Angular v$($v.Version)" -ForegroundColor Green
    Write-Host "    $($v.Path)" -ForegroundColor Gray
}

$selected = $versions[0]

if ($PSBoundParameters.ContainsKey('Version')) {
    $match = $versions | Where-Object { [int]$_.Version -eq $Version }
    if (-not $match) {
        Write-Host ""
        Write-Host "Angular v$Version no esta instalado." -ForegroundColor Red
        Write-Host ""
        exit 1
    }
    $selected = @($match)[0]
}

if (-not (Test-Path -LiteralPath $selected.Shell)) {
    Write-Host ""
    Write-Host "Falta el shell: $($selected.Shell)" -ForegroundColor Red
    Write-Host "Vuelve a ejecutar Setup-AngularEnv.bat para regenerarlo." -ForegroundColor White
    Write-Host ""
    exit 1
}

Write-Host ""
Write-Host "Abriendo shell de Angular v$($selected.Version)..." -ForegroundColor Cyan
Write-Host ""

Start-Process cmd -ArgumentList "/c", "call ""$($selected.Shell)"" && cmd /k" -WindowStyle Normal
