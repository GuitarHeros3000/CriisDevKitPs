#Requires -Version 5.1
<#
.SYNOPSIS
    Start-GradleEnv.ps1 - Abre un shell con el Gradle instalado por Setup-GradleEnv.
.PARAMETER Version
    Linea a abrir (ej: 9.7). Si se omite, la mas reciente instalada.
.EXAMPLE
    .\Start-GradleEnv.ps1
#>

param([string]$Version)

$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

$GradleRoot = Join-Path $WorkspaceRoot "Gradle"

function Get-GradleVersions {
    if (-not (Test-Path $GradleRoot)) { return @() }

    $result = @()
    foreach ($dir in (Get-ChildItem $GradleRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($dir.Name -notmatch '^gradle-(\d+\.\d+)$') { continue }
        $linea = $Matches[1]

        # Del jar del lanzador, no ejecutando gradle: necesita JAVA_HOME y
        # ademas levanta un demonio que tarda.
        $ver = $linea
        $jar = @(Get-ChildItem -Path (Join-Path $dir.FullName "lib\gradle-launcher-*.jar") -ErrorAction SilentlyContinue)
        if ($jar.Count -gt 0 -and $jar[0].Name -match 'gradle-launcher-([\d.]+)\.jar') { $ver = $Matches[1] }

        $result += [PSCustomObject]@{
            Version = $ver
            Linea   = $linea
            Path    = $dir.FullName
            Shell   = Join-Path $dir.FullName ("gradle$($linea -replace '\.','')-shell.bat")
        }
    }
    return $result
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Gradle Environment" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

$versions = @(Get-GradleVersions | Sort-Object { [version]$_.Linea } -Descending)

if ($versions.Count -eq 0) {
    Write-Host "No hay versiones instaladas." -ForegroundColor Red
    Write-Host ""
    Write-Host "Ejecuta: .\bin\Setup-GradleEnv.bat" -ForegroundColor White
    Write-Host ""
    exit 1
}

Write-Host "Versiones instaladas:" -ForegroundColor Yellow
Write-Host ""
foreach ($v in $versions) {
    Write-Host "  Gradle $($v.Version)" -ForegroundColor Green
    Write-Host "    $($v.Path)" -ForegroundColor Gray
}

$selected = $versions[0]

if (-not [string]::IsNullOrWhiteSpace($Version)) {
    $match = $versions | Where-Object { $_.Version -eq $Version -or $_.Linea -eq $Version }
    if (-not $match) {
        Write-Host ""
        Write-Host "Gradle $Version no esta instalado." -ForegroundColor Red
        Write-Host ""
        exit 1
    }
    $selected = @($match)[0]
}

if (-not (Get-KitJavaHome)) {
    Write-Host ""
    Write-Host "AVISO: no hay ningun JDK del kit; Gradle no arrancara sin uno." -ForegroundColor Yellow
    Write-Host "  Instalalo con .\bin\Setup-JavaEnv.bat y reejecuta .\bin\Setup-GradleEnv.bat" -ForegroundColor Gray
}

if (-not (Test-Path -LiteralPath $selected.Shell)) {
    Write-Host ""
    Write-Host "Falta el shell: $($selected.Shell)" -ForegroundColor Red
    Write-Host "Vuelve a ejecutar Setup-GradleEnv.bat para regenerarlo." -ForegroundColor White
    Write-Host ""
    exit 1
}

Write-Host ""
Write-Host "Abriendo shell de Gradle $($selected.Version)..." -ForegroundColor Cyan
Write-Host ""

Start-Process cmd -ArgumentList "/k", """$($selected.Shell)"""
