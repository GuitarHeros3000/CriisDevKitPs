#Requires -Version 5.1
<#
.SYNOPSIS
    Setup-AngularEnv.ps1 - Configura entorno Angular sin permisos de administrador
.DESCRIPTION
    Descarga Node.js portable e instala Angular CLI en carpeta por version.
    La estructura se crea en una carpeta 'Angular' junto a la raiz del kit.
.PARAMETER AngularVersion
    Version de Angular CLI a instalar (18, 19, 20, etc.)
.PARAMETER NodeVersion
    Fuerza una version concreta de Node (ej: 22.23.2). Si se omite, se resuelve
    automaticamente a partir de los "engines" que declara esa version del CLI.
.PARAMETER NewProject
    Nombre del proyecto a crear automaticamente
.EXAMPLE
    .\Setup-AngularEnv.ps1 -AngularVersion 20
.EXAMPLE
    .\Setup-AngularEnv.ps1 -AngularVersion 18 -NewProject mi-proyecto
.EXAMPLE
    .\Setup-AngularEnv.ps1 -AngularVersion 22 -NodeVersion 24.19.0
#>

param(
    [Parameter(Mandatory=$false)]
    # Admite la linea ("20") o la version exacta del CLI ("20.3.35"), en el
    # mismo parametro, para que un devenv.lock.json pueda fijarla.
    #
    # Sin ValidateRange: ese atributo compara contra un numero y rechazaba
    # "20.3.35" antes siquiera de entrar al script. El rango se comprueba abajo,
    # sobre la LINEA ya extraida.
    [string]$AngularVersion = '20',

    [string]$NodeVersion,

    [string]$NewProject,

    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

$AngularRoot = Join-Path $WorkspaceRoot "Angular"

$NpmRegistryUrl = "https://registry.npmjs.org/@angular%2fcli"

# Suelo de version de Node. Angular 14 declara "^14.15.0 || >=16.10.0", asi que
# sin este limite se elegiria Node 14, que lleva anos sin parches y ya no trae
# binarios utilizables para el tooling actual. Node 16 es el minimo practico.
$MinNodeMajor = 16

# Memoria de consultas al registro de npm, por version mayor de Angular.
$script:AngularEngineCache = @{}

# Respaldo para cuando no hay red o el registro no responde. Cada entrada es la
# Node que resolvio la regla de abajo, con el rango real que declara el CLI.
# Verificado contra registry.npmjs.org el 2026-08-04.
$NodeFallbackByAngular = @{
    14 = @{ Node = '16.20.2'; Engine = '^14.15.0 || >=16.10.0' }
    15 = @{ Node = '16.20.2'; Engine = '^14.20.0 || ^16.13.0 || >=18.10.0' }
    16 = @{ Node = '16.20.2'; Engine = '^16.14.0 || >=18.10.0' }
    17 = @{ Node = '18.20.8'; Engine = '^18.13.0 || >=20.9.0' }
    18 = @{ Node = '20.20.2'; Engine = '^18.19.1 || ^20.11.1 || >=22.0.0' }
    19 = @{ Node = '20.20.2'; Engine = '^18.19.1 || ^20.11.1 || >=22.0.0' }
    20 = @{ Node = '22.23.2'; Engine = '^20.19.0 || ^22.12.0 || >=24.0.0' }
    21 = @{ Node = '22.23.2'; Engine = '^20.19.0 || ^22.12.0 || >=24.0.0' }
    22 = @{ Node = '24.19.0'; Engine = '^22.22.3 || ^24.15.0 || >=26.0.0' }
}

function Initialize-AngularDirectories {
    param([int]$Version)

    $angularPath = Join-Path $EnvSetup.AngularRoot "angular-v$Version"
    $projectsPath = Join-Path $angularPath "projects"

    Write-Log "Creando estructura en:"
    Write-Log "  $angularPath"

    $directories = @(
        $EnvSetup.AngularRoot,
        $angularPath,
        $projectsPath
    )

    foreach ($dir in $directories) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    return $angularPath
}

# --------------------------------------------------------------------------
# Resolucion de la version de Node que necesita este Angular
# --------------------------------------------------------------------------

function Get-AngularNodeEngine {
    <#
        Devuelve el rango "engines.node" que declara la ultima release estable
        del CLI para ese major, leido del registro de npm.
        Se pide el packument abreviado (unos cientos de KB en vez de varios MB).

        Devuelve $null si el registro no respondio, o un objeto con CliVersion
        vacio si respondio pero esa version de Angular no existe. Distinguir los
        dos casos importa: uno se arregla con el proxy, el otro cambiando el numero.
    #>
    param([int]$Version)

    # El packument son cientos de KB y se consulta dos veces (al resolver y al
    # validar). Se memoriza para no bajarlo repetido, que en una red con proxy
    # lento se nota.
    if ($script:AngularEngineCache.ContainsKey($Version)) {
        return $script:AngularEngineCache[$Version]
    }

    $pack = Invoke-JsonApi -Uri $NpmRegistryUrl `
                           -Headers @{ Accept = 'application/vnd.npm.install-v1+json' } `
                           -TimeoutSec 120 -Quiet
    if (-not $pack -or -not $pack.versions) { return $null }

    $stable = @($pack.versions.PSObject.Properties.Name |
        Where-Object { $_ -match "^$Version\." -and $_ -notmatch '-(next|rc|beta|alpha)' } |
        Sort-Object { ConvertTo-SemverObject $_ })

    if ($stable.Count -eq 0) {
        $script:AngularEngineCache[$Version] = [PSCustomObject]@{ CliVersion = $null; Engine = $null }
        return $script:AngularEngineCache[$Version]
    }

    $latest = $stable[-1]
    $script:AngularEngineCache[$Version] = [PSCustomObject]@{
        CliVersion = $latest
        Engine     = $pack.versions.$latest.engines.node
    }
    return $script:AngularEngineCache[$Version]
}


function Select-NodeForEngine {
    <#
    .SYNOPSIS
        Elige la version de Node a instalar para un rango "engines".
    .DESCRIPTION
        Regla: la linea LTS mas alta que el rango nombra EXPLICITAMENTE con "^".
        Los terminos "^X.Y.Z" son las majors contra las que Angular realmente
        probo; el ">=X" final es una puerta abierta a majors que aun no existian
        cuando se publico ese CLI. Coger la mas alta de las nombradas da lo mas
        nuevo que Angular valido de verdad, sin saltar a una Node no probada.

        Si el rango no nombra ninguna LTS disponible con "^", se usa la LTS mas
        baja que cumpla el rango.

        En ambos casos se descartan las lineas por debajo de -MinMajor.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Engine,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$LtsReleases,
        [Parameter(Mandatory=$true)][int]$MinMajor
    )

    $candidates = @($LtsReleases | Where-Object { $_.Major -ge $MinMajor })
    if ($candidates.Count -eq 0) { return $null }

    $named = @()
    foreach ($branch in ($Engine -split '\|\|')) {
        if ($branch.Trim() -match '^\^\s*(\d+)\.') { $named += [int]$Matches[1] }
    }

    $explicit = @($candidates | Where-Object { $named -contains $_.Major } | Sort-Object Major -Descending)
    if ($explicit.Count -gt 0) { return $explicit[0] }

    $satisfying = @($candidates |
        Where-Object { Test-SemverRange -Version $_.Version -Range $Engine } |
        Sort-Object Major)
    if ($satisfying.Count -gt 0) { return $satisfying[0] }

    return $null
}

function Resolve-NodeVersion {
    <#
        Decide que Node instalar: primero lo que pidio el usuario, luego lo que
        dice el registro de npm, y como ultimo recurso la tabla local.

        Devuelve $null si no hay forma de decidirlo, despues de explicar por que.
        No llama a exit: matar el proceso desde dentro de una funcion la hace
        intesteable e impide reutilizarla. Misma convencion que Invoke-Download
        e Invoke-JsonApi en Common.ps1.
    #>
    param(
        [int]$Version,
        [string]$Forced
    )

    if (-not [string]::IsNullOrWhiteSpace($Forced)) {
        Write-Log "Node forzado por parametro: v$Forced" "WARN"
        return $Forced.TrimStart('v')
    }

    Write-Log "Consultando que Node necesita Angular v$Version..."
    $engineInfo = Get-AngularNodeEngine -Version $Version

    # El registro respondio pero no hay ninguna release estable de ese major:
    # es un numero de version equivocado, no un problema de red.
    if ($engineInfo -and -not $engineInfo.CliVersion) {
        Write-Log "No existe ninguna version estable de @angular/cli v$Version." "ERROR"
        Write-Log "  Comprueba el numero:  npm view @angular/cli versions" "WARN"
        return $null
    }

    if ($engineInfo -and $engineInfo.Engine) {
        Write-Log "  @angular/cli@$($engineInfo.CliVersion) requiere Node: $($engineInfo.Engine)"

        # Se avisa UNA vez y aqui, no dentro de Test-SemverRange: alli se llama una
        # vez por cada version candidata de Node y el aviso saldria repetido.
        $raros = Get-UnsupportedSemverComparators -Range $engineInfo.Engine
        if ($raros.Count -gt 0) {
            Write-Log "  Aviso: hay terminos del rango que este kit no sabe leer: $($raros -join ', ')" "WARN"
            Write-Log "  Se ignoran, asi que la Node elegida puede no ser la mejor." "WARN"
            Write-Log "  Si algo falla, fuerza la version:  -NodeVersion 22.23.2" "WARN"
        }

        $lts = Get-NodeLtsReleases
        $pick = Select-NodeForEngine -Engine $engineInfo.Engine -LtsReleases $lts -MinMajor $MinNodeMajor

        if ($pick) {
            Write-Log "  Node elegido: v$($pick.Version) (LTS $($pick.Lts))" "SUCCESS"
            if ($pick.Major -lt 20) {
                Write-Log "  Aviso: la linea Node $($pick.Major) ya no recibe parches de seguridad." "WARN"
                Write-Log "  Es la que pide este Angular; para otra usa -NodeVersion." "WARN"
            }
            return $pick.Version
        }

        Write-Log "  No se encontro una LTS de Node que cumpla ese rango" "WARN"
    }

    if ($NodeFallbackByAngular.ContainsKey($Version)) {
        $fb = $NodeFallbackByAngular[$Version]
        Write-Log "  Sin datos del registro; uso la tabla local: Node v$($fb.Node)" "WARN"
        Write-Log "  (rango conocido para Angular v${Version}: $($fb.Engine))"
        return $fb.Node
    }

    Write-Log "No se pudo determinar que Node necesita Angular v$Version." "ERROR"
    Write-Log "  No hay conexion al registro de npm y la version no esta en la tabla local." "ERROR"
    Write-Log "  Indica la version a mano:  -NodeVersion 22.23.2" "WARN"
    return $null
}

function Test-NodeSatisfiesAngular {
    <#
        Ultima red de seguridad: avisa antes de descargar 30 MB si la Node
        elegida no cumple lo que pide el CLI (tipico al usar -NodeVersion).
    #>
    param(
        [string]$NodeVer,
        [int]$Version
    )

    $engine = $null
    $info = Get-AngularNodeEngine -Version $Version
    if ($info) { $engine = $info.Engine }
    elseif ($NodeFallbackByAngular.ContainsKey($Version)) { $engine = $NodeFallbackByAngular[$Version].Engine }

    if (-not $engine) { return }

    if (Test-SemverRange -Version $NodeVer -Range $engine) {
        Write-Log "Node v$NodeVer cumple los requisitos de Angular v$Version" "SUCCESS"
    }
    else {
        Write-Log "Node v$NodeVer NO cumple lo que pide Angular v${Version}: $engine" "WARN"
        Write-Log "  La instalacion del CLI puede fallar con EBADENGINE." "WARN"
    }
}

function Get-NodeJsPortable {
    $nodeFolderPath = Join-Path $EnvSetup.AngularRoot $EnvSetup.NodeFolderName

    if (Test-Path (Join-Path $nodeFolderPath "node.exe")) {
        Write-Log "Node.js ya existe: $nodeFolderPath" "SUCCESS"
        return $nodeFolderPath
    }

    $nodeZipPath = Join-Path $EnvSetup.AngularRoot $EnvSetup.NodeZipName

    # nodejs.org publica SHASUMS256.txt junto a cada release: lo leemos para
    # verificar la descarga. Si no se puede obtener, seguimos pero avisando.
    Write-Log "Obteniendo checksum oficial de Node.js..."
    $expectedHash = Get-Sha256FromShasums -Uri $EnvSetup.NodeShasumsUrl -FileName $EnvSetup.NodeZipName
    if (-not $expectedHash) {
        Write-Log "No se pudo leer el checksum oficial; se continua sin verificar hash" "WARN"
    }

    Write-Log "Descargando Node.js v$($EnvSetup.NodeVersion)..."
    $ok = Invoke-Download -Uri $EnvSetup.NodeDownloadUrl `
                          -OutFile $nodeZipPath `
                          -Sha256 $expectedHash `
                          -Description "Node.js v$($EnvSetup.NodeVersion)"
    if (-not $ok) { return $null }

    if (-not (Test-ZipIntegrity -ZipPath $nodeZipPath)) {
        Write-Log "El zip de Node.js llego danado o incompleto" "ERROR"
        Remove-Item $nodeZipPath -Force -ErrorAction SilentlyContinue
        return $null
    }

    Write-Log "Extrayendo..."
    Expand-Archive -Path $nodeZipPath -DestinationPath $EnvSetup.AngularRoot -Force
    Remove-Item $nodeZipPath -Force
    Write-Log "Node.js instalado" "SUCCESS"

    return $nodeFolderPath
}

function Install-AngularCLI {
    param(
        [string]$AngularPath,
        [string]$NodePath,
        [int]$Version
    )

    $npmCmd = Join-Path $NodePath "npm.cmd"
    $npmPrefix = Join-Path $AngularPath "npm-global"
    $npmCache = Join-Path $EnvSetup.AngularRoot "npm-cache"

    Write-Log "Instalando Angular CLI v$Version..."

    # npm se configura por variables de entorno, y solo para este proceso.
    # "npm config set cache" (sin --global) escribe en %USERPROFILE%\.npmrc de
    # forma permanente: dejaba el npm del sistema del usuario apuntando su cache
    # dentro de esta carpeta, y roto en cuanto se borrara.
    $savedPrefix = $env:NPM_CONFIG_PREFIX
    $savedCache  = $env:NPM_CONFIG_CACHE
    $env:NPM_CONFIG_PREFIX = $npmPrefix
    $env:NPM_CONFIG_CACHE  = $npmCache

    try {
        # npm escribe warnings en stderr de forma rutinaria: con
        # ErrorActionPreference = Stop eso abortaria el script.
        $run = Invoke-NativeCommand -FilePath $npmCmd -Arguments @('install', '-g', "@angular/cli@$Version")
    }
    finally {
        Restore-EnvVar -Name 'NPM_CONFIG_PREFIX' -Value $savedPrefix
        Restore-EnvVar -Name 'NPM_CONFIG_CACHE'  -Value $savedCache
    }

    if ($run.ExitCode -ne 0) {
        Write-Log "Error al instalar Angular CLI" "ERROR"
        Write-Log "  Si estas detras de un proxy, npm necesita su propia config:" "WARN"
        Write-Log "  npm config set proxy http://usuario:clave@proxy.empresa:8080" "WARN"
        Write-Log "  npm config set https-proxy http://usuario:clave@proxy.empresa:8080" "WARN"
        return $null
    }

    Write-Log "Angular CLI v$Version instalado" "SUCCESS"
    return (Join-Path $npmPrefix "ng.cmd")
}

function New-AngularProject {
    param(
        [string]$NgCmd,
        [string]$AngularPath,
        [string]$ProjectName
    )

    if ([string]::IsNullOrWhiteSpace($ProjectName)) {
        return
    }

    $projectsPath = Join-Path $AngularPath "projects"

    Write-Log "Creando proyecto '$ProjectName'..."

    # Push/Pop: 'ng new' crea en el directorio actual, pero no queremos dejar al
    # usuario en otra carpeta cuando termine el script.
    Push-Location $projectsPath
    try {
        $run = Invoke-NativeCommand -FilePath $NgCmd -Arguments @('new', $ProjectName, '--skip-install', '--defaults')
        if ($run.ExitCode -eq 0) {
            Write-Log "Proyecto creado: $projectsPath\$ProjectName" "SUCCESS"
            Write-Log "  Recuerda: se creo con --skip-install; ejecuta 'npm install' dentro." "WARN"
        }
        else {
            Write-Log "No se pudo crear el proyecto (codigo $($run.ExitCode))" "ERROR"
        }
    }
    finally {
        Pop-Location
    }
}

# Se separa lo pedido en linea y version exacta del CLI. Todo lo demas -carpeta,
# nombre del shell, que Node hace falta- va por la LINEA; la exacta solo decide
# que le pedimos a npm.
$pedidoNg       = Split-RuntimeVersionSpec -Clave angular -Spec $AngularVersion
$AngularExacta  = $pedidoNg.Exacta
$AngularVersion = [int]$pedidoNg.Linea

if ($AngularVersion -lt 14 -or $AngularVersion -gt 40) {
    Write-Log "Version de Angular fuera de rango: $AngularVersion (se admite de 14 a 40)" "ERROR"
    exit 1
}

Write-Log "========================================" "INFO"
Write-Log "  Angular Dev Environment Setup" "INFO"
Write-Log "  Version: $(if ($AngularExacta) { $AngularExacta } else { $AngularVersion })" "INFO"
Write-Log "========================================" "INFO"
Write-Log ""
Write-Log "Carpeta destino: $AngularRoot" "INFO"
Write-Log ""

# La version de Node no es fija: depende de lo que pida este Angular. Se resuelve
# antes de construir $EnvSetup porque el nombre de carpeta y las URLs dependen de ella.
#
# Los exit viven AQUI, en el cuerpo del script, y no dentro de las funciones:
# ellas explican que fallo y devuelven $null, y es este nivel el que decide que
# eso es fatal. Asi se pueden probar por separado y reutilizar desde otro script
# sin que se lleven por delante el proceso entero.
$resolvedNode = Resolve-NodeVersion -Version $AngularVersion -Forced $NodeVersion
if (-not $resolvedNode) { exit 1 }

Test-NodeSatisfiesAngular -NodeVer $resolvedNode -Version $AngularVersion
Write-Log ""

$nodeFolderName = "node-v$resolvedNode-win-x64"

$EnvSetup = @{
    AngularRoot       = $AngularRoot
    NodeVersion       = $resolvedNode
    NodeZipName       = "$nodeFolderName.zip"
    NodeFolderName    = $nodeFolderName
    NodeDownloadUrl   = "https://nodejs.org/dist/v$resolvedNode/$nodeFolderName.zip"
    NodeShasumsUrl    = "https://nodejs.org/dist/v$resolvedNode/SHASUMS256.txt"
    AngularVersion    = $AngularVersion
    AngularExacta     = $AngularExacta
    AngularFolderName = "angular-v$AngularVersion"
}

if ($WhatIf) {
    # Se imprime despues de resolver la Node por el registro de npm (solo
    # lectura): lo mas util de este plan es ver QUE Node se ha elegido y por que,
    # antes de bajar 30 MB y de que npm instale 292 paquetes.
    $destinoNode = Join-Path $EnvSetup.AngularRoot $EnvSetup.NodeFolderName
    $destinoAng  = Join-Path $EnvSetup.AngularRoot $EnvSetup.AngularFolderName

    Write-Host ""
    Write-Host "Se va a instalar:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host ("  [angular]  Angular CLI v{0}" -f $EnvSetup.AngularVersion)
    Write-Host ("  [node]     v{0}{1}" -f $EnvSetup.NodeVersion,
                 $(if ($NodeVersion) { "  (forzada con -NodeVersion)" } else { "  (resuelta segun lo que pide el CLI)" }))
    Write-Host ("  [descarga] {0}" -f $EnvSetup.NodeDownloadUrl) -ForegroundColor DarkGray
    Write-Host  "             + el CLI y sus dependencias desde registry.npmjs.org" -ForegroundColor DarkGray
    Write-Host ("  [carpeta]  {0}{1}" -f $destinoNode, $(if (Test-Path (Join-Path $destinoNode "node.exe")) { "   (ya existe: se reutiliza)" } else { "" }))
    Write-Host ("  [carpeta]  {0}" -f $destinoAng)
    Write-Host ("  [PATH]     {0}" -f $destinoNode)
    Write-Host  "             el CLI NO se publica en el PATH: solo dentro de su shell" -ForegroundColor DarkGray
    Write-Host ("  [shell]    shell-v{0}.bat" -f $EnvSetup.AngularVersion)
    if (-not [string]::IsNullOrWhiteSpace($NewProject)) {
        Write-Host ("  [proyecto] {0}" -f (Join-Path $destinoAng "projects\$NewProject"))
    }
    Write-Host ""
    Write-Host "-WhatIf: no se ha tocado nada." -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

$angularPath = Initialize-AngularDirectories -Version $EnvSetup.AngularVersion

$nodePath = Get-NodeJsPortable
if (-not $nodePath) { exit 1 }

Show-PathConflicts -Root $EnvSetup.AngularRoot -Keep $nodePath -Label "Angular"
Add-UserPathEntry -Path $nodePath

# A npm se le pide la version EXACTA si el lock la fijo; si no, la linea, que
# npm resuelve a su ultimo parche.
$ngCmd = Install-AngularCLI -AngularPath $angularPath -NodePath $nodePath `
             -Version $(if ($EnvSetup.AngularExacta) { $EnvSetup.AngularExacta } else { $EnvSetup.AngularVersion })
if (-not $ngCmd) { exit 1 }

Write-AngularShell -AngularPath $angularPath -NodePath $nodePath -Version $EnvSetup.AngularVersion -NodeVersion $EnvSetup.NodeVersion | Out-Null
Write-Log "Shell creado: $angularPath\shell-v$($EnvSetup.AngularVersion).bat" "SUCCESS"

New-AngularProject -NgCmd $ngCmd -AngularPath $angularPath -ProjectName $NewProject

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  CONFIGURACION COMPLETADA" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Estructura creada:" -ForegroundColor Yellow
Write-Host "  $($EnvSetup.AngularRoot)"
Write-Host "  +-- $($EnvSetup.NodeFolderName)\"
Write-Host "  +-- angular-v$($EnvSetup.AngularVersion)\"
Write-Host "      +-- npm-global\"
Write-Host "      +-- shell-v$($EnvSetup.AngularVersion).bat"
Write-Host "      +-- projects\"
Write-Host ""
Write-Host "Node.js v$($EnvSetup.NodeVersion) agregado al PATH." -ForegroundColor Green
Write-Host ""
Write-Host "Para comenzar:" -ForegroundColor Yellow
Write-Host "  Usa el shell: ..\Angular\angular-v$($EnvSetup.AngularVersion)\shell-v$($EnvSetup.AngularVersion).bat" -ForegroundColor White
Write-Host "  O copia el shell a tu escritorio para acceso rapido." -ForegroundColor Gray
Write-Host ""
