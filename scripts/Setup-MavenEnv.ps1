#Requires -Version 5.1
<#
.SYNOPSIS
    Setup-MavenEnv.ps1 - Instala Apache Maven sin permisos de administrador.
.DESCRIPTION
    Maven se distribuye como un zip y no trae instalador, asi que aqui no hay
    nada que esquivar: es el camino oficial y nunca ha pedido admin.

    Verifica el SHA-512 que Apache publica junto al zip (SHA-512 y no SHA-256:
    es lo que firman ellos).

    Necesita un JDK. Si hay uno instalado por el kit, el shell generado apunta
    ahi con JAVA_HOME; si no, avisa en vez de fallar con un error de Java que no
    explica nada.

    Con varios JDK instalados se escribe ADEMAS un shell por cada uno
    (mvn39-java21-shell.bat, mvn39-java25-shell.bat...), para trabajar el mismo
    dia en proyectos que piden Javas distintos sin tocar JAVA_HOME ni reejecutar
    nada: se abre el shell que toque.
.PARAMETER MavenVersion
    Version concreta (ej: 3.9.16). Si se omite, la ultima publicada.
.PARAMETER JavaVersion
    A que JDK del kit apunta el shell por defecto (ej: 21). Si se omite, el mas
    alto instalado.
.PARAMETER Force
    Reinstala aunque ya exista esa linea.
.PARAMETER WhatIf
    Muestra el plan y no toca nada.
.EXAMPLE
    .\Setup-MavenEnv.ps1
.EXAMPLE
    .\Setup-MavenEnv.ps1 -MavenVersion 3.9.16 -Force
.EXAMPLE
    .\Setup-MavenEnv.ps1 -JavaVersion 21
#>

param(
    [string]$MavenVersion,

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

$MavenRoot = Join-Path $WorkspaceRoot "Maven"

Write-Log "========================================" "INFO"
Write-Log "  Apache Maven Setup" "INFO"
Write-Log "========================================" "INFO"
Write-Log ""

function Get-InstalledMavenVersion {
    param([string]$MvnCmd)

    # mvn es un .cmd, asi que se invoca por cmd /c: Invoke-NativeCommand espera
    # un ejecutable. Y necesita JAVA_HOME, que aqui puede no estar puesto, asi
    # que se lee la version del archivo que trae el propio Maven, que no depende
    # de que Java arranque.
    $pom = Join-Path (Split-Path -Parent (Split-Path -Parent $MvnCmd)) "lib\maven-core-*.jar"
    $jar = @(Get-ChildItem -Path $pom -ErrorAction SilentlyContinue)
    if ($jar.Count -gt 0 -and $jar[0].Name -match 'maven-core-([\d.]+)\.jar') {
        return $Matches[1]
    }
    return $null
}

function Get-MavenPortable {
    param([PSCustomObject]$Release, [string]$FolderName)

    $mavenPath = Join-Path $MavenRoot $FolderName
    $mvnCmd    = Join-Path $mavenPath "bin\mvn.cmd"

    if (Test-Path $mvnCmd) {
        $instalada = Get-InstalledMavenVersion -MvnCmd $mvnCmd

        if ($Force) {
            Write-Log "-Force: se reinstala $FolderName desde cero" "WARN"
            if ($instalada) { Write-Log "  habia: $instalada  ->  se pondra: $($Release.Version)" }
            Remove-Item -LiteralPath $mavenPath -Recurse -Force
        }
        elseif ($instalada -eq $Release.Version) {
            Write-Log "Maven $instalada ya esta instalado y al dia" "SUCCESS"
            return $mavenPath
        }
        elseif ($instalada) {
            Write-Log "Ya hay Maven $instalada instalado en $FolderName" "WARN"
            Write-Log "  Disponible: $($Release.Version)" "WARN"
            Write-Log "  Para actualizarlo:  .\bin\Setup-MavenEnv.bat -MavenVersion $($Release.Version) -Force" "WARN"
            return $mavenPath
        }
        else {
            Write-Log "Hay un Maven que no se reconoce en $FolderName" "ERROR"
            Write-Log "  Instalacion corrupta. Reinstala con:  -Force" "WARN"
            return $null
        }
    }

    if (-not (Test-Path $MavenRoot)) {
        New-Item -ItemType Directory -Path $MavenRoot -Force | Out-Null
    }

    $zipPath = Join-Path $MavenRoot $Release.FileName

    if (-not $Release.Sha512) {
        Write-Log "Apache no devolvio el SHA-512; se continua sin verificar hash" "WARN"
    }

    Write-Log "Descargando Maven $($Release.Version)..."
    if (-not (Invoke-Download -Uri $Release.Url -OutFile $zipPath -Sha512 $Release.Sha512 `
                              -Description "Apache Maven $($Release.Version)")) {
        return $null
    }

    if (-not (Test-ZipIntegrity -ZipPath $zipPath)) {
        Write-Log "El zip de Maven llego danado o incompleto" "ERROR"
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        return $null
    }

    Write-Log "Extrayendo..."
    # El zip trae dentro apache-maven-X.Y.Z; la instalacion se guarda como
    # maven-<linea>, una carpeta por linea igual que python-3.12 y git-2.55.
    $temp = Join-Path $MavenRoot "temp_maven"
    if (Test-Path $temp) { Remove-Item $temp -Recurse -Force }
    Expand-Archive -Path $zipPath -DestinationPath $temp -Force

    $inner = @(Get-ChildItem $temp -Directory)
    if ($inner.Count -eq 1) {
        Move-Item -LiteralPath $inner[0].FullName -Destination $mavenPath -Force
    }
    else {
        New-Item -ItemType Directory -Path $mavenPath -Force | Out-Null
        Move-Item -Path "$temp\*" -Destination $mavenPath -Force
    }

    Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $zipPath -Force

    Write-Log "Maven instalado en $mavenPath" "SUCCESS"
    return $mavenPath
}

# --------------------------------------------------------------------------

Write-Log $(if ($MavenVersion) { "Buscando Maven $MavenVersion..." } else { "Consultando la ultima version de Maven..." })

$release = Get-MavenRelease -Version $MavenVersion
if (-not $release) {
    Write-Log "No se pudo determinar que Maven instalar." "ERROR"
    Write-Log "  No se pudo leer $MavenBaseUrl. Reintenta, o indica la version:" "WARN"
    Write-Log "    .\bin\Setup-MavenEnv.bat -MavenVersion 3.9.16" "WARN"
    exit 1
}

Write-Log "  Version: $($release.Version)" "SUCCESS"

$line       = Get-ToolLine -Version $release.Version
$FolderName = "maven-$line"
$shellName  = "mvn$($line -replace '\.','')-shell.bat"
$javaHome   = Resolve-KitJdk -Linea $JavaVersion
if ($JavaVersion -and -not $javaHome) {
    $hay = @(Get-KitJdkLines)
    Write-Log "El kit no tiene instalado el JDK $JavaVersion." "ERROR"
    Write-Log "  Instalado: $(if ($hay.Count) { $hay -join ', ' } else { '(ninguno)' })" "WARN"
    Write-Log "  Instalalo con:  .\bin\Setup-JavaEnv.bat -JavaVersion $JavaVersion" "WARN"
    exit 1
}

Write-Log "Carpeta destino: $MavenRoot" "INFO"
if ($javaHome) { Write-Log "JDK del kit:     $javaHome" "INFO" }
else           { Write-Log "Sin JDK del kit: instala uno con .\bin\Setup-JavaEnv.bat" "WARN" }
Write-Log ""

if ($WhatIf) {
    $destino = Join-Path $MavenRoot $FolderName
    $yaHay = if (Test-Path (Join-Path $destino "bin\mvn.cmd")) {
        Get-InstalledMavenVersion -MvnCmd (Join-Path $destino "bin\mvn.cmd")
    } else { $null }

    Write-Host ""
    Write-Host "Se va a instalar:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host ("  [version]  Maven {0}" -f $release.Version)
    $hashTxt = if ($release.Sha512) { "SHA-512 verificado" } else { "SIN checksum" }
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
        Write-Host ("             mvn{0}-java{1}-shell.bat" -f ($line -replace '\.',''), $j) -ForegroundColor DarkGray
    }
    if ($javaHome) { Write-Host ("  [JAVA_HOME] {0}   (solo dentro del shell)" -f $javaHome) }
    else           { Write-Host  "  [JAVA_HOME] sin JDK del kit: Maven no arrancara sin uno" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "-WhatIf: no se ha tocado nada." -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

$mavenPath = Get-MavenPortable -Release $release -FolderName $FolderName
if (-not $mavenPath) { exit 1 }

Show-PathConflicts -Root $MavenRoot -Keep (Join-Path $mavenPath "bin") -Label "Maven"
Add-UserPathEntry -Path (Join-Path $mavenPath "bin")

Write-BuildToolShell -Tool Maven -ToolPath $mavenPath -Version $release.Version -JavaHome $javaHome | Out-Null
Write-Log "Shell creado: $mavenPath\$shellName" "SUCCESS"
# La CA de la empresa y el proxy, si los hay guardados. Una herramienta recien
# instalada nace sin ellos y falla con un error de certificado o de red que no
# menciona nada de esto.
foreach ($linea in @(Sync-CorpNet)) { Write-Log $linea "SUCCESS" }


# Con varios JDK instalados, uno por cada uno: abrir el que toque es mas comodo
# que reejecutar este comando para cambiar de Java.
$porJdk = Write-BuildToolShellsPorJdk -Tool Maven -ToolPath $mavenPath -Version $release.Version
foreach ($s in $porJdk.Escritos) { Write-Log "  y ademas: $(Split-Path -Leaf $s)" "SUCCESS" }
if ($porJdk.Borrados -gt 0) { Write-Log "  retirados $($porJdk.Borrados) shells de JDK que ya no estan" "INFO" }

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  CONFIGURACION COMPLETADA" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Estructura creada:" -ForegroundColor Yellow
Write-Host "  $MavenRoot"
Write-Host "  +-- $FolderName\"
Write-Host "      +-- bin\mvn.cmd"
Write-Host "      +-- $shellName"
Write-Host ""
Write-Host "Maven $($release.Version) agregado al PATH." -ForegroundColor Green
if (-not $javaHome) {
    Write-Host ""
    Write-Host "Maven NO arrancara sin un JDK. Instala uno con:" -ForegroundColor Yellow
    Write-Host "  .\bin\Setup-JavaEnv.bat" -ForegroundColor White
    Write-Host "y vuelve a ejecutar este comando para que el shell lo recoja." -ForegroundColor Gray
}
Write-Host ""
Write-Host "Para comenzar:" -ForegroundColor Yellow
Write-Host "  Usa el shell: ..\Maven\$FolderName\$shellName" -ForegroundColor White
Write-Host "  Comprueba con: .\bin\Doctor-Env.bat" -ForegroundColor Gray
Write-Host ""
