#Requires -Version 5.1
<#
.SYNOPSIS
    Start-VSCodeEnv.ps1 - Abre el VS Code portable instalado por Setup-VSCodeEnv.
.DESCRIPTION
    Por defecto abre el editor. Con -Shell abre una consola con 'code' en el
    PATH, para usarlo desde linea de comandos.
.PARAMETER Version
    Linea a abrir (ej: 1.135). Si se omite, la mas reciente instalada.
.PARAMETER Path
    Carpeta o archivo que abrir en el editor.
.PARAMETER Shell
    Abre una consola con 'code' en el PATH en vez del editor.
.EXAMPLE
    .\Start-VSCodeEnv.ps1
.EXAMPLE
    .\Start-VSCodeEnv.ps1 -Path C:\proyectos\mi-app
#>

param(
    [string]$Version,

    [string]$Path,

    [switch]$Shell
)

$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Common.ps1")

$VSCodeRoot = Join-Path $WorkspaceRoot "VSCode"

function Get-VSCodeVersions {
    if (-not (Test-Path $VSCodeRoot)) { return @() }

    $result = @()
    foreach ($dir in (Get-ChildItem $VSCodeRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($dir.Name -notmatch '^vscode-(\d+\.\d+)$') { continue }
        $linea = $Matches[1]

        $exe = Join-Path $dir.FullName "Code.exe"
        $ver = $linea
        if (Test-Path $exe) {
            $v = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
            if ($v -match '(\d+\.\d+\.\d+)') { $ver = $Matches[1] }
        }

        $result += [PSCustomObject]@{
            Version  = $ver
            Linea    = $linea
            Path     = $dir.FullName
            Exe      = $exe
            Portable = Test-Path (Join-Path $dir.FullName "data")
            Shell    = Join-Path $dir.FullName ("code$($linea -replace '\.','')-shell.bat")
        }
    }
    return $result
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Visual Studio Code (portable)" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

$versions = @(Get-VSCodeVersions | Sort-Object { [version]$_.Linea } -Descending)

if ($versions.Count -eq 0) {
    Write-Host "No hay versiones instaladas." -ForegroundColor Red
    Write-Host ""
    Write-Host "Ejecuta: .\bin\setup\Setup-VSCodeEnv.bat" -ForegroundColor White
    Write-Host ""
    exit 1
}

Write-Host "Versiones instaladas:" -ForegroundColor Yellow
Write-Host ""
foreach ($v in $versions) {
    Write-Host "  VS Code $($v.Version)" -ForegroundColor Green
    Write-Host "    $($v.Path)" -ForegroundColor Gray
    if (-not $v.Portable) {
        Write-Host "    OJO: sin carpeta data\, NO esta en modo portable" -ForegroundColor Yellow
    }
}

$selected = $versions[0]

if (-not [string]::IsNullOrWhiteSpace($Version)) {
    $match = $versions | Where-Object { $_.Version -eq $Version -or $_.Linea -eq $Version }
    if (-not $match) {
        Write-Host ""
        Write-Host "VS Code $Version no esta instalado." -ForegroundColor Red
        Write-Host ""
        exit 1
    }
    $selected = @($match)[0]
}

if ($Shell) {
    if (-not (Test-Path -LiteralPath $selected.Shell)) {
        Write-Host ""
        Write-Host "Falta el shell: $($selected.Shell)" -ForegroundColor Red
        Write-Host "Vuelve a ejecutar Setup-VSCodeEnv.bat para regenerarlo." -ForegroundColor White
        Write-Host ""
        exit 1
    }
    Write-Host ""
    Write-Host "Abriendo consola con 'code' en el PATH..." -ForegroundColor Cyan
    Write-Host ""
    Start-Process cmd -ArgumentList "/k", """$($selected.Shell)"""
    exit 0
}

if (-not (Test-Path -LiteralPath $selected.Exe)) {
    Write-Host ""
    Write-Host "Falta Code.exe en $($selected.Path)" -ForegroundColor Red
    Write-Host "Reinstala con:  .\bin\setup\Setup-VSCodeEnv.bat -Force -KeepData" -ForegroundColor White
    Write-Host ""
    exit 1
}

Write-Host ""
Write-Host "Abriendo VS Code $($selected.Version)..." -ForegroundColor Cyan
Write-Host ""

if (-not [string]::IsNullOrWhiteSpace($Path)) {
    Start-Process $selected.Exe -ArgumentList @($Path)
}
else {
    Start-Process $selected.Exe
}
