#Requires -Version 5.1
<#
.SYNOPSIS
    Start-GitEnv.ps1 - Abre un shell con el Git instalado por Setup-GitEnv.
.PARAMETER Version
    Linea a abrir (ej: 2.55). Si se omite, la mas reciente instalada.
.PARAMETER Bash
    Abre Git Bash en vez del shell de cmd.
.EXAMPLE
    .\Start-GitEnv.ps1
.EXAMPLE
    .\Start-GitEnv.ps1 -Bash
#>

param(
    [string]$Version,

    [switch]$Bash
)

$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Common.ps1")

$GitRoot = Join-Path $WorkspaceRoot "Git"

function Get-GitVersions {
    if (-not (Test-Path $GitRoot)) { return @() }

    $result = @()
    foreach ($dir in (Get-ChildItem $GitRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($dir.Name -notmatch '^git-(\d+\.\d+)$') { continue }
        $linea = $Matches[1]

        # La carpeta solo lleva la linea (git-2.55), asi que la version exacta
        # se le pregunta al binario.
        $exe = Join-Path $dir.FullName "cmd\git.exe"
        $ver = $linea
        if (Test-Path $exe) {
            $run = Invoke-NativeCommand -FilePath $exe -Arguments @('--version') -Quiet
            if ($run.ExitCode -eq 0) {
                $parsed = ConvertFrom-GitVersionOutput -Output $run.Output
                if ($parsed) { $ver = $parsed }
            }
        }

        $result += [PSCustomObject]@{
            Version = $ver
            Linea   = $linea
            Path    = $dir.FullName
            Shell   = Join-Path $dir.FullName ("git$($linea -replace '\.','')-shell.bat")
            Bash    = Join-Path $dir.FullName "git-bash.exe"
        }
    }
    return $result
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Git Development Environment" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

$versions = @(Get-GitVersions | Sort-Object { [version]$_.Linea } -Descending)

if ($versions.Count -eq 0) {
    Write-Host "No hay versiones instaladas." -ForegroundColor Red
    Write-Host ""
    Write-Host "Ejecuta: .\bin\Setup-GitEnv.bat" -ForegroundColor White
    Write-Host ""
    exit 1
}

Write-Host "Versiones instaladas:" -ForegroundColor Yellow
Write-Host ""
foreach ($v in $versions) {
    Write-Host "  Git $($v.Version)" -ForegroundColor Green
    Write-Host "    $($v.Path)" -ForegroundColor Gray
}

$selected = $versions[0]

if (-not [string]::IsNullOrWhiteSpace($Version)) {
    # Se admite tanto la linea ("2.55") como la version completa ("2.55.0.5").
    $match = $versions | Where-Object { $_.Version -eq $Version -or $_.Linea -eq $Version }
    if (-not $match) {
        Write-Host ""
        Write-Host "Git $Version no esta instalado." -ForegroundColor Red
        Write-Host ""
        exit 1
    }
    $selected = @($match)[0]
}

if ($Bash) {
    if (-not (Test-Path -LiteralPath $selected.Bash)) {
        Write-Host ""
        Write-Host "Falta git-bash.exe en $($selected.Path)" -ForegroundColor Red
        Write-Host "Reinstala con:  .\bin\Setup-GitEnv.bat -Force" -ForegroundColor White
        Write-Host ""
        exit 1
    }
    Write-Host ""
    Write-Host "Abriendo Git Bash $($selected.Version)..." -ForegroundColor Cyan
    Write-Host ""
    Start-Process $selected.Bash
    exit 0
}

if (-not (Test-Path -LiteralPath $selected.Shell)) {
    Write-Host ""
    Write-Host "Falta el shell: $($selected.Shell)" -ForegroundColor Red
    Write-Host "Vuelve a ejecutar Setup-GitEnv.bat para regenerarlo." -ForegroundColor White
    Write-Host ""
    exit 1
}

Write-Host ""
Write-Host "Abriendo shell de Git $($selected.Version)..." -ForegroundColor Cyan
Write-Host ""

Start-Process cmd -ArgumentList "/k", """$($selected.Shell)"""
