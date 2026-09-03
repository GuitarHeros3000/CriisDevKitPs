#Requires -Version 5.1
<#
.SYNOPSIS
    Start-DotnetEnv.ps1 - Abre un shell con el SDK de .NET instalado por Setup-DotnetEnv.
.PARAMETER Version
    Canal a abrir (ej: 10.0). Si se omite, el mas reciente instalado.
.EXAMPLE
    .\Start-DotnetEnv.ps1
#>

param([string]$Version)

$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Common.ps1")

$DotnetRoot = Join-Path $WorkspaceRoot "Dotnet"

function Get-DotnetVersions {
    if (-not (Test-Path $DotnetRoot)) { return @() }

    $result = @()
    foreach ($dir in (Get-ChildItem $DotnetRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($dir.Name -notmatch '^dotnet-(\d+\.\d+)$') { continue }
        $canal = $Matches[1]

        # La version exacta del SDK se lee de la carpeta sdk\, no ejecutando
        # dotnet: fuera de su ubicacion por defecto necesita DOTNET_ROOT puesto.
        $ver = $canal
        $sdks = @(Get-ChildItem -LiteralPath (Join-Path $dir.FullName "sdk") -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -match '^\d+\.\d+\.\d+' })
        if ($sdks.Count -gt 0) { $ver = @($sdks | Sort-Object Name -Descending)[0].Name }

        $result += [PSCustomObject]@{
            Version = $ver
            Canal   = $canal
            Path    = $dir.FullName
            Shell   = Join-Path $dir.FullName ("dotnet$($canal -replace '\.','')-shell.bat")
        }
    }
    return $result
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  .NET SDK Environment" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

$versions = @(Get-DotnetVersions | Sort-Object { [version]$_.Canal } -Descending)

if ($versions.Count -eq 0) {
    Write-Host "No hay versiones instaladas." -ForegroundColor Red
    Write-Host ""
    Write-Host "Ejecuta: .\bin\Setup-DotnetEnv.bat" -ForegroundColor White
    Write-Host ""
    exit 1
}

Write-Host "Versiones instaladas:" -ForegroundColor Yellow
Write-Host ""
foreach ($v in $versions) {
    Write-Host "  .NET SDK $($v.Version)  (canal $($v.Canal))" -ForegroundColor Green
    Write-Host "    $($v.Path)" -ForegroundColor Gray
}

$selected = $versions[0]

if (-not [string]::IsNullOrWhiteSpace($Version)) {
    $match = $versions | Where-Object { $_.Version -eq $Version -or $_.Canal -eq $Version }
    if (-not $match) {
        Write-Host ""
        Write-Host ".NET $Version no esta instalado." -ForegroundColor Red
        Write-Host ""
        exit 1
    }
    $selected = @($match)[0]
}

if (-not (Test-Path -LiteralPath $selected.Shell)) {
    Write-Host ""
    Write-Host "Falta el shell: $($selected.Shell)" -ForegroundColor Red
    Write-Host "Vuelve a ejecutar Setup-DotnetEnv.bat para regenerarlo." -ForegroundColor White
    Write-Host ""
    exit 1
}

Write-Host ""
Write-Host "Abriendo shell de .NET SDK $($selected.Version)..." -ForegroundColor Cyan
Write-Host ""

Start-Process cmd -ArgumentList "/k", """$($selected.Shell)"""
