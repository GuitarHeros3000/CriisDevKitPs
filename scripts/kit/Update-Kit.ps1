#Requires -Version 5.1
<#
.SYNOPSIS
    Update-Kit.ps1 - Actualiza el propio kit a la ultima version publicada.
.DESCRIPTION
    Baja la ultima release de GitHub, comprueba su SHA-256 y pone sus
    archivos en su sitio. Antes guarda lo que va a cambiar, para poder volver
    atras con -Revertir.

    Las carpetas del kit (bin, scripts, lib, tests, docs) quedan exactamente
    como en la version nueva. En la raiz solo se escribe lo que trae la
    version nueva: sources.json, los bundles de Export-Env y lo demas tuyo se
    respetan. Los runtimes instalados (Python\, Java\...) no se tocan: viven
    fuera de la carpeta del kit.

    Si el kit es un clon de git, no hace nada: ahi se actualiza con git pull,
    y sobrescribir los archivos dejaria el repositorio lleno de cambios.
.PARAMETER Check
    Solo dice si hay una version nueva.
.PARAMETER Version
    Una version concreta (2.3.0) en vez de la ultima.
.PARAMETER Force
    Reinstala aunque ya este al dia, o aunque sea un clon de git.
.PARAMETER Revertir
    Vuelve a la version de antes de la ultima actualizacion.
.EXAMPLE
    .\Update-Kit.ps1 -Check
.EXAMPLE
    .\Update-Kit.ps1
.EXAMPLE
    .\Update-Kit.ps1 -Revertir
#>

param(
    [switch]$Check,

    [string]$Version,

    [switch]$Force,

    [switch]$Revertir
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Common.ps1")
# Lo de actualizar (ver su cabecera: no lo carga Common).
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\KitUpdate.ps1")

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Update-Kit - Actualizar el kit" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Log "Este kit: v$KitVersion  ($DevKitRoot)"

function Write-BatNote {
    param([object[]]$Pendientes)
    if (@($Pendientes).Count -eq 0) { return }
    Start-DeferredCopy -Pares $Pendientes
    Write-Log "  $(@($Pendientes).Count) .bat se ponen en unos segundos, cuando este haya terminado:" "INFO"
    Write-Log "  cmd lee los .bat mientras los ejecuta, y no se puede cambiar el que esta en marcha." "INFO"
}

# --------------------------------------------------------------------------
# -Revertir
# --------------------------------------------------------------------------

if ($Revertir) {
    $marca = Join-Path $KitBackupDir '.criisdevkit-version'
    if (-not (Test-Path -LiteralPath $marca)) {
        Write-Log "No hay ninguna actualizacion que deshacer." "WARN"
        exit 0
    }
    $anterior = (Get-Content -LiteralPath $marca -Raw).Trim()
    Write-Log "Volviendo a v$anterior..."
    $r = Restore-KitBackup -Respaldo $KitBackupDir -Destino $DevKitRoot
    Write-Log "Hecho: $($r.Escritos) archivo(s) repuestos y $($r.Borrados) quitados." "SUCCESS"
    Write-BatNote -Pendientes $r.BatsPendientes
    Remove-Item -LiteralPath $KitBackupDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "Cierra y vuelve a abrir el menu para usar la version de antes." -ForegroundColor Gray
    Write-Host ""
    exit 0
}

# --------------------------------------------------------------------------
# Que hay publicado
# --------------------------------------------------------------------------

if ((Test-Path -LiteralPath (Join-Path $DevKitRoot '.git')) -and -not $Force -and -not $Check) {
    Write-Log "Este kit es un clon de git: se actualiza con git pull, no con esto." "WARN"
    Write-Log "  cd `"$DevKitRoot`"  y  git pull" "WARN"
    Write-Log "  (Sobrescribir los archivos dejaria el repositorio lleno de cambios. Con -Force se hace igual.)" "WARN"
    exit 0
}

if ($Version) {
    if ($Version.TrimStart('v') -notmatch '^\d+\.\d+\.\d+$') {
        Write-Log "Version no valida: $Version. Tiene la forma 2.3.0." "ERROR"
        exit 1
    }
    $rel = [PSCustomObject]@{ Tag = "v$($Version.TrimStart('v'))"; Version = $Version.TrimStart('v') }
}
else {
    Write-Log "Mirando la ultima version en github.com/$KitRepo..."
    $rel = Get-KitLatestRelease
    if (-not $rel) {
        Write-Log "No hay ninguna version publicada todavia (o no se llega a github.com)." "WARN"
        Write-Log "  https://github.com/$KitRepo/releases" "WARN"
        Write-Log "  Diagnostico de la red:  .\bin\kit\Doctor-Env.bat" "WARN"
        exit 0
    }
}

$hay = [version]$rel.Version
$tengo = [version]$KitVersion
if ($hay -le $tengo -and -not $Force) {
    if ($hay -eq $tengo) { Write-Log "Ya tienes la ultima: v$KitVersion" "SUCCESS" }
    else { Write-Log "La publicada (v$($rel.Version)) es anterior a la tuya (v$KitVersion); no se toca nada." "SUCCESS" }
    exit 0
}

if ($Check) {
    Write-Log "Hay una version nueva: v$($rel.Version) (tienes v$KitVersion)" "WARN"
    Write-Log "  Para ponerla:  .\bin\kit\Update-Kit.bat" "WARN"
    Write-Log "  Que trae:  https://github.com/$KitRepo/releases/tag/$($rel.Tag)" "INFO"
    exit 0
}

# --------------------------------------------------------------------------
# Bajarla, comprobarla y ponerla
# --------------------------------------------------------------------------

$archivos = Get-KitReleaseFiles -Tag $rel.Tag
$trabajo = Join-Path ([IO.Path]::GetTempPath()) ("criisdevkit-update-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $trabajo -Force | Out-Null

try {
    # El SHA-256 lo publica el mismo flujo que crea la release. Sin el no hay
    # forma de saber que el zip llego entero, y un kit a medias no arranca.
    $textoSha = Get-WebText -Uri $archivos.Sha256 -Quiet
    $sha = Get-HashFromChecksumText -Text $textoSha -Algorithm SHA256
    if (-not $sha) {
        Write-Log "La release v$($rel.Version) no trae su SHA-256 ($($archivos.FileName).sha256)." "ERROR"
        Write-Log "  Sin el no se puede comprobar que el zip llegue entero; no se actualiza." "WARN"
        exit 1
    }

    $zip = Join-Path $trabajo $archivos.FileName
    Write-Log "Descargando v$($rel.Version)..."
    if (-not (Invoke-Download -Uri $archivos.Zip -OutFile $zip -Sha256 $sha -Description "CriisDevKit v$($rel.Version)")) { exit 1 }

    $nuevo = Join-Path $trabajo 'kit'
    Expand-ZipArchive -Path $zip -Destino $nuevo -QuitarEnvoltorio

    if (-not (Test-KitFolderLooksComplete -Raiz $nuevo)) {
        Write-Log "El zip no tiene la forma del kit (faltan archivos clave); no se toca nada." "ERROR"
        exit 1
    }
    $dentro = Get-KitVersionFromFolder -Raiz $nuevo
    if ($dentro -ne $rel.Version) {
        Write-Log "El zip dice ser v$dentro y la release es v$($rel.Version); no se toca nada." "ERROR"
        exit 1
    }

    Write-Log "Poniendo v$($rel.Version) (lo de ahora se guarda en $KitBackupDir)..."
    $r = Update-KitFiles -Nuevo $nuevo -Destino $DevKitRoot -Respaldo $KitBackupDir -VersionAnterior $KitVersion

    Write-Log "v$KitVersion -> v$($rel.Version): $($r.Escritos) archivo(s) nuevos o cambiados, $($r.Borrados) que ya no hacian falta." "SUCCESS"
    Write-BatNote -Pendientes $r.BatsPendientes
}
finally {
    Remove-Item -LiteralPath $trabajo -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Que trae:  https://github.com/$KitRepo/releases/tag/$($rel.Tag)" -ForegroundColor Gray
Write-Host "Si algo va peor:  .\bin\kit\Update-Kit.bat -Revertir" -ForegroundColor Gray
Write-Host "Si estabas en el menu, cierralo y vuelvelo a abrir: sigue con la version de antes." -ForegroundColor Gray
Write-Host ""
exit 0
