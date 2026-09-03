#Requires -Version 5.1
<#
.SYNOPSIS
    Setup-VSCodeEnv.ps1 - Instala Visual Studio Code sin permisos de administrador.
.DESCRIPTION
    El instalador normal de VS Code -el "System Installer"- pide administrador.
    Pero Microsoft publica ademas el .zip, y ese admite MODO PORTABLE oficial:
    basta con crear una carpeta "data" junto al ejecutable y VS Code guarda ahi
    sus ajustes y extensiones en vez de en tu perfil. Sin registro, sin admin.

    Eso tiene una ventaja de propina: el entorno se lo puedes llevar entero en
    una carpeta, extensiones incluidas.

    Verifica el SHA-256 que publica la propia API de actualizacion de VS Code.
.PARAMETER Force
    Reinstala aunque ya exista esa version.
.PARAMETER KeepData
    Con -Force, conserva la carpeta data\ (ajustes y extensiones) en vez de
    borrarla con el resto.
.PARAMETER WhatIf
    Muestra el plan y no toca nada.
.EXAMPLE
    .\Setup-VSCodeEnv.ps1
.EXAMPLE
    .\Setup-VSCodeEnv.ps1 -Force -KeepData
#>

param(
    # Version concreta (ej: 1.135.0). Si se omite, la ultima estable. Existe
    # para que un devenv.lock.json pueda fijarla.
    [string]$VSCodeVersion,

    [switch]$Force,

    [switch]$KeepData,

    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Common.ps1")

$VSCodeRoot = Join-Path $WorkspaceRoot "VSCode"

Write-Log "========================================" "INFO"
Write-Log "  Visual Studio Code (portable)" "INFO"
Write-Log "========================================" "INFO"
Write-Log ""

function Get-InstalledVSCodeVersion {
    param([string]$VSCodePath)

    # De los recursos del ejecutable, no ejecutandolo: Code.exe es una
    # aplicacion grafica y lanzarla abriria una ventana.
    $exe = Join-Path $VSCodePath "Code.exe"
    if (-not (Test-Path -LiteralPath $exe)) { return $null }
    $v = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
    if ($v -match '(\d+\.\d+\.\d+)') { return $Matches[1] }
    return $v
}

function Get-VSCodePortable {
    param([PSCustomObject]$Release, [string]$FolderName)

    $vscodePath = Join-Path $VSCodeRoot $FolderName
    $dataPath   = Join-Path $vscodePath "data"
    $exe        = Join-Path $vscodePath "Code.exe"

    if (Test-Path $exe) {
        $instalada = Get-InstalledVSCodeVersion -VSCodePath $vscodePath

        if ($Force) {
            Write-Log "-Force: se reinstala $FolderName desde cero" "WARN"
            if ($instalada) { Write-Log "  habia: $instalada  ->  se pondra: $($Release.Version)" }

            # data\ son los ajustes y las extensiones del usuario. Borrarlas sin
            # avisar seria perder trabajo suyo, no del kit.
            $rescate = $null
            if ($KeepData -and (Test-Path -LiteralPath $dataPath)) {
                $rescate = Join-Path $VSCodeRoot ("data-rescatada-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
                Move-Item -LiteralPath $dataPath -Destination $rescate -Force
                Write-Log "  -KeepData: ajustes y extensiones apartados" "SUCCESS"
            }
            elseif (Test-Path -LiteralPath $dataPath) {
                Write-Log "  Se van a BORRAR los ajustes y extensiones de data\." "WARN"
                Write-Log "  Para conservarlos, cancela y usa:  -Force -KeepData" "WARN"
            }

            Remove-Item -LiteralPath $vscodePath -Recurse -Force

            if ($rescate) {
                New-Item -ItemType Directory -Path $vscodePath -Force | Out-Null
                Move-Item -LiteralPath $rescate -Destination $dataPath -Force
            }
        }
        elseif ($instalada -eq $Release.Version) {
            Write-Log "VS Code $instalada ya esta instalado y al dia" "SUCCESS"
            return $vscodePath
        }
        elseif ($instalada) {
            Write-Log "Ya hay VS Code $instalada instalado en $FolderName" "WARN"
            Write-Log "  Disponible: $($Release.Version)" "WARN"
            Write-Log "  Para actualizarlo conservando tus extensiones:" "WARN"
            Write-Log "    .\bin\Setup-VSCodeEnv.bat -Force -KeepData" "WARN"
            return $vscodePath
        }
    }

    if (-not (Test-Path $VSCodeRoot)) {
        New-Item -ItemType Directory -Path $VSCodeRoot -Force | Out-Null
    }

    $zipPath = Join-Path $VSCodeRoot $Release.FileName

    Write-Log "Descargando VS Code $($Release.Version)..."
    Write-Log "  (unos 320 MB, tarda)"
    if (-not (Invoke-Download -Uri $Release.Url -OutFile $zipPath -Sha256 $Release.Sha256 `
                              -Description "VS Code $($Release.Version)")) {
        return $null
    }

    if (-not (Test-ZipIntegrity -ZipPath $zipPath)) {
        Write-Log "El zip de VS Code llego danado o incompleto" "ERROR"
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        return $null
    }

    Write-Log "Extrayendo (son bastantes archivos)..."
    # El zip de VS Code NO trae carpeta contenedora: su contenido va directo a
    # la carpeta destino, al reves que los de Node, Maven o Gradle.
    if (-not (Test-Path $vscodePath)) {
        New-Item -ItemType Directory -Path $vscodePath -Force | Out-Null
    }
    Expand-Archive -Path $zipPath -DestinationPath $vscodePath -Force
    Remove-Item $zipPath -Force

    if (-not (Test-Path $exe)) {
        Write-Log "Tras extraer no hay Code.exe en $vscodePath" "ERROR"
        return $null
    }

    # ESTO es lo que activa el modo portable. Sin esta carpeta, VS Code
    # escribiria los ajustes y las extensiones en %APPDATA%, y dejaria de ser
    # portable sin avisar de nada.
    if (-not (Test-Path -LiteralPath $dataPath)) {
        New-Item -ItemType Directory -Path $dataPath -Force | Out-Null
        Write-Log "Modo portable activado (carpeta data\)" "SUCCESS"
    }
    else {
        Write-Log "Modo portable: se conservan los ajustes y extensiones de data\" "SUCCESS"
    }

    Write-Log "VS Code instalado en $vscodePath" "SUCCESS"
    return $vscodePath
}

# --------------------------------------------------------------------------

$pedidoVs = Split-RuntimeVersionSpec -Clave vscode -Spec $VSCodeVersion

Write-Log $(if ($pedidoVs.Exacta) { "Buscando VS Code $($pedidoVs.Exacta)..." }
            else { "Consultando la ultima version estable de VS Code..." })

$release = Get-VSCodeRelease -Version $pedidoVs.Exacta
if (-not $release) {
    Write-Log "No se pudo consultar la version de VS Code." "ERROR"
    Write-Log "  No se pudo leer $VSCodeUpdateApi. Reintenta." "WARN"
    exit 1
}

Write-Log "  Version: $($release.Version)" "SUCCESS"
if ($pedidoVs.Exacta -and -not $release.Sha256) {
    # Se dice en vez de callarlo: pedir una version concreta sale por otra ruta
    # que no publica checksum, asi que esa descarga NO se verifica.
    Write-Log "  Al pedir una version concreta no hay checksum publicado: no se verificara." "WARN"
}

$line       = Get-ToolLine -Version $release.Version
$FolderName = "vscode-$line"
$shellName  = "code$($line -replace '\.','')-shell.bat"

Write-Log "Carpeta destino: $VSCodeRoot" "INFO"
Write-Log ""

if ($WhatIf) {
    $destino = Join-Path $VSCodeRoot $FolderName
    $yaHay = Get-InstalledVSCodeVersion -VSCodePath $destino
    $hayData = Test-Path -LiteralPath (Join-Path $destino "data")

    Write-Host ""
    Write-Host "Se va a instalar:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host ("  [version]  VS Code {0}" -f $release.Version)
    $hashTxt = if ($release.Sha256) { "SHA-256 verificado" } else { "SIN checksum" }
    Write-Host ("  [descarga] zip oficial, unos 320 MB  ({0})" -f $hashTxt) -ForegroundColor DarkGray
    Write-Host ("  [carpeta]  {0}" -f $destino)
    if ($yaHay) {
        if ($Force -and $KeepData)  { Write-Host ("             -Force -KeepData: reemplaza {0} y CONSERVA data\" -f $yaHay) -ForegroundColor Yellow }
        elseif ($Force -and $hayData) { Write-Host ("             -Force BORRARIA {0} Y tus ajustes y extensiones de data\" -f $yaHay) -ForegroundColor Red }
        elseif ($Force)              { Write-Host ("             -Force BORRARIA la actual ({0})" -f $yaHay) -ForegroundColor Red }
        else                         { Write-Host ("             ya hay {0}; sin -Force no se tocaria" -f $yaHay) -ForegroundColor Yellow }
    }
    Write-Host ("  [portable] {0}\data   <- lo que hace que sea portable" -f $destino)
    Write-Host ("  [PATH]     {0}\bin" -f $destino)
    Write-Host ("  [shell]    {0}" -f $shellName)
    Write-Host ""
    Write-Host "No es el instalador: es el zip oficial en modo portable." -ForegroundColor DarkGray
    Write-Host "No toca el registro ni pide administrador." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "-WhatIf: no se ha tocado nada." -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

$vscodePath = Get-VSCodePortable -Release $release -FolderName $FolderName
if (-not $vscodePath) { exit 1 }

Show-PathConflicts -Root $VSCodeRoot -Keep (Join-Path $vscodePath "bin") -Label "VS Code"
Add-UserPathEntry -Path (Join-Path $vscodePath "bin")

Write-VSCodeShell -VSCodePath $vscodePath -Version $release.Version | Out-Null
Write-Log "Shell creado: $vscodePath\$shellName" "SUCCESS"

# Si ya hay JDK del kit, este editor nace sabiendo cuales son. Sin esto, un
# portable instalado despues de los Java nacia sin saber nada de ellos y habia
# que acordarse de registrarlos a mano.
foreach ($linea in @(Sync-VSCodeJavaRuntimes -Inicializar)) {
    Write-Log "JDK registrados: $linea" "SUCCESS"

    # Registrarlos no sirve de nada sin la extension que los lee, y un portable
    # recien instalado no trae ninguna. Solo se dice si de verdad falta.
    $settings = Join-Path $vscodePath "data\user-data\User\settings.json"
    if (@(Get-VSCodeExtensions -SettingsPath $settings) -notcontains 'redhat.java') {
        Write-Log "  Los lee la extension de Java, que este VS Code no tiene:" "WARN"
        Write-Log "    .\bin\Use-VSCodeJava.bat -InstallExtension" "WARN"
    }
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  CONFIGURACION COMPLETADA" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Estructura creada:" -ForegroundColor Yellow
Write-Host "  $VSCodeRoot"
Write-Host "  +-- $FolderName\"
Write-Host "      +-- Code.exe"
Write-Host "      +-- data\        (tus ajustes y extensiones)"
Write-Host "      +-- $shellName"
Write-Host ""
Write-Host "VS Code $($release.Version) listo, sin administrador." -ForegroundColor Green
Write-Host ""
Write-Host "Al ser portable, los ajustes y las extensiones viven en data\ y no en" -ForegroundColor Gray
Write-Host "tu perfil: puedes llevarte la carpeta entera a otro equipo." -ForegroundColor Gray
Write-Host ""
Write-Host "Para comenzar:" -ForegroundColor Yellow
Write-Host "  Abrelo:       .\bin\Start-VSCodeEnv.bat" -ForegroundColor White
Write-Host "  Desde consola: code ." -ForegroundColor White
Write-Host "  Comprueba con: .\bin\Doctor-Env.bat" -ForegroundColor Gray
Write-Host ""
