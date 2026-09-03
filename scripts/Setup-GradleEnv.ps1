#Requires -Version 5.1
<#
.SYNOPSIS
    Setup-GradleEnv.ps1 - Instala Gradle sin permisos de administrador.
.DESCRIPTION
    Gradle se distribuye como un zip y no trae instalador, asi que aqui no hay
    nada que esquivar: es el camino oficial y nunca ha pedido admin.

    Verifica el SHA-256 que Gradle publica junto al zip.

    Necesita un JDK. Si hay uno instalado por el kit, el shell generado apunta
    ahi con JAVA_HOME; si no, avisa en vez de fallar con un error de Java que no
    explica nada.

    Con varios JDK instalados se escribe ADEMAS un shell por cada uno
    (gradle97-java21-shell.bat, gradle97-java25-shell.bat...), para trabajar el
    mismo dia en proyectos que piden Javas distintos sin tocar JAVA_HOME ni
    reejecutar nada: se abre el shell que toque.
.PARAMETER GradleVersion
    Version concreta (ej: 9.7.1). Si se omite, la actual segun la API de Gradle.
.PARAMETER JavaVersion
    A que JDK del kit apunta el shell por defecto (ej: 21). Si se omite, el mas
    alto instalado.
.PARAMETER Force
    Reinstala aunque ya exista esa linea.
.PARAMETER WhatIf
    Muestra el plan y no toca nada.
.EXAMPLE
    .\Setup-GradleEnv.ps1
.EXAMPLE
    .\Setup-GradleEnv.ps1 -GradleVersion 8.14 -Force
.EXAMPLE
    .\Setup-GradleEnv.ps1 -JavaVersion 21
#>

param(
    [string]$GradleVersion,

    # A que JDK del kit ata el shell por defecto (ej: 21). Sin esto se usa el
    # mas alto instalado. Ademas, si hay varios JDK se genera un shell por cada
    # uno, para poder cambiar de Java sin reejecutar esto.
    [string]$JavaVersion,

    [switch]$Force,

    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

$GradleRoot = Join-Path $WorkspaceRoot "Gradle"

Write-Log "========================================" "INFO"
Write-Log "  Gradle Setup" "INFO"
Write-Log "========================================" "INFO"
Write-Log ""

function Get-InstalledGradleVersion {
    param([string]$GradlePath)

    # Se lee del nombre del jar que trae dentro y no ejecutando gradle: gradle
    # necesita JAVA_HOME, que aqui puede no estar puesto, y ademas arranca un
    # demonio que tarda.
    $jars = @(Get-ChildItem -Path (Join-Path $GradlePath "lib\gradle-launcher-*.jar") -ErrorAction SilentlyContinue)
    if ($jars.Count -gt 0 -and $jars[0].Name -match 'gradle-launcher-([\d.]+)\.jar') {
        return $Matches[1]
    }
    return $null
}

function Get-GradlePortable {
    param([PSCustomObject]$Release, [string]$FolderName)

    $gradlePath = Join-Path $GradleRoot $FolderName
    $gradleBat  = Join-Path $gradlePath "bin\gradle.bat"

    if (Test-Path $gradleBat) {
        $instalada = Get-InstalledGradleVersion -GradlePath $gradlePath

        if ($Force) {
            Write-Log "-Force: se reinstala $FolderName desde cero" "WARN"
            if ($instalada) { Write-Log "  habia: $instalada  ->  se pondra: $($Release.Version)" }
            Remove-Item -LiteralPath $gradlePath -Recurse -Force
        }
        elseif ($instalada -eq $Release.Version) {
            Write-Log "Gradle $instalada ya esta instalado y al dia" "SUCCESS"
            return $gradlePath
        }
        elseif ($instalada) {
            Write-Log "Ya hay Gradle $instalada instalado en $FolderName" "WARN"
            Write-Log "  Disponible: $($Release.Version)" "WARN"
            Write-Log "  Para actualizarlo:  .\bin\Setup-GradleEnv.bat -GradleVersion $($Release.Version) -Force" "WARN"
            return $gradlePath
        }
        else {
            Write-Log "Hay un Gradle que no se reconoce en $FolderName" "ERROR"
            Write-Log "  Instalacion corrupta. Reinstala con:  -Force" "WARN"
            return $null
        }
    }

    if (-not (Test-Path $GradleRoot)) {
        New-Item -ItemType Directory -Path $GradleRoot -Force | Out-Null
    }

    $zipPath = Join-Path $GradleRoot $Release.FileName

    if (-not $Release.Sha256) {
        Write-Log "Gradle no devolvio el SHA-256; se continua sin verificar hash" "WARN"
    }

    Write-Log "Descargando Gradle $($Release.Version)..."
    Write-Log "  (unos 130 MB)"
    if (-not (Invoke-Download -Uri $Release.Url -OutFile $zipPath -Sha256 $Release.Sha256 `
                              -Description "Gradle $($Release.Version)")) {
        return $null
    }

    if (-not (Test-ZipIntegrity -ZipPath $zipPath)) {
        Write-Log "El zip de Gradle llego danado o incompleto" "ERROR"
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        return $null
    }

    Write-Log "Extrayendo..."
    $temp = Join-Path $GradleRoot "temp_gradle"
    if (Test-Path $temp) { Remove-Item $temp -Recurse -Force }
    Expand-Archive -Path $zipPath -DestinationPath $temp -Force

    $inner = @(Get-ChildItem $temp -Directory)
    if ($inner.Count -eq 1) {
        Move-Item -LiteralPath $inner[0].FullName -Destination $gradlePath -Force
    }
    else {
        New-Item -ItemType Directory -Path $gradlePath -Force | Out-Null
        Move-Item -Path "$temp\*" -Destination $gradlePath -Force
    }

    Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $zipPath -Force

    Write-Log "Gradle instalado en $gradlePath" "SUCCESS"
    return $gradlePath
}

# --------------------------------------------------------------------------

Write-Log $(if ($GradleVersion) { "Buscando Gradle $GradleVersion..." } else { "Consultando la version actual de Gradle..." })

$release = Get-GradleRelease -Version $GradleVersion
if (-not $release) {
    Write-Log "No se pudo determinar que Gradle instalar." "ERROR"
    Write-Log "  No se pudo leer $GradleVersionApi. Reintenta, o indica la version:" "WARN"
    Write-Log "    .\bin\Setup-GradleEnv.bat -GradleVersion 9.7.1" "WARN"
    exit 1
}

Write-Log "  Version: $($release.Version)" "SUCCESS"

$line       = Get-ToolLine -Version $release.Version
$FolderName = "gradle-$line"
$shellName  = "gradle$($line -replace '\.','')-shell.bat"
$javaHome   = Resolve-KitJdk -Linea $JavaVersion
if ($JavaVersion -and -not $javaHome) {
    $hay = @(Get-KitJdkLines)
    Write-Log "El kit no tiene instalado el JDK $JavaVersion." "ERROR"
    Write-Log "  Instalado: $(if ($hay.Count) { $hay -join ', ' } else { '(ninguno)' })" "WARN"
    Write-Log "  Instalalo con:  .\bin\Setup-JavaEnv.bat -JavaVersion $JavaVersion" "WARN"
    exit 1
}

Write-Log "Carpeta destino: $GradleRoot" "INFO"
if ($javaHome) { Write-Log "JDK del kit:     $javaHome" "INFO" }
else           { Write-Log "Sin JDK del kit: instala uno con .\bin\Setup-JavaEnv.bat" "WARN" }
Write-Log ""

if ($WhatIf) {
    $destino = Join-Path $GradleRoot $FolderName
    $yaHay = if (Test-Path (Join-Path $destino "bin\gradle.bat")) {
        Get-InstalledGradleVersion -GradlePath $destino
    } else { $null }

    Write-Host ""
    Write-Host "Se va a instalar:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host ("  [version]  Gradle {0}" -f $release.Version)
    $hashTxt = if ($release.Sha256) { "SHA-256 verificado" } else { "SIN checksum" }
    Write-Host ("  [descarga] {0}  ({1})" -f $release.Url, $hashTxt) -ForegroundColor DarkGray
    Write-Host ("  [carpeta]  {0}" -f $destino)
    if ($yaHay) {
        if ($Force) { Write-Host ("             -Force BORRARIA la actual ({0})" -f $yaHay) -ForegroundColor Red }
        else        { Write-Host ("             ya hay {0}; sin -Force no se tocaria" -f $yaHay) -ForegroundColor Yellow }
    }
    Write-Host ("  [PATH]     {0}\bin" -f $destino)
    Write-Host ("  [shell]    {0}" -f $shellName)
    $jdks = @(Get-KitJdkLines)
    foreach ($j in $(if ($jdks.Count -ge 2) { $jdks } else { @() })) {
        Write-Host ("             gradle{0}-java{1}-shell.bat" -f ($line -replace '\.',''), $j) -ForegroundColor DarkGray
    }
    if ($javaHome) { Write-Host ("  [JAVA_HOME] {0}   (solo dentro del shell)" -f $javaHome) }
    else           { Write-Host  "  [JAVA_HOME] sin JDK del kit: Gradle no arrancara sin uno" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "-WhatIf: no se ha tocado nada." -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

$gradlePath = Get-GradlePortable -Release $release -FolderName $FolderName
if (-not $gradlePath) { exit 1 }

Show-PathConflicts -Root $GradleRoot -Keep (Join-Path $gradlePath "bin") -Label "Gradle"
Add-UserPathEntry -Path (Join-Path $gradlePath "bin")

Write-BuildToolShell -Tool Gradle -ToolPath $gradlePath -Version $release.Version -JavaHome $javaHome | Out-Null
Write-Log "Shell creado: $gradlePath\$shellName" "SUCCESS"
# La CA de la empresa y el proxy, si los hay guardados. Una herramienta recien
# instalada nace sin ellos y falla con un error de certificado o de red que no
# menciona nada de esto.
foreach ($linea in @(Sync-CorpNet)) { Write-Log $linea "SUCCESS" }


# Con varios JDK instalados, uno por cada uno: abrir el que toque es mas comodo
# que reejecutar este comando para cambiar de Java.
$porJdk = Write-BuildToolShellsPorJdk -Tool Gradle -ToolPath $gradlePath -Version $release.Version
foreach ($s in $porJdk.Escritos) { Write-Log "  y ademas: $(Split-Path -Leaf $s)" "SUCCESS" }
if ($porJdk.Borrados -gt 0) { Write-Log "  retirados $($porJdk.Borrados) shells de JDK que ya no estan" "INFO" }

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  CONFIGURACION COMPLETADA" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Estructura creada:" -ForegroundColor Yellow
Write-Host "  $GradleRoot"
Write-Host "  +-- $FolderName\"
Write-Host "      +-- bin\gradle.bat"
Write-Host "      +-- $shellName"
Write-Host ""
Write-Host "Gradle $($release.Version) agregado al PATH." -ForegroundColor Green
if (-not $javaHome) {
    Write-Host ""
    Write-Host "Gradle NO arrancara sin un JDK. Instala uno con:" -ForegroundColor Yellow
    Write-Host "  .\bin\Setup-JavaEnv.bat" -ForegroundColor White
    Write-Host "y vuelve a ejecutar este comando para que el shell lo recoja." -ForegroundColor Gray
}
Write-Host ""
Write-Host "Para comenzar:" -ForegroundColor Yellow
Write-Host "  Usa el shell: ..\Gradle\$FolderName\$shellName" -ForegroundColor White
Write-Host "  Comprueba con: .\bin\Doctor-Env.bat" -ForegroundColor Gray
Write-Host ""
