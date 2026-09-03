#Requires -Version 5.1
<#
.SYNOPSIS
    Start-NodeEnv.ps1 - Abre un shell con la Node instalada por Setup-NodeEnv.
.PARAMETER Version
    Version mayor a abrir (ej: 22). Si se omite, la mas reciente instalada.
.EXAMPLE
    .\Start-NodeEnv.ps1
.EXAMPLE
    .\Start-NodeEnv.ps1 -Version 22
#>

param([string]$Version)

$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

$NodeRoot = Join-Path $WorkspaceRoot "Node"

function Get-NodeVersions {
    if (-not (Test-Path $NodeRoot)) { return @() }

    $result = @()
    foreach ($dir in (Get-ChildItem $NodeRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($dir.Name -notmatch '^node-(\d+)$') { continue }
        $major = $Matches[1]

        # La carpeta solo lleva la mayor (node-22), asi que el patch exacto se
        # pregunta al binario.
        $exe = Join-Path $dir.FullName "node.exe"
        $ver = $major
        if (Test-Path $exe) {
            $run = Invoke-NativeCommand -FilePath $exe -Arguments @('--version') -Quiet
            if ($run.ExitCode -eq 0 -and $run.Output -match 'v?(\d+\.\d+\.\d+)') { $ver = $Matches[1] }
        }

        $result += [PSCustomObject]@{
            Version = $ver
            Major   = $major
            Path    = $dir.FullName
            Shell   = Join-Path $dir.FullName "node$major-shell.bat"
        }
    }
    return $result
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Node.js Development Environment" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

$versions = @(Get-NodeVersions | Sort-Object { [int]$_.Major } -Descending)

if ($versions.Count -eq 0) {
    Write-Host "No hay versiones instaladas." -ForegroundColor Red
    Write-Host ""
    Write-Host "Ejecuta: .\bin\Setup-NodeEnv.bat" -ForegroundColor White
    Write-Host ""
    exit 1
}

Write-Host "Versiones instaladas:" -ForegroundColor Yellow
Write-Host ""
foreach ($v in $versions) {
    Write-Host "  Node v$($v.Version)" -ForegroundColor Green
    Write-Host "    $($v.Path)" -ForegroundColor Gray
}

$selected = $versions[0]

if (-not [string]::IsNullOrWhiteSpace($Version)) {
    # Se admite tanto la mayor ("22") como la completa ("22.23.2").
    $match = $versions | Where-Object { $_.Version -eq $Version -or $_.Major -eq $Version }
    if (-not $match) {
        Write-Host ""
        Write-Host "Node v$Version no esta instalado." -ForegroundColor Red
        Write-Host ""
        exit 1
    }
    $selected = @($match)[0]
}

if (-not (Test-Path -LiteralPath $selected.Shell)) {
    Write-Host ""
    Write-Host "Falta el shell: $($selected.Shell)" -ForegroundColor Red
    Write-Host "Vuelve a ejecutar Setup-NodeEnv.bat para regenerarlo." -ForegroundColor White
    Write-Host ""
    exit 1
}

Write-Host ""
Write-Host "Abriendo shell de Node v$($selected.Version)..." -ForegroundColor Cyan
Write-Host ""

Start-Process cmd -ArgumentList "/k", """$($selected.Shell)"""
