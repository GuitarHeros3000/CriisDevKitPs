#Requires -Version 5.1
<#
.SYNOPSIS
    Setup-JavaEnv.ps1 - Instala un JDK sin permisos de administrador.
.DESCRIPTION
    Descarga el JDK de Eclipse Temurin (Adoptium) en formato zip y lo deja en una
    carpeta por version mayor. La API de Adoptium publica el SHA-256 de cada
    binario, asi que la descarga se verifica siempre.

    OJO con JAVA_HOME: por defecto NO se toca. Muchas herramientas (Maven,
    Gradle, los IDE) leen esa variable en vez del PATH, asi que cambiarla altera
    con que JDK compilan todos tus proyectos. Con -SetJavaHome se puede hacer
    explicitamente.
.PARAMETER JavaVersion
    Version mayor del JDK (8, 11, 17, 21, 25...). Por defecto la ultima LTS.
.PARAMETER SetJavaHome
    Ademas del PATH, define JAVA_HOME de usuario apuntando a este JDK.
.PARAMETER Force
    Reinstala aunque ya exista esa version mayor. Necesario para actualizar el
    patch, porque la carpeta se llama solo jdk-<mayor>.
.EXAMPLE
    .\Setup-JavaEnv.ps1
.EXAMPLE
    .\Setup-JavaEnv.ps1 -JavaVersion 17
.EXAMPLE
    .\Setup-JavaEnv.ps1 -JavaVersion 21 -SetJavaHome
#>

param(
    # Admite la linea ("21") o el release exacto ("jdk-21.0.5+11"). Es un
    # string y no un int para que quepan los dos en el mismo parametro: asi un
    # devenv.lock.json puede fijar la version sin necesitar otro distinto.
    [string]$JavaVersion = '',

    [switch]$SetJavaHome,

    [switch]$Force,

    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

$JavaRoot = Join-Path $WorkspaceRoot "Java"

$AdoptiumApi = "https://api.adoptium.net/v3"

# Respaldo para cuando la API no responde. Verificado el 2026-08-04.
$JavaLtsFallback = @(8, 11, 17, 21, 25)

Write-Log "========================================" "INFO"
Write-Log "  Java (JDK) Environment Setup" "INFO"
Write-Log "========================================" "INFO"
Write-Log ""

function Get-AdoptiumReleases {
    <#
        Versiones que Adoptium publica hoy. Devuelve $null si no se pudo leer,
        para que quien llama decida si tira del respaldo.
    #>
    return Invoke-JsonApi -Uri "$AdoptiumApi/info/available_releases" -TimeoutSec 60 -Quiet
}

function Resolve-JavaVersion {
    <#
        Devuelve 0 si la version pedida no existe, despues de explicar por que.
        No llama a exit: matar el proceso desde dentro de una funcion la hace
        intesteable e impide reutilizarla. Misma convencion que Invoke-JsonApi
        en Common.ps1.
    #>
    param([int]$Requested)

    $info = Get-AdoptiumReleases

    if ($Requested -gt 0) {
        if ($info -and ($info.available_releases -notcontains $Requested)) {
            Write-Log "Adoptium no publica el JDK $Requested." "ERROR"
            Write-Log "  Disponibles: $($info.available_releases -join ', ')" "WARN"
            Write-Log "  LTS:         $($info.available_lts_releases -join ', ')" "WARN"
            return 0
        }
        return $Requested
    }

    if ($info -and $info.most_recent_lts) {
        Write-Log "Sin -JavaVersion: se usa la ultima LTS ($($info.most_recent_lts))"
        return [int]$info.most_recent_lts
    }

    $fb = $JavaLtsFallback[-1]
    Write-Log "No se pudo consultar Adoptium; se usa la tabla local: JDK $fb" "WARN"
    return $fb
}

function Get-AdoptiumBinary {
    <#
        Datos del JDK para Windows x64: enlace, checksum SHA-256 y version
        completa. Con -Release se pide ESE exacto en vez del ultimo de la
        linea, que es lo que permite fijarlo en un devenv.lock.json.
    #>
    param(
        [int]$Major,
        [string]$Release
    )

    if (-not [string]::IsNullOrWhiteSpace($Release)) {
        Write-Log "Consultando Adoptium por el release exacto $Release..."
        $info = Get-JavaArchiveInfo -Release $Release
        if (-not $info) {
            Write-Log "Adoptium no publica el release '$Release'." "ERROR"
            Write-Log "  Comprueba el nombre exacto, o pide solo la linea:  -JavaVersion $Major" "WARN"
            return $null
        }

        # Se traduce a la forma que espera el resto de ESTE script. Devolver el
        # objeto de Get-JavaArchiveInfo tal cual no valia: usa Url y Sha256
        # donde aqui se leen Link y Sha256, asi que la descarga se quedaba sin
        # URL y fallaba con "el argumento 'Uri' es una cadena vacia".
        return [PSCustomObject]@{
            Release  = $info.Release
            Semver   = $null
            FileName = $info.FileName
            Link     = $info.Url
            Sha256   = $info.Sha256
            SizeMb   = $info.SizeMb
        }
    }

    $uri = "$AdoptiumApi/assets/latest/$Major/hotspot" +
           "?architecture=x64&image_type=jdk&os=windows&vendor=eclipse"

    Write-Log "Consultando Adoptium por el JDK $Major..."
    $assets = Invoke-JsonApi -Uri $uri -TimeoutSec 120

    if (-not $assets -or $assets.Count -eq 0) {
        Write-Log "Adoptium no devolvio ningun binario para el JDK $Major." "ERROR"
        return $null
    }

    # Puede devolver varios (jdk/jre, distintos empaquetados): nos quedamos con
    # el zip, que es el unico que se puede usar sin instalador.
    $zip = @($assets | Where-Object { $_.binary.package.name -like '*.zip' })
    if ($zip.Count -eq 0) {
        Write-Log "Adoptium no publica zip para el JDK $Major en Windows x64." "ERROR"
        Write-Log "  Solo hay instalador .msi, que no sirve para el modo portable." "WARN"
        return $null
    }

    $r = $zip[0]
    return [PSCustomObject]@{
        Release  = $r.release_name
        Semver   = $r.version.semver
        FileName = $r.binary.package.name
        Link     = $r.binary.package.link
        Sha256   = $r.binary.package.checksum
        SizeMb   = [math]::Round($r.binary.package.size / 1MB, 1)
    }
}

$ReleaseMarker = ".assassinskipadm-release"

function Get-InstalledJavaVersion {
    param([string]$JavaExe)

    # java -version escribe en stderr por decision historica, de ahi el -Quiet.
    $run = Invoke-NativeCommand -FilePath $JavaExe -Arguments @('-version') -Quiet
    if ($run.ExitCode -ne 0) { return $null }
    if ($run.Output -match 'version "([^"]+)"') { return $Matches[1] }
    return $null
}

function Get-InstalledJavaRelease {
    <#
        Lee la release exacta que se instalo, de un archivo que dejamos nosotros.

        No se compara la version que reporta "java -version" porque los formatos
        no coinciden entre familias (JDK 21 dice "21.0.12", JDK 8 dice
        "1.8.0_462") y porque comparar como texto da falsos positivos: "21.0.1"
        esta contenido en "21.0.12", asi que un JDK con muchos parches de
        retraso se daba por actualizado.
    #>
    param([string]$JdkPath)

    $file = Join-Path $JdkPath $ReleaseMarker
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    return (Get-Content -LiteralPath $file -Raw).Trim()
}

function Set-InstalledJavaRelease {
    param([string]$JdkPath, [string]$Release)
    Set-Content -LiteralPath (Join-Path $JdkPath $ReleaseMarker) -Value $Release -Encoding ASCII
}

function Get-JavaPortable {
    param([PSCustomObject]$Binary, [string]$FolderName)

    $jdkPath = Join-Path $JavaRoot $FolderName
    $javaExe = Join-Path $jdkPath "bin\java.exe"

    if (Test-Path $javaExe) {
        $installedRelease = Get-InstalledJavaRelease -JdkPath $jdkPath
        $installedVersion = Get-InstalledJavaVersion -JavaExe $javaExe

        if ($Force) {
            Write-Log "-Force: se reinstala $FolderName desde cero" "WARN"
            $habia = if ($installedRelease) { $installedRelease } else { $installedVersion }
            if ($habia) { Write-Log "  habia: $habia  ->  se pondra: $($Binary.Release)" }
            Remove-Item -LiteralPath $jdkPath -Recurse -Force
        }
        elseif ($installedRelease -eq $Binary.Release) {
            Write-Log "JDK $($Binary.Release) ya esta instalado y al dia" "SUCCESS"
            return $jdkPath
        }
        elseif ($installedRelease) {
            Write-Log "Ya hay un JDK instalado en ${FolderName}: $installedRelease" "WARN"
            Write-Log "  Disponible: $($Binary.Release)" "WARN"
            Write-Log "  Para actualizarlo:  .\Setup-JavaEnv.bat -JavaVersion $JavaVersion -Force" "WARN"
            return $jdkPath
        }
        elseif ($installedVersion) {
            # Instalado por una version del kit anterior al marcador: no se puede
            # saber si esta al dia, asi que se dice en vez de suponer.
            Write-Log "Hay un JDK $installedVersion en $FolderName, sin marca de release" "WARN"
            Write-Log "  Disponible: $($Binary.Release)" "WARN"
            Write-Log "  No se puede comparar; reinstala con -Force si quieres asegurarte." "WARN"
            return $jdkPath
        }
        else {
            Write-Log "Hay un java.exe que no arranca en $FolderName" "ERROR"
            Write-Log "  Instalacion corrupta. Reinstala con:  -JavaVersion $JavaVersion -Force" "WARN"
            return $null
        }
    }

    if (-not (Test-Path $JavaRoot)) {
        New-Item -ItemType Directory -Path $JavaRoot -Force | Out-Null
    }

    $zipPath = Join-Path $JavaRoot $Binary.FileName

    Write-Log "Descargando $($Binary.Release) ($($Binary.SizeMb) MB)..."
    $ok = Invoke-Download -Uri $Binary.Link `
                          -OutFile $zipPath `
                          -Sha256 $Binary.Sha256 `
                          -Description "JDK $($Binary.Release)"
    if (-not $ok) {
        Write-Log "Los binarios de Adoptium se sirven desde GitHub." "WARN"
        Write-Log "  Si tu red bloquea github.com, pidelo a IT o usa otra fuente." "WARN"
        return $null
    }

    if (-not (Test-ZipIntegrity -ZipPath $zipPath)) {
        Write-Log "El zip del JDK llego danado" "ERROR"
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        return $null
    }

    Write-Log "Extrayendo..."
    $temp = Join-Path $JavaRoot "temp_jdk"
    if (Test-Path $temp) { Remove-Item $temp -Recurse -Force }
    Expand-Archive -Path $zipPath -DestinationPath $temp -Force

    # El zip trae una carpeta raiz con el nombre de la release (jdk-21.0.12+8):
    # se sube su contenido un nivel para que la ruta sea estable.
    $inner = @(Get-ChildItem $temp -Directory)
    if ($inner.Count -eq 1) {
        Move-Item -LiteralPath $inner[0].FullName -Destination $jdkPath -Force
    }
    else {
        New-Item -ItemType Directory -Path $jdkPath -Force | Out-Null
        Move-Item -Path "$temp\*" -Destination $jdkPath -Force
    }

    Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $zipPath -Force

    Set-InstalledJavaRelease -JdkPath $jdkPath -Release $Binary.Release

    Write-Log "JDK instalado en $jdkPath" "SUCCESS"
    return $jdkPath
}

# --------------------------------------------------------------------------

# Los exit viven AQUI, en el cuerpo del script, y no dentro de las funciones:
# ellas explican que fallo y devuelven $null (o 0), y es este nivel el que decide
# que eso es fatal. Asi se pueden probar por separado y reutilizar desde otro
# script sin que se lleven por delante el proceso entero.
# Se separa lo pedido en linea y release exacto ANTES de resolver: la carpeta y
# los mensajes van por la linea, y el exacto solo decide que binario se baja.
$pedido      = Split-RuntimeVersionSpec -Clave java -Spec $JavaVersion
$JavaRelease = $pedido.Exacta

$JavaVersion = Resolve-JavaVersion -Requested ([int]$(if ($pedido.Linea) { $pedido.Linea } else { 0 }))
if ($JavaVersion -le 0) { exit 1 }

$FolderName = "jdk-$JavaVersion"

Write-Log "Carpeta destino: $JavaRoot" "INFO"
Write-Log ""

$binary = Get-AdoptiumBinary -Major $JavaVersion -Release $JavaRelease
if (-not $binary) { exit 1 }

Write-Log "  Release : $($binary.Release)"
Write-Log "  Archivo : $($binary.FileName)"
Write-Log ""

if ($WhatIf) {
    # Aqui el plan vale doble: la API de Adoptium ya ha dicho el tamano exacto,
    # asi que se ve que son ~200 MB antes de empezar a bajarlos.
    $destino = Join-Path $JavaRoot $FolderName
    $javaExe = Join-Path $destino "bin\java.exe"
    $yaHay = if (Test-Path $javaExe) { Get-InstalledJavaRelease -JdkPath $destino } else { $null }

    Write-Host ""
    Write-Host "Se va a instalar:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host ("  [release]  {0}" -f $binary.Release)
    Write-Host ("  [descarga] {0} MB  (SHA-256 verificado)" -f $binary.SizeMb)
    Write-Host ("             {0}" -f $binary.Link) -ForegroundColor DarkGray
    Write-Host ("  [carpeta]  {0}" -f $destino)
    if ($yaHay) {
        if ($yaHay -eq $binary.Release) {
            Write-Host  "             ya esta instalada esa misma release: no se descargaria nada" -ForegroundColor Green
        }
        elseif ($Force) {
            Write-Host ("             -Force BORRARIA la actual ({0})" -f $yaHay) -ForegroundColor Red
        }
        else {
            Write-Host ("             ya hay {0}; sin -Force no se tocaria" -f $yaHay) -ForegroundColor Yellow
        }
    }
    Write-Host ("  [PATH]     {0}" -f (Join-Path $destino "bin"))
    Write-Host ("  [shell]    java{0}-shell.bat" -f $JavaVersion)
    if ($SetJavaHome) {
        $previo = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'User')
        Write-Host ("  [JAVA_HOME] de usuario -> {0}" -f $destino) -ForegroundColor Yellow
        if ($previo) { Write-Host ("              sustituiria a: {0}" -f $previo) -ForegroundColor Yellow }
        Write-Host  "              Maven, Gradle y los IDE compilarian con este JDK." -ForegroundColor Yellow
    }
    else {
        Write-Host  "  [JAVA_HOME] no se tocaria (usa -SetJavaHome si lo quieres)" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "-WhatIf: no se ha tocado nada." -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

$jdkPath = Get-JavaPortable -Binary $binary -FolderName $FolderName
if (-not $jdkPath) { exit 1 }

$binPath = Join-Path $jdkPath "bin"

Show-PathConflicts -Root $JavaRoot -Keep $jdkPath -Label "Java"
Add-UserPathEntry -Path $binPath

if ($SetJavaHome) {
    $previous = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'User')
    if ($previous) {
        Write-Log "JAVA_HOME de usuario anterior: $previous" "WARN"
    }
    [Environment]::SetEnvironmentVariable('JAVA_HOME', $jdkPath, 'User')
    Write-Log "JAVA_HOME de usuario = $jdkPath" "SUCCESS"
    Write-Log "  Maven, Gradle y los IDE compilaran con este JDK." "WARN"
}
else {
    Write-Log "JAVA_HOME no se ha tocado (usa -SetJavaHome si lo quieres)." "INFO"
}

Write-JavaShell -JdkPath $jdkPath -Major $JavaVersion -Release $binary.Release | Out-Null
Write-Log "Shell creado: $jdkPath\java$JavaVersion-shell.bat" "SUCCESS"

# Maven y Gradle llevan un shell por cada JDK; el que se acaba de instalar tiene
# que aparecer ahi sin que haya que reejecutar sus Setup a mano.
foreach ($linea in @(Sync-BuildToolShells)) { Write-Log "Shells al dia: $linea" "SUCCESS" }

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  CONFIGURACION COMPLETADA" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Estructura creada:" -ForegroundColor Yellow
Write-Host "  $JavaRoot"
Write-Host "  +-- $FolderName\"
Write-Host "      +-- bin\java.exe"
Write-Host "      +-- java$JavaVersion-shell.bat"
Write-Host ""
Write-Host "JDK $($binary.Release) agregado al PATH." -ForegroundColor Green
Write-Host ""
Write-Host "Para comenzar:" -ForegroundColor Yellow
Write-Host "  Usa el shell: ..\Java\$FolderName\java$JavaVersion-shell.bat" -ForegroundColor White
Write-Host "  Comprueba con: .\Doctor-Env.bat" -ForegroundColor Gray
Write-Host ""
