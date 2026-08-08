#Requires -Version 5.1
<#
.SYNOPSIS
    Setup-NodeEnv.ps1 - Instala Node.js suelto, sin Angular.
.DESCRIPTION
    Hasta ahora Node solo llegaba como dependencia de Setup-AngularEnv y vivia
    dentro de Angular\. Este script lo instala como runtime independiente en su
    propia carpeta Node\, igual que Python\ y Java\.

    Son instalaciones SEPARADAS a proposito: la Node de Angular\ la elige el CLI
    y no debe cambiar porque aqui se instale otra. Ocupan mas disco, pero
    compartirlas haria que actualizar una rompiera la otra.

    Descarga el zip oficial de nodejs.org verificando su SHA-256 contra el
    SHASUMS256.txt de la misma release.
.PARAMETER NodeVersion
    Version concreta (ej: 22.23.2). Si se omite, la ultima LTS disponible.
.PARAMETER Force
    Reinstala aunque ya exista esa version mayor.
.PARAMETER WhatIf
    Muestra el plan y no toca nada.
.EXAMPLE
    .\Setup-NodeEnv.ps1
.EXAMPLE
    .\Setup-NodeEnv.ps1 -NodeVersion 22.23.2
#>

param(
    [string]$NodeVersion,

    [switch]$Force,

    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

$NodeRoot = Join-Path $WorkspaceRoot "Node"

Write-Log "========================================" "INFO"
Write-Log "  Node.js Environment Setup" "INFO"
Write-Log "========================================" "INFO"
Write-Log ""

function Resolve-StandaloneNodeVersion {
    <#
        Sin -NodeVersion se coge la LTS mas alta. Devuelve $null si no se pudo
        decidir, tras explicar por que: el exit vive en el cuerpo del script.
    #>
    param([string]$Forced)

    if (-not [string]::IsNullOrWhiteSpace($Forced)) {
        Write-Log "Version forzada por parametro: v$($Forced.TrimStart('v'))"
        return $Forced.TrimStart('v')
    }

    Write-Log "Consultando las LTS disponibles en nodejs.org..."
    $lts = @(Get-NodeLtsReleases)
    if ($lts.Count -eq 0) {
        Write-Log "No se pudo leer el indice de nodejs.org." "ERROR"
        Write-Log "  Indica la version a mano:  -NodeVersion 22.23.2" "WARN"
        return $null
    }

    $elegida = @($lts | Sort-Object Major -Descending)[0]
    Write-Log "  Elegida: v$($elegida.Version) (LTS $($elegida.Lts))" "SUCCESS"
    return $elegida.Version
}

function Get-InstalledNodeVersion {
    param([string]$NodeExe)

    $run = Invoke-NativeCommand -FilePath $NodeExe -Arguments @('--version') -Quiet
    if ($run.ExitCode -ne 0) { return $null }
    if ($run.Output -match 'v?(\d+\.\d+\.\d+)') { return $Matches[1] }
    return $null
}

function Get-NodePortable {
    param([PSCustomObject]$Archive)

    $nodePath = Join-Path $NodeRoot $Archive.FolderName
    $nodeExe  = Join-Path $nodePath "node.exe"

    if (Test-Path $nodeExe) {
        $instalada = Get-InstalledNodeVersion -NodeExe $nodeExe

        if ($Force) {
            Write-Log "-Force: se reinstala $($Archive.FolderName) desde cero" "WARN"
            Remove-Item -LiteralPath $nodePath -Recurse -Force
        }
        elseif ($instalada) {
            Write-Log "Node v$instalada ya esta instalado en $($Archive.FolderName)" "SUCCESS"
            return $nodePath
        }
        else {
            Write-Log "Hay un node.exe que no arranca en $($Archive.FolderName)" "ERROR"
            Write-Log "  Instalacion corrupta. Reinstala con:  -NodeVersion $($Archive.Version) -Force" "WARN"
            return $null
        }
    }

    if (-not (Test-Path $NodeRoot)) {
        New-Item -ItemType Directory -Path $NodeRoot -Force | Out-Null
    }

    $zipPath = Join-Path $NodeRoot $Archive.FileName

    Write-Log "Obteniendo checksum oficial..."
    $hash = Get-Sha256FromShasums -Uri $Archive.ShasumsUrl -FileName $Archive.FileName
    if (-not $hash) {
        Write-Log "No se pudo leer el checksum oficial; se continua sin verificar hash" "WARN"
    }

    Write-Log "Descargando Node.js v$($Archive.Version)..."
    if (-not (Invoke-Download -Uri $Archive.Url -OutFile $zipPath -Sha256 $hash `
                              -Description "Node.js v$($Archive.Version)")) {
        return $null
    }

    if (-not (Test-ZipIntegrity -ZipPath $zipPath)) {
        Write-Log "El zip de Node.js llego danado o incompleto" "ERROR"
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        return $null
    }

    Write-Log "Extrayendo..."
    # El zip ya trae dentro una carpeta node-vX-win-x64, asi que se extrae en la
    # raiz y queda con el nombre correcto sin mover nada.
    Expand-Archive -Path $zipPath -DestinationPath $NodeRoot -Force
    Remove-Item $zipPath -Force

    Write-Log "Node.js instalado en $nodePath" "SUCCESS"
    return $nodePath
}

# --------------------------------------------------------------------------

$version = Resolve-StandaloneNodeVersion -Forced $NodeVersion
if (-not $version) { exit 1 }

$archive = Get-NodeArchiveInfo -Version $version
$archive | Add-Member -NotePropertyName Version -NotePropertyValue $version -Force

Write-Log "Carpeta destino: $NodeRoot" "INFO"
Write-Log ""

if ($WhatIf) {
    $destino = Join-Path $NodeRoot $archive.FolderName
    $yaHay = if (Test-Path (Join-Path $destino "node.exe")) {
        Get-InstalledNodeVersion -NodeExe (Join-Path $destino "node.exe")
    } else { $null }

    Write-Host ""
    Write-Host "Se va a instalar:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host ("  [version]  Node v{0}" -f $version)
    Write-Host ("  [descarga] {0}  (SHA-256 verificado)" -f $archive.Url) -ForegroundColor DarkGray
    Write-Host ("  [carpeta]  {0}" -f $destino)
    if ($yaHay) {
        if ($Force) { Write-Host ("             -Force BORRARIA la actual (v{0})" -f $yaHay) -ForegroundColor Red }
        else        { Write-Host ("             ya hay v{0}; sin -Force no se tocaria" -f $yaHay) -ForegroundColor Yellow }
    }
    Write-Host ("  [PATH]     {0}" -f $destino)
    Write-Host ("  [shell]    node{0}-shell.bat" -f $version.Split('.')[0])
    Write-Host ""
    Write-Host "Nota: es independiente de la Node que instala Setup-AngularEnv." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "-WhatIf: no se ha tocado nada." -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

$nodePath = Get-NodePortable -Archive $archive
if (-not $nodePath) { exit 1 }

Show-PathConflicts -Root $NodeRoot -Keep $nodePath -Label "Node"
Add-UserPathEntry -Path $nodePath

Write-NodeShell -NodePath $nodePath -Version $version | Out-Null
$major = $version.Split('.')[0]
Write-Log "Shell creado: $nodePath\node$major-shell.bat" "SUCCESS"

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  CONFIGURACION COMPLETADA" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Estructura creada:" -ForegroundColor Yellow
Write-Host "  $NodeRoot"
Write-Host "  +-- $($archive.FolderName)\"
Write-Host "      +-- node.exe"
Write-Host "      +-- node$major-shell.bat"
Write-Host ""
Write-Host "Node v$version agregado al PATH." -ForegroundColor Green
Write-Host ""
Write-Host "Para comenzar:" -ForegroundColor Yellow
Write-Host "  Usa el shell: ..\Node\$($archive.FolderName)\node$major-shell.bat" -ForegroundColor White
Write-Host "  Comprueba con: .\Doctor-Env.bat" -ForegroundColor Gray
Write-Host ""
