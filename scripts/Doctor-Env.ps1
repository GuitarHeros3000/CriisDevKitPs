#Requires -Version 5.1
<#
.SYNOPSIS
    Doctor-Env.ps1 - Diagnostico del entorno de desarrollo sin admin.
.DESCRIPTION
    Responde de un vistazo: que hay instalado, si el PATH esta sano, si se llega
    a internet (y por que proxy), y que herramientas opcionales faltan.
    Es lo primero que conviene ejecutar cuando algo falla o al llegar a un equipo
    nuevo. No modifica nada: solo lee.
.PARAMETER SkipNetwork
    Omite las pruebas de conectividad (util sin red o para ir mas rapido).
.PARAMETER Fix
    Repara lo que se pueda arreglar sin descargar nada: shells que faltan,
    ._pth sin parchear, entradas muertas o duplicadas del PATH y JAVA_HOME
    apuntando a una carpeta borrada. SIN este parametro, Doctor no toca nada.
.PARAMETER Force
    Con -Fix, no pide confirmacion.
.PARAMETER Report
    Ademas de mostrarlo, guarda el diagnostico en un archivo markdown listo para
    adjuntar a un ticket. La clave del proxy va enmascarada, como en pantalla.
.PARAMETER ReportPath
    Donde guardarlo. Por defecto, junto a los registros, en
    %LOCALAPPDATA%\AssassinSkipAdm\informes.
.EXAMPLE
    .\Doctor-Env.ps1
.EXAMPLE
    .\Doctor-Env.ps1 -Fix
.EXAMPLE
    .\Doctor-Env.ps1 -Report
.EXAMPLE
    .\Doctor-Env.ps1 -Report -ReportPath D:\ticket-4821.md
#>

param(
    [switch]$SkipNetwork,

    [switch]$Fix,

    [switch]$Force,

    [switch]$Report,

    [string]$ReportPath
)

$ProgressPreference = "SilentlyContinue"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

# Reparaciones que las comprobaciones van encontrando. Se ejecutan al final y
# solo con -Fix: por defecto Doctor sigue siendo de solo lectura.
$script:Fixes = @()

function Add-Fix {
    <#
        Registra algo reparable. Solo se apunta lo que se puede arreglar EN LOCAL:
        nada que necesite descargar, porque Doctor debe servir igual en una
        maquina sin red.

        Los datos van en -Arguments y el bloque los recibe como parametros. NO se
        usa .GetNewClosure() para capturarlos: eso mete el bloque en un ambito de
        modulo nuevo que NO ve las funciones que Common.ps1 trajo por
        dot-sourcing, y la reparacion falla con "no se reconoce el termino".
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Description,
        [Parameter(Mandatory=$true)][scriptblock]$Action,
        [hashtable]$Arguments = @{}
    )
    $script:Fixes += [PSCustomObject]@{
        Description = $Description
        Action      = $Action
        Arguments   = $Arguments
    }
}

$AngularRoot = Join-Path $WorkspaceRoot "Angular"
$PythonRoot  = Join-Path $WorkspaceRoot "Python"
$JavaRoot    = Join-Path $WorkspaceRoot "Java"
$NodeRoot    = Join-Path $WorkspaceRoot "Node"
$GitRoot     = Join-Path $WorkspaceRoot "Git"
$MavenRoot   = Join-Path $WorkspaceRoot "Maven"
$GradleRoot  = Join-Path $WorkspaceRoot "Gradle"
$DotnetRoot  = Join-Path $WorkspaceRoot "Dotnet"
$VSCodeRoot  = Join-Path $WorkspaceRoot "VSCode"
$AppsRoot    = Join-Path $WorkspaceRoot "Apps"

# Contadores para el resumen final.
$script:Problems = 0
$script:Warnings = 0

# Lineas del informe. Se acumulan siempre (cuesta nada) y solo se escriben con
# -Report. Se engancha aqui, en las tres funciones de salida, y no con un
# transcript como el registro: alli hacia falta capturar TODO, aqui se quiere
# markdown estructurado, no un volcado de consola.
$script:ReportLines = @()

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "-- $Title " -ForegroundColor Cyan -NoNewline
    Write-Host ("-" * [Math]::Max(0, 58 - $Title.Length)) -ForegroundColor DarkGray

    $script:ReportLines += ""
    $script:ReportLines += "## $Title"
    $script:ReportLines += ""
}

function Write-Check {
    param(
        [string]$Label,
        [string]$Value,
        [ValidateSet('ok', 'warn', 'fail', 'info')]
        [string]$State = 'info'
    )

    $mark, $color = switch ($State) {
        'ok'   { '[ok]  ', 'Green' }
        'warn' { '[!]   ', 'Yellow' }
        'fail' { '[X]   ', 'Red' }
        default { '      ', 'Gray' }
    }

    if ($State -eq 'fail') { $script:Problems++ }
    if ($State -eq 'warn') { $script:Warnings++ }

    Write-Host $mark -ForegroundColor $color -NoNewline
    Write-Host ("{0,-26}" -f $Label) -NoNewline
    Write-Host $Value -ForegroundColor $color

    # Solo ASCII: PowerShell 5.1 lee los .ps1 como ANSI si no llevan BOM, asi que
    # un guion largo o una tilde aqui corrompen el archivo y rompen el parser.
    $icono = switch ($State) { 'ok' { '`[ok]`' } 'warn' { '`[!]`' } 'fail' { '`[X]`' } default { '`[--]`' } }
    $script:ReportLines += "- $icono **$Label** : $Value"
}

function Write-Detail {
    param([string]$Text)
    Write-Host "        $Text" -ForegroundColor DarkGray

    # Sangrado para que cuelgue del check anterior al renderizar el markdown.
    $script:ReportLines += "  - $Text"
}

function Invoke-VersionProbe {
    <#
        Ejecuta un binario para leer su version. Devuelve $null si no arranca:
        un Doctor que revienta con el primer ejecutable corrupto no diagnostica
        nada, y justo ese caso (descarga a medias) es el que hay que detectar.
    #>
    param(
        [string]$Exe,
        [string[]]$Arguments = @('--version')
    )

    try {
        $out = & $Exe @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) { return $null }
        $text = ($out | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }

        $first = ($text -split "`n")[0].Trim()

        # Lo que un .exe escribe en stderr llega envuelto en un ErrorRecord cuyo
        # texto empieza por "<programa> : ". Pasa con "java -version", que usa
        # stderr por decision historica de sus autores.
        $leaf = Split-Path -Leaf $Exe
        if ($first.StartsWith("$leaf : ")) {
            $first = $first.Substring("$leaf : ".Length).Trim()
        }

        return $first
    }
    catch {
        return $null
    }
}

# --------------------------------------------------------------------------

function Test-Host {
    Write-Section "Sistema"

    Write-Check "PowerShell" "$($PSVersionTable.PSVersion)" 'ok'
    Write-Check "Windows" "$([Environment]::OSVersion.Version)" 'info'
    Write-Check "Arquitectura" "$env:PROCESSOR_ARCHITECTURE" 'info'
    Write-Check "Usuario" "$env:USERNAME" 'info'

    # ExecutionPolicy persistida. OJO: no se usa Get-ExecutionPolicy a secas
    # porque los .bat del kit lanzan con -ExecutionPolicy Bypass y eso solo
    # afecta a ESE proceso. Lo que decide si el perfil de PowerShell se carga en
    # una terminal normal son los ambitos guardados, y el de politica de grupo
    # gana sobre los demas.
    $scopes = @('MachinePolicy', 'UserPolicy', 'CurrentUser', 'LocalMachine')
    $effective = 'Restricted'
    $source = 'por defecto'
    foreach ($s in $scopes) {
        $v = (Get-ExecutionPolicy -Scope $s -ErrorAction SilentlyContinue)
        if ($v -and $v -ne 'Undefined') { $effective = $v; $source = $s; break }
    }

    if ($effective -in @('Restricted', 'AllSigned')) {
        Write-Check "ExecutionPolicy" "$effective ($source)" 'warn'
        Write-Detail "Con esta politica, el perfil de PowerShell no se ejecuta, asi que"
        Write-Detail "Use-Env no podria enganchar PowerShell (el de cmd.exe si)."
        if ($source -in @('MachinePolicy', 'UserPolicy')) {
            Write-Detail "Viene de politica de grupo: no se puede cambiar sin IT."
        }
        else {
            Write-Detail "Se puede cambiar sin admin:"
            Write-Detail "  Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned"
        }
    }
    else {
        Write-Check "ExecutionPolicy" "$effective ($source)" 'ok'
    }

    # Los scripts asumen que se puede escribir junto al kit.
    $probe = Join-Path $WorkspaceRoot ".doctor-write-test"
    try {
        Set-Content -LiteralPath $probe -Value "x" -ErrorAction Stop
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        Write-Check "Escritura en workspace" "OK" 'ok'
    }
    catch {
        Write-Check "Escritura en workspace" "SIN PERMISO" 'fail'
        Write-Detail $WorkspaceRoot
    }

    try {
        $drive = (Get-Item $WorkspaceRoot).PSDrive
        $freeGb = [Math]::Round($drive.Free / 1GB, 1)
        # Node + Angular CLI + un proyecto rondan los 2 GB.
        $state = if ($freeGb -lt 2) { 'fail' } elseif ($freeGb -lt 5) { 'warn' } else { 'ok' }
        Write-Check "Espacio libre" "$freeGb GB en $($drive.Name):" $state
        if ($state -ne 'ok') { Write-Detail "Node + Angular CLI + un proyecto ocupan ~2 GB." }
    }
    catch {
        Write-Check "Espacio libre" "no se pudo calcular" 'warn'
    }
}

function Test-Network {
    Write-Section "Red"

    # Las reglas de espejo se anuncian SIEMPRE, incluso con -SkipNetwork: no son
    # una prueba de red sino configuracion, y de donde descarga el kit no puede
    # quedar invisible en un informe. Ademas cambian como se lee todo lo demas
    # de esta seccion.
    $reglas = @(Get-SourceRules)
    if ($reglas.Count -gt 0) {
        Write-Check "Fuentes" "$($reglas.Count) regla(s) de espejo activas" 'warn'
        foreach ($r in $reglas) { Write-Detail "$($r.De)  ->  $($r.A)" }
        Write-Detail "Definidas en $SourcesFile"
        Write-Detail "El checksum tambien viene del espejo: se confia en el como en el proxy."
    }
    else {
        Write-Check "Fuentes" "oficiales (sin sources.json)" 'ok'
    }

    if ($SkipNetwork) {
        Write-Check "Pruebas de red" "omitidas (-SkipNetwork)" 'info'
        return
    }

    $proxy = Resolve-DownloadProxy -Uri ([Uri]"https://nodejs.org")
    if ($proxy) {
        Write-Check "Proxy" (Format-ProxyForDisplay $proxy) 'info'
        $fromEnv = $env:HTTPS_PROXY, $env:HTTP_PROXY, $env:ALL_PROXY | Where-Object { $_ }
        Write-Detail $(if ($fromEnv) { "origen: variable de entorno" } else { "origen: configuracion del sistema" })
    }
    else {
        Write-Check "Proxy" "ninguno (salida directa)" 'info'
    }

    Write-Check "TLS negociable" "$([Net.ServicePointManager]::SecurityProtocol)" 'ok'

    # Los dominios de los que depende el kit. Los binarios de Adoptium se sirven
    # desde GitHub, asi que se comprueba aparte de su API: son dos permisos
    # distintos en un cortafuegos corporativo.
    $targets = @(
        @{ Name = "nodejs.org";          Url = "https://nodejs.org/dist/index.json" }
        @{ Name = "registry.npmjs.org";  Url = "https://registry.npmjs.org/@angular%2fcli" }
        @{ Name = "python.org";          Url = "https://www.python.org/ftp/python/" }
        @{ Name = "pypi.org";            Url = "https://pypi.org/simple/" }
        @{ Name = "api.adoptium.net";    Url = "https://api.adoptium.net/v3/info/available_releases" }
        @{ Name = "github.com (JDK)";    Url = "https://github.com/adoptium" }
    )

    foreach ($t in $targets) {
        # Se comprueba la URL por la que el kit saldria de verdad. Con un espejo
        # configurado, decir que nodejs.org es alcanzable no significaria nada:
        # el kit no va a ir ahi.
        $t.Url = Resolve-KitUrl -Uri $t.Url -Quiet

        $params = @{
            Uri             = $t.Url
            UseBasicParsing = $true
            TimeoutSec      = 25
            Method          = 'Head'
        }
        # Add-ProxyToRequest y no las dos lineas de siempre: si el proxy lleva
        # usuario y clave en la URL hay que enviarlos aparte. Poniendo la URL
        # entera en -Proxy se descartan, el proxy responde 407 a todo, y este
        # diagnostico acusaba al cortafuegos de bloquear los seis dominios.
        Add-ProxyToRequest -Params $params -Uri ([Uri]$t.Url)

        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            Invoke-WebRequest @params | Out-Null
            $sw.Stop()
            Write-Check $t.Name "alcanzable ($($sw.ElapsedMilliseconds) ms)" 'ok'
        }
        catch {
            $sw.Stop()
            Write-Check $t.Name "NO alcanzable" 'fail'
            $hint = Get-DownloadErrorHint -ErrorRecord $_
            if ($hint) { Write-Detail $hint }
            else { Write-Detail (Get-WebErrorText -ErrorRecord $_) }
        }
    }
}

function Test-AngularInstall {
    Write-Section "Angular"

    if (-not (Test-Path $AngularRoot)) {
        Write-Check "Instalado" "no ($AngularRoot no existe)" 'info'
        Write-Detail "Instala con:  .\Setup-AngularEnv.bat -AngularVersion 20"
        return
    }

    $nodes = @(Get-ChildItem $AngularRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^node-v(.+)-win-x64$' })

    if ($nodes.Count -eq 0) {
        Write-Check "Node.js" "ninguno en $AngularRoot" 'fail'
    }
    foreach ($n in $nodes) {
        $exe = Join-Path $n.FullName "node.exe"
        if (-not (Test-Path $exe)) {
            Write-Check "Node.js" "carpeta sin node.exe: $($n.Name)" 'fail'
            continue
        }

        $ver = Invoke-VersionProbe -Exe $exe
        if ($ver) {
            Write-Check "Node.js" "$ver  ($($n.Name))" 'ok'
        }
        else {
            Write-Check "Node.js" "node.exe no arranca ($($n.Name))" 'fail'
            Write-Detail "Instalacion corrupta; borra la carpeta y reejecuta el setup."
        }
    }

    $versions = @(Get-ChildItem $AngularRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^angular-v(\d+)$' })

    if ($versions.Count -eq 0) {
        Write-Check "Angular CLI" "ninguno instalado" 'info'
        return
    }

    foreach ($v in ($versions | Sort-Object { [int]($_.Name -replace 'angular-v', '') })) {
        $num   = $v.Name -replace 'angular-v', ''
        $ngCmd = Join-Path $v.FullName "npm-global\ng.cmd"
        $shell = Join-Path $v.FullName "shell-v$num.bat"

        if (Test-Path $ngCmd) {
            Write-Check "Angular v$num" "instalado" 'ok'
        }
        else {
            Write-Check "Angular v$num" "falta ng.cmd en npm-global" 'fail'
            Write-Detail "Reejecuta:  .\Setup-AngularEnv.bat -AngularVersion $num"
        }

        if (-not (Test-Path $shell)) {
            Write-Check "  shell-v$num.bat" "falta" 'warn'

            # El Node con el que se instalo esta en el nombre de su carpeta; si
            # hay varias, se usa la unica que quede o se deja sin reparar.
            $nodeDirs = @(Get-ChildItem $AngularRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^node-v(.+)-win-x64$' })
            if ($nodeDirs.Count -eq 1) {
                $nodePath = $nodeDirs[0].FullName
                $nodeVer  = $nodeDirs[0].Name -replace '^node-v|-win-x64$', ''
                Add-Fix -Description "regenerar shell-v$num.bat de Angular" `
                        -Arguments @{ AngularPath = $v.FullName; NodePath = $nodePath; Version = $num; NodeVersion = $nodeVer } `
                        -Action {
                    param($AngularPath, $NodePath, $Version, $NodeVersion)
                    Write-AngularShell -AngularPath $AngularPath -NodePath $NodePath -Version $Version -NodeVersion $NodeVersion | Out-Null
                }
            }
            else {
                Write-Detail "hay $($nodeDirs.Count) versiones de Node: no se puede deducir cual usaba"
                Write-Detail "reejecuta:  .\Setup-AngularEnv.bat -AngularVersion $num"
            }
        }
    }
}

function Test-PythonInstall {
    Write-Section "Python"

    if (-not (Test-Path $PythonRoot)) {
        Write-Check "Instalado" "no ($PythonRoot no existe)" 'info'
        Write-Detail "Instala con:  .\Setup-PythonEnv.bat -PythonVersion 3.12"
        return
    }

    $versions = @(Get-ChildItem $PythonRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^python-\d+\.\d+$' })

    if ($versions.Count -eq 0) {
        Write-Check "Instalado" "ninguna version en $PythonRoot" 'info'
        return
    }

    foreach ($v in $versions) {
        $num = $v.Name -replace 'python-', ''
        $exe = Join-Path $v.FullName "python.exe"

        if (-not (Test-Path $exe)) {
            Write-Check "Python v$num" "falta python.exe" 'fail'
            continue
        }

        $tag = $num -replace '\.', ''

        $ver = Invoke-VersionProbe -Exe $exe
        $exeOk = [bool]$ver
        if ($exeOk) {
            Write-Check "Python v$num" "$ver" 'ok'
        }
        else {
            Write-Check "Python v$num" "python.exe no arranca" 'fail'
            Write-Detail "Instalacion corrupta; borra la carpeta y reejecuta el setup."
        }

        # SHA-256 del zip con que se instalo. Es trazabilidad, no verificacion:
        # sirve para comparar dos maquinas que dicen tener la misma version.
        # python.org no publica hashes con los que contrastarlo.
        $shaFile = Join-Path $v.FullName ".assassinskipadm-sha256"
        if (Test-Path $shaFile) {
            Write-Check "  SHA-256 del zip" (Get-Content -LiteralPath $shaFile -Raw).Trim() 'info'
        }

        # Las comprobaciones de fichero valen aunque el binario este roto: dicen
        # si ademas hay que rehacer la configuracion, no solo la descarga.
        $pth = Join-Path $v.FullName "python$tag._pth"
        if (Test-Path $pth) {
            $content = Get-Content $pth -Raw
            $siteOk = $content -match '(?m)^\s*import site\s*$'
            $pkgOk  = $content -match '(?m)^\s*Lib\\site-packages\s*$'
            if ($siteOk -and $pkgOk) {
                Write-Check "  ._pth" "configurado" 'ok'
            }
            else {
                Write-Check "  ._pth" "sin parchear (pip no importara)" 'fail'
                Add-Fix -Description "parchear python$tag._pth (site + site-packages)" `
                        -Arguments @{ PthFile = $pth } -Action {
                    param($PthFile)
                    $l = Get-Content $PthFile
                    $l = $l | ForEach-Object { $_ -replace '^\s*#\s*import site\s*$', 'import site' }
                    if ($l -notcontains 'Lib\site-packages') { $l += 'Lib\site-packages' }
                    if ($l -notcontains 'import site') { $l += 'import site' }
                    Set-Content -Path $PthFile -Value $l -Encoding ASCII
                }
            }
        }
        else {
            Write-Check "  ._pth" "no encontrado" 'warn'
        }

        $shell = Join-Path $v.FullName "py$tag-shell.bat"
        if (-not (Test-Path $shell)) {
            Write-Check "  py$tag-shell.bat" "falta" 'warn'
            Add-Fix -Description "regenerar py$tag-shell.bat" `
                    -Arguments @{ PythonPath = $v.FullName; Version = $num } -Action {
                param($PythonPath, $Version)
                Write-PythonShell -PythonPath $PythonPath -Version $Version | Out-Null
            }
        }

        # pip solo tiene sentido probarlo si el interprete arranca.
        if ($exeOk) {
            $pipVer = Invoke-VersionProbe -Exe $exe -Arguments @('-m', 'pip', '--version')
            if ($pipVer) {
                Write-Check "  pip" $pipVer 'ok'
            }
            else {
                Write-Check "  pip" "no responde" 'fail'
            }
        }
    }
}

function Test-JavaInstall {
    Write-Section "Java"

    if (-not (Test-Path $JavaRoot)) {
        Write-Check "Instalado" "no ($JavaRoot no existe)" 'info'
        Write-Detail "Instala con:  .\Setup-JavaEnv.bat -JavaVersion 21"
        return
    }

    $versions = @(Get-ChildItem $JavaRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^jdk-(\d+)$' })

    if ($versions.Count -eq 0) {
        Write-Check "Instalado" "ninguna version en $JavaRoot" 'info'
        return
    }

    foreach ($v in ($versions | Sort-Object { [int]($_.Name -replace 'jdk-', '') })) {
        $num = $v.Name -replace 'jdk-', ''
        $exe = Join-Path $v.FullName "bin\java.exe"

        if (-not (Test-Path $exe)) {
            Write-Check "JDK $num" "falta bin\java.exe" 'fail'
            continue
        }

        # java -version escribe en stderr, de ahi que se lea la salida completa.
        $ver = Invoke-VersionProbe -Exe $exe -Arguments @('-version')
        if ($ver) {
            Write-Check "JDK $num" $ver 'ok'
        }
        else {
            Write-Check "JDK $num" "java.exe no arranca" 'fail'
            Write-Detail "Instalacion corrupta; reinstala con -JavaVersion $num -Force"
        }

        $shell = Join-Path $v.FullName "java$num-shell.bat"
        if (-not (Test-Path $shell)) {
            Write-Check "  java$num-shell.bat" "falta" 'warn'
            $rel = $null
            $mk = Join-Path $v.FullName ".assassinskipadm-release"
            if (Test-Path $mk) { $rel = (Get-Content $mk -Raw).Trim() }
            Add-Fix -Description "regenerar java$num-shell.bat" `
                    -Arguments @{ JdkPath = $v.FullName; Major = $num; Release = $rel } -Action {
                param($JdkPath, $Major, $Release)
                Write-JavaShell -JdkPath $JdkPath -Major $Major -Release $Release | Out-Null
            }
        }
    }

    # JAVA_HOME decide con que JDK compilan Maven, Gradle y los IDE, asi que
    # importa mas que el PATH y conviene decir cual manda y de donde sale.
    $userHome    = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'User')
    $machineHome = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'Machine')

    if ($userHome) {
        $exists = Test-Path -LiteralPath $userHome
        Write-Check "JAVA_HOME (usuario)" $userHome $(if ($exists) { 'ok' } else { 'fail' })
        if (-not $exists) {
            Write-Detail "La carpeta no existe: Maven y Gradle fallarian."
            Add-Fix -Description "retirar JAVA_HOME de usuario (apunta a una carpeta borrada)" -Action {
                [Environment]::SetEnvironmentVariable('JAVA_HOME', $null, 'User')
            }
        }
        if ($machineHome) { Write-Detail "tapa al de maquina: $machineHome" }
    }
    elseif ($machineHome) {
        Write-Check "JAVA_HOME (maquina)" $machineHome 'info'
        Write-Detail "Para que Maven/Gradle usen el JDK del kit:  -SetJavaHome"
    }
    else {
        Write-Check "JAVA_HOME" "sin definir" 'info'
    }
}

function Test-NodeInstall {
    <#
        La Node SUELTA, la que instala Setup-NodeEnv en Node\. La que vive dentro
        de Angular\ se reporta en la seccion de Angular: son independientes y
        conviene verlas por separado para no creer que sobra una.
    #>
    Write-Section "Node (suelto)"

    $nodeRoot = Join-Path $WorkspaceRoot "Node"
    if (-not (Test-Path $nodeRoot)) {
        Write-Check "Instalado" "no ($nodeRoot no existe)" 'info'
        Write-Detail "Instala con:  .\Setup-NodeEnv.bat"
        return
    }

    $dirs = @(Get-ChildItem $nodeRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^node-(\d+)$' })

    if ($dirs.Count -eq 0) {
        Write-Check "Instalado" "ninguna version en $nodeRoot" 'info'
        return
    }

    foreach ($d in $dirs) {
        $null = $d.Name -match '^node-(\d+)$'
        $major = $Matches[1]
        $exe = Join-Path $d.FullName "node.exe"

        if (-not (Test-Path $exe)) {
            Write-Check "Node $($d.Name)" "falta node.exe" 'fail'
            Write-Detail "Instalacion corrupta; reejecuta .\Setup-NodeEnv.bat"
            continue
        }

        $ver = Invoke-VersionProbe -Exe $exe
        if ($ver) { Write-Check "Node v$major" $ver 'ok' }
        else      { Write-Check "Node v$major" "node.exe no arranca" 'fail' }

        $shell = Join-Path $d.FullName "node$major-shell.bat"
        if (-not (Test-Path $shell)) {
            Write-Check "  node$major-shell.bat" "falta" 'warn'
            Add-Fix -Description "regenerar node$major-shell.bat" `
                    -Arguments @{ Path = $d.FullName; Version = $ver } `
                    -Action {
                        param($Path, $Version)
                        Write-NodeShell -NodePath $Path -Version ($Version -replace '^v','') | Out-Null
                    }
        }
    }
}

function Test-GitInstall {
    <#
        Git portable, el que instala Setup-GitEnv en Git\. No se comprueba
        contra el "git" del PATH a secas: si hay uno de maquina instalado por
        IT, el del kit puede estar tapado, y eso lo dice la seccion de
        conflictos de PATH, no esta.
    #>
    Write-Section "Git (portable)"

    if (-not (Test-Path $GitRoot)) {
        Write-Check "Instalado" "no ($GitRoot no existe)" 'info'
        Write-Detail "Instala con:  .\Setup-GitEnv.bat"
        return
    }

    $dirs = @(Get-ChildItem $GitRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^git-(\d+\.\d+)$' })

    if ($dirs.Count -eq 0) {
        Write-Check "Instalado" "ninguna version en $GitRoot" 'info'
        return
    }

    foreach ($d in $dirs) {
        $null = $d.Name -match '^git-(\d+\.\d+)$'
        $linea = $Matches[1]
        $exe = Join-Path $d.FullName "cmd\git.exe"

        if (-not (Test-Path $exe)) {
            Write-Check "Git $($d.Name)" "falta cmd\git.exe" 'fail'
            Write-Detail "Instalacion corrupta; reejecuta .\Setup-GitEnv.bat -Force"
            continue
        }

        $ver = Invoke-VersionProbe -Exe $exe
        if ($ver) { Write-Check "Git $linea" $ver 'ok' }
        else      { Write-Check "Git $linea" "git.exe no arranca" 'fail' }

        # Git Bash es la mitad del valor de PortableGit; si falta, la
        # instalacion sirve pero esta coja.
        if (-not (Test-Path (Join-Path $d.FullName "git-bash.exe"))) {
            Write-Check "  git-bash.exe" "falta" 'warn'
            Write-Detail "Reinstala con:  .\Setup-GitEnv.bat -Force"
        }

        # Si post-install.bat sigue ahi es que no llego a ejecutarse: git
        # funciona, pero el entorno de Git Bash quedo a medias.
        if (Test-Path (Join-Path $d.FullName "post-install.bat")) {
            Write-Check "  post-instalacion" "sin completar" 'warn'
            Write-Detail "Git funciona, pero Git Bash puede ir justo. Reinstala con -Force."
        }

        $shell = Join-Path $d.FullName ("git$($linea -replace '\.','')-shell.bat")
        if (-not (Test-Path $shell)) {
            Write-Check "  $(Split-Path -Leaf $shell)" "falta" 'warn'
            Add-Fix -Description "regenerar $(Split-Path -Leaf $shell)" `
                    -Arguments @{ Path = $d.FullName; Version = $ver } `
                    -Action {
                        param($Path, $Version)
                        $v = ($Version -replace '^git version ', '') -replace '\.windows\.', '.'
                        Write-GitShell -GitPath $Path -Version $v | Out-Null
                    }
        }
    }
}

function Test-BuildToolInstall {
    <#
        Maven y Gradle se comprueban igual: una carpeta por linea, un ejecutable
        en bin\, un shell generado, y la version leida de un jar en vez de
        ejecutando la herramienta -las dos necesitan JAVA_HOME y ninguna arranca
        rapido-. Por eso es una sola funcion con parametros y no dos copias.
    #>
    param(
        [string]$Titulo,
        [string]$Root,
        [string]$Prefijo,        # 'maven'  /  'gradle'
        [string]$ExeRel,         # 'bin\mvn.cmd'
        [string]$ShellPrefijo,   # 'mvn'  /  'gradle'
        [string]$JarGlob,        # 'lib\maven-core-*.jar'
        [string]$JarRegex,
        [string]$SetupBat
    )

    Write-Section $Titulo

    if (-not (Test-Path $Root)) {
        Write-Check "Instalado" "no ($Root no existe)" 'info'
        Write-Detail "Instala con:  $SetupBat"
        return
    }

    $dirs = @(Get-ChildItem $Root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "^$Prefijo-(\d+\.\d+)$" })

    if ($dirs.Count -eq 0) {
        Write-Check "Instalado" "ninguna version en $Root" 'info'
        return
    }

    foreach ($d in $dirs) {
        $null = $d.Name -match "^$Prefijo-(\d+\.\d+)$"
        $linea = $Matches[1]

        if (-not (Test-Path (Join-Path $d.FullName $ExeRel))) {
            Write-Check "$Titulo $($d.Name)" "falta $ExeRel" 'fail'
            Write-Detail "Instalacion corrupta; reejecuta $SetupBat -Force"
            continue
        }

        $ver = $linea
        $jar = @(Get-ChildItem -Path (Join-Path $d.FullName $JarGlob) -ErrorAction SilentlyContinue)
        if ($jar.Count -gt 0 -and $jar[0].Name -match $JarRegex) { $ver = $Matches[1] }
        Write-Check "$Titulo $linea" $ver 'ok'

        $shell = Join-Path $d.FullName "$ShellPrefijo$($linea -replace '\.','')-shell.bat"
        if (-not (Test-Path $shell)) {
            Write-Check "  $(Split-Path -Leaf $shell)" "falta" 'warn'
            Write-Detail "Regeneralo con:  $SetupBat -Force"
        }
        elseif (-not ((Get-Content -LiteralPath $shell -Raw) -match 'JAVA_HOME')) {
            # El shell se genero cuando no habia ningun JDK del kit. La
            # herramienta esta bien, pero no arrancara.
            Write-Check "  JAVA_HOME en el shell" "sin definir" 'warn'
            Write-Detail "Se genero sin JDK del kit. Instala uno y reejecuta $SetupBat -Force"
        }
    }
}

function Test-DotnetInstall {
    Write-Section ".NET SDK"

    if (-not (Test-Path $DotnetRoot)) {
        Write-Check "Instalado" "no ($DotnetRoot no existe)" 'info'
        Write-Detail "Instala con:  .\Setup-DotnetEnv.bat"
        return
    }

    $dirs = @(Get-ChildItem $DotnetRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^dotnet-(\d+\.\d+)$' })
    if ($dirs.Count -eq 0) {
        Write-Check "Instalado" "ninguna version en $DotnetRoot" 'info'
        return
    }

    foreach ($d in $dirs) {
        $null = $d.Name -match '^dotnet-(\d+\.\d+)$'
        $canal = $Matches[1]

        if (-not (Test-Path (Join-Path $d.FullName "dotnet.exe"))) {
            Write-Check ".NET $($d.Name)" "falta dotnet.exe" 'fail'
            Write-Detail "Instalacion corrupta; reejecuta .\Setup-DotnetEnv.bat -Force"
            continue
        }

        # De la carpeta sdk\ y no ejecutando dotnet: es mas rapido y no depende
        # de que variables de entorno haya puestas.
        $sdks = @(Get-ChildItem -LiteralPath (Join-Path $d.FullName "sdk") -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -match '^\d+\.\d+\.\d+' })
        if ($sdks.Count -gt 0) {
            Write-Check ".NET $canal" (@($sdks | Sort-Object Name -Descending)[0].Name) 'ok'
        }
        else {
            Write-Check ".NET $canal" "hay dotnet.exe pero ningun SDK en sdk\" 'fail'
        }

        $shell = Join-Path $d.FullName "dotnet$($canal -replace '\.','')-shell.bat"
        if (-not (Test-Path $shell)) {
            Write-Check "  $(Split-Path -Leaf $shell)" "falta" 'warn'
            Write-Detail "Regeneralo con:  .\Setup-DotnetEnv.bat -Channel $canal -Force"
        }
    }
}

function Test-VSCodeInstall {
    Write-Section "VS Code (portable)"

    if (-not (Test-Path $VSCodeRoot)) {
        Write-Check "Instalado" "no ($VSCodeRoot no existe)" 'info'
        Write-Detail "Instala con:  .\Setup-VSCodeEnv.bat"
        return
    }

    $dirs = @(Get-ChildItem $VSCodeRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^vscode-(\d+\.\d+)$' })
    if ($dirs.Count -eq 0) {
        Write-Check "Instalado" "ninguna version en $VSCodeRoot" 'info'
        return
    }

    foreach ($d in $dirs) {
        $null = $d.Name -match '^vscode-(\d+\.\d+)$'
        $linea = $Matches[1]
        $exe = Join-Path $d.FullName "Code.exe"

        if (-not (Test-Path $exe)) {
            Write-Check "VS Code $($d.Name)" "falta Code.exe" 'fail'
            Write-Detail "Instalacion corrupta; reejecuta .\Setup-VSCodeEnv.bat -Force"
            continue
        }

        $v = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
        Write-Check "VS Code $linea" $v 'ok'

        # Sin data\ deja de ser portable EN SILENCIO: escribiria los ajustes y
        # las extensiones en el perfil, mezclandose con los de otro VS Code que
        # hubiera instalado. Es el fallo mas facil de no notar aqui.
        $data = Join-Path $d.FullName "data"
        if (-not (Test-Path -LiteralPath $data)) {
            Write-Check "  modo portable" "NO activo: falta data\" 'fail'
            Write-Detail "Escribira en tu perfil en vez de en su carpeta."
            Add-Fix -Description "activar el modo portable (crear data\)" `
                    -Arguments @{ Path = $d.FullName } `
                    -Action {
                        param($Path)
                        New-Item -ItemType Directory -Path (Join-Path $Path "data") -Force | Out-Null
                    }
        }
        else {
            $ext = @(Get-ChildItem -LiteralPath (Join-Path $data "extensions") -Directory -ErrorAction SilentlyContinue)
            Write-Check "  modo portable" "activo ($($ext.Count) extension(es) en data\)" 'ok'
        }

        $shell = Join-Path $d.FullName "code$($linea -replace '\.','')-shell.bat"
        if (-not (Test-Path $shell)) {
            Write-Check "  $(Split-Path -Leaf $shell)" "falta" 'warn'
            Write-Detail "Regeneralo con:  .\Setup-VSCodeEnv.bat -Force -KeepData"
        }
    }
}

function Test-PortableApps {
    Write-Section "Install-NoAdmin"

    # Sin estas dos, el fallback portable de NSIS e Inno no puede funcionar.
    # Find-KitTool mira el PATH y ademas Apps\tools, que es donde deja las suyas
    # Install-NoAdmin. Antes solo se miraba el PATH, asi que aunque el kit ya las
    # hubiera descargado, Doctor seguia avisando de que faltaban.
    $sevenZip = Find-KitTool -FileName '7z.exe'
    if ($sevenZip) {
        Write-Check "7z.exe (NSIS)" $sevenZip 'ok'
    }
    else {
        # Ya no es un aviso: Install-NoAdmin la descarga sola cuando la necesita.
        Write-Check "7z.exe (NSIS)" "no esta; se descargara al hacer falta" 'info'
    }

    # Se acepta cualquiera de los dos. innounp era el historico; innoextract es
    # el equivalente moderno y el que el kit sabe descargar.
    $inno = Find-KitTool -FileName 'innounp.exe'
    $innoTipo = 'innounp.exe'
    if (-not $inno) {
        $inno = Find-KitTool -FileName 'innoextract.exe'
        $innoTipo = 'innoextract.exe'
    }
    if ($inno) {
        Write-Check "$innoTipo (Inno)" $inno 'ok'
    }
    else {
        Write-Check "Extractor Inno Setup" "no esta; se descargara al hacer falta" 'info'
    }

    if (Test-Path $AppsRoot) {
        $apps = @(Get-ChildItem $AppsRoot -Directory -ErrorAction SilentlyContinue)
        Write-Check "Apps portables" "$($apps.Count) en $AppsRoot" 'info'
        foreach ($a in $apps) { Write-Detail $a.Name }
    }
    else {
        Write-Check "Apps portables" "ninguna todavia" 'info'
    }
}

function Test-UserPath {
    Write-Section "PATH de usuario"

    $raw = Get-RawUserPath
    $entries = @($raw -split ';' | Where-Object { $_.Trim() -ne '' })

    Write-Check "Entradas" "$($entries.Count)" 'info'

    # Longitud: por encima de ~2000 caracteres, algunas herramientas antiguas
    # y el editor grafico de variables empiezan a truncar.
    $state = if ($raw.Length -gt 2000) { 'warn' } else { 'ok' }
    Write-Check "Longitud" "$($raw.Length) caracteres" $state

    $dups = @($entries | Group-Object { $_.TrimEnd('\').ToLowerInvariant() } |
        Where-Object { $_.Count -gt 1 })
    if ($dups.Count -gt 0) {
        Write-Check "Duplicados" "$($dups.Count)" 'warn'
        foreach ($d in $dups) { Write-Detail "$($d.Name)  (x$($d.Count))" }

        Add-Fix -Description "quitar $($dups.Count) entrada(s) duplicada(s) del PATH" -Action {
            $cur = Get-RawUserPath
            $seen = @{}
            $kept = @()
            foreach ($e in (Split-UserPath -Value $cur)) {
                $k = $e.TrimEnd('\').ToLowerInvariant()
                if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $kept += $e }
            }
            Save-UserPath -Previous $cur -Updated ($kept -join ';') | Out-Null
        }
    }
    else {
        Write-Check "Duplicados" "ninguno" 'ok'
    }

    # Entradas que apuntan a carpetas borradas: rastro de instalaciones viejas.
    $broken = @($entries | Where-Object {
        $expanded = [Environment]::ExpandEnvironmentVariables($_)
        -not (Test-Path -LiteralPath $expanded)
    })
    if ($broken.Count -gt 0) {
        Write-Check "Rutas inexistentes" "$($broken.Count)" 'warn'

        # Solo se ofrecen para borrar las que cuelgan de las carpetas del kit.
        # Una ruta muerta ajena puede ser una unidad de red o un USB desconectado
        # ahora mismo: borrarla seria destruir algo que el usuario si quiere.
        # OJO al anadir un runtime nuevo: si su carpeta raiz no esta en esta lista,
        # Doctor no reconocera sus rutas muertas como propias y las dejara para
        # siempre marcadas como "ajena". Paso con Node\ al anadirlo.
        $roots = @($AngularRoot, $PythonRoot, $JavaRoot, $NodeRoot, $GitRoot,
                   $MavenRoot, $GradleRoot, $DotnetRoot, $VSCodeRoot | ForEach-Object {
            [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\')
        })

        $delKit = @()
        foreach ($b in $broken) {
            $exp = [Environment]::ExpandEnvironmentVariables($b).TrimEnd('\')
            $esDelKit = [bool](@($roots | Where-Object {
                $exp -ieq $_ -or $exp.StartsWith($_ + '\', [StringComparison]::OrdinalIgnoreCase)
            }).Count)

            if ($esDelKit) { $delKit += $b; Write-Detail "$b   (del kit)" }
            else           { Write-Detail "$b   (ajena: no se toca)" }
        }

        if ($delKit.Count -gt 0) {
            Add-Fix -Description "quitar $($delKit.Count) ruta(s) muerta(s) del kit en el PATH" `
                    -Arguments @{ Targets = $delKit } -Action {
                param($Targets)
                Remove-UserPathEntry -Path $Targets | Out-Null
            }
        }
    }
    else {
        Write-Check "Rutas inexistentes" "ninguna" 'ok'
    }

    $backupDir = Join-Path $env:LOCALAPPDATA "AssassinSkipAdm\path-backups"
    if (Test-Path $backupDir) {
        $backups = @(Get-ChildItem $backupDir -Filter *.txt -ErrorAction SilentlyContinue)
        Write-Check "Copias del PATH" "$($backups.Count) en $backupDir" 'info'
    }

    # El registro se menciona aqui y no al arrancar cada comando: Doctor es el
    # punto de entrada documentado cuando algo falla, asi que es donde el usuario
    # va a mirar. Anadir una linea a cada ejecucion seria ruido.
    if (Test-Path $KitLogDir) {
        $logs = @(Get-ChildItem $KitLogDir -Filter *.log -ErrorAction SilentlyContinue)
        if ($logs.Count -gt 0) {
            Write-Check "Registro de ejecuciones" "$($logs.Count) en $KitLogDir" 'info'
            # Puede haber logs de ejecuciones ANTERIORES y no de esta: con
            # ASSASSINSKIPADM_NOLOG la variable no existe. Sin esta comprobacion,
            # Split-Path recibia $null y Doctor escupia un error de PowerShell.
            if ($env:ASSASSINSKIPADM_LOGFILE) {
                Write-Detail "El de esta ejecucion: $(Split-Path -Leaf $env:ASSASSINSKIPADM_LOGFILE)"
            }
            Write-Detail "Adjunta el mas reciente si tienes que abrir un ticket a IT."
        }
    }
}

function Get-KitProvidedCommand {
    <#
        Busca el ejecutable dentro de lo que instalo el kit, mirando el disco y
        no el PATH. Sirve para distinguir "el kit no lo tiene" de "el kit lo
        tiene pero no lo publica en el PATH global".
    #>
    param([Parameter(Mandatory=$true)][string]$FileName)

    $found = @()

    $places = @()
    if (Test-Path $AngularRoot) {
        foreach ($d in (Get-ChildItem $AngularRoot -Directory -ErrorAction SilentlyContinue)) {
            $places += $d.FullName
            $places += (Join-Path $d.FullName "npm-global")
        }
    }
    if (Test-Path $PythonRoot) {
        foreach ($d in (Get-ChildItem $PythonRoot -Directory -ErrorAction SilentlyContinue)) {
            $places += $d.FullName
            $places += (Join-Path $d.FullName "Scripts")
        }
    }
    if (Test-Path $JavaRoot) {
        foreach ($d in (Get-ChildItem $JavaRoot -Directory -ErrorAction SilentlyContinue)) {
            $places += (Join-Path $d.FullName "bin")
        }
    }

    foreach ($p in $places) {
        if (Test-Path -LiteralPath (Join-Path $p $FileName)) {
            $normalized = $p.TrimEnd('\')
            if ($found -notcontains $normalized) { $found += $normalized }
        }
    }

    return $found
}

function Test-PathConflicts {
    <#
        Responde a "si escribo 'node' en una terminal, cual arranca?".
        Es la pregunta que mas confunde cuando conviven la instalacion del kit,
        otra que el usuario ya tenia, y varias versiones del propio kit.
    #>
    Write-Section "Que version responde"

    $entries = Get-EffectivePathEntries

    $activated = @(Get-ActivationPaths)
    if ($activated.Count -gt 0) {
        Write-Check "Use-Env" "activo ($($activated.Count) rutas antepuestas)" 'ok'
        Write-Detail "Se aplican al abrir cada terminal, por delante del PATH de maquina."
    }
    else {
        Write-Check "Use-Env" "no activado" 'info'
        Write-Detail "Solo hace falta si abajo aparece algun '[X] NO es la del kit'."
    }

    $commands = @(
        @{ File = 'node.exe';   Label = 'node' },
        @{ File = 'npm.cmd';    Label = 'npm' },
        @{ File = 'ng.cmd';     Label = 'ng' },
        @{ File = 'python.exe'; Label = 'python' },
        @{ File = 'java.exe';   Label = 'java' }
    )

    $anyKit = $false

    foreach ($c in $commands) {
        $hits    = @(Find-CommandInPath -FileName $c.File -Entries $entries)
        $kitDirs = @(Get-KitProvidedCommand -FileName $c.File)

        if ($kitDirs.Count -gt 0) { $anyKit = $true }

        if ($hits.Count -eq 0) {
            if ($kitDirs.Count -gt 0) {
                Write-Check $c.Label "solo dentro del shell del kit" 'info'
                foreach ($k in $kitDirs) { Write-Detail $k }
            }
            else {
                Write-Check $c.Label "no esta en el PATH" 'info'
            }
            continue
        }

        $winner    = $hits[0]
        $winnerIsKit = ($kitDirs | Where-Object { $_ -ieq $winner.Path }).Count -gt 0
        $kitOnPath = @($hits | Where-Object { $p = $_.Path; ($kitDirs | Where-Object { $_ -ieq $p }).Count -gt 0 })

        $version = Invoke-VersionProbe -Exe (Join-Path $winner.Path $c.File)
        $shown = if ($version) { $version } else { "(no responde)" }

        # Caso critico: el kit tiene su copia en el PATH pero gana otra. Pasa
        # siempre que la rival este en el PATH de MAQUINA, porque ese bloque se
        # busca antes que el de usuario y el kit no puede tocarlo sin admin.
        if ($kitOnPath.Count -gt 0 -and -not $winnerIsKit) {
            Write-Check $c.Label "$shown  <- NO es la del kit" 'fail'
            Write-Detail "gana:   $($winner.Path)   [PATH de $($winner.Scope)]"
            foreach ($k in $kitOnPath) {
                Write-Detail "tapada: $($k.Path)   [PATH de $($k.Scope)]"
            }
            if ($winner.Scope -eq 'maquina') {
                Write-Detail "El PATH de maquina se busca ANTES que el de usuario, y el kit"
                Write-Detail "no puede modificarlo sin admin. Usa el shell generado del kit."
            }
            continue
        }

        # El kit lo trae instalado pero deliberadamente no lo publica en el PATH
        # global (es el caso de ng: cada version vive en su npm-global). Sin este
        # aviso, el usuario cree estar usando la del kit y no lo esta.
        if ($kitDirs.Count -gt 0 -and $kitOnPath.Count -eq 0 -and -not $winnerIsKit) {
            Write-Check $c.Label "$shown  <- no es la del kit" 'warn'
            Write-Detail "gana:      $($winner.Path)   [PATH de $($winner.Scope)]"
            foreach ($k in $kitDirs) { Write-Detail "el kit trae: $k  (solo dentro de su shell)" }
            continue
        }

        if ($hits.Count -eq 1) {
            Write-Check $c.Label $shown 'ok'
            Write-Detail "$($winner.Path)   [PATH de $($winner.Scope)]"
            continue
        }

        Write-Check $c.Label "$shown  ($($hits.Count) copias en el PATH)" 'warn'
        Write-Detail "gana:   $($winner.Path)   [PATH de $($winner.Scope)]"
        foreach ($h in ($hits | Select-Object -Skip 1)) {
            Write-Detail "tapada: $($h.Path)   [PATH de $($h.Scope)]"
        }
    }

    if ($anyKit) {
        Write-Host ""
        Write-Detail "Los shells del kit (shell-vN.bat, pyXYZ-shell.bat) fijan su propio"
        Write-Detail "PATH, asi que dentro de ellos siempre manda su version."
    }
}

function Test-KitIntegrity {
    Write-Section "Kit"

    Write-Check "Version del kit" $KitVersion 'info'
    Write-Check "Raiz del kit" $DevKitRoot 'info'
    Write-Check "Workspace" $WorkspaceRoot 'info'

    # Los .bat son la interfaz publica: si falta uno, el kit esta roto para el
    # usuario aunque los .ps1 esten todos.
    $expected = @(
        "lib\Common.ps1",
        "scripts\Setup-AngularEnv.ps1",
        "scripts\Setup-PythonEnv.ps1",
        "scripts\Start-AngularEnv.ps1",
        "scripts\Start-PythonEnv.ps1",
        "scripts\Install-NoAdmin.ps1",
        "scripts\Doctor-Env.ps1",
        "scripts\Uninstall-Env.ps1",
        "scripts\Use-Env.ps1",
        "scripts\Export-Env.ps1",
        "scripts\Import-Env.ps1",
        "Export-Env.bat",
        "Import-Env.bat",
        "scripts\Setup-JavaEnv.ps1",
        "scripts\Start-JavaEnv.ps1",
        "Setup-JavaEnv.bat",
        "Start-JavaEnv.bat",
        "Use-Env.bat",
        "Setup-AngularEnv.bat",
        "Setup-PythonEnv.bat",
        "Start-AngularEnv.bat",
        "Start-PythonEnv.bat",
        "Install-NoAdmin.bat",
        "Doctor-Env.bat",
        "Uninstall-Env.bat",
        "Run-Tests.bat",
        "scripts\Run-Tests.ps1",
        "Setup-NodeEnv.bat",
        "Start-NodeEnv.bat",
        "scripts\Setup-NodeEnv.ps1",
        "scripts\Start-NodeEnv.ps1",
        "Update-Env.bat",
        "scripts\Update-Env.ps1",
        "Setup-GitEnv.bat",
        "Start-GitEnv.bat",
        "scripts\Setup-GitEnv.ps1",
        "scripts\Start-GitEnv.ps1",
        "sources.json.ejemplo",
        "Setup-MavenEnv.bat",
        "Start-MavenEnv.bat",
        "scripts\Setup-MavenEnv.ps1",
        "scripts\Start-MavenEnv.ps1",
        "Setup-GradleEnv.bat",
        "Start-GradleEnv.bat",
        "scripts\Setup-GradleEnv.ps1",
        "scripts\Start-GradleEnv.ps1",
        "Setup-DotnetEnv.bat",
        "Start-DotnetEnv.bat",
        "scripts\Setup-DotnetEnv.ps1",
        "scripts\Start-DotnetEnv.ps1",
        "Setup-VSCodeEnv.bat",
        "Start-VSCodeEnv.bat",
        "scripts\Setup-VSCodeEnv.ps1",
        "scripts\Start-VSCodeEnv.ps1",
        "Restore-Env.bat",
        "scripts\Restore-Env.ps1",
        "devenv.json.ejemplo",
        "tests\Common.Tests.ps1",
        "tests\Shells.Tests.ps1",
        "tests\UserPath.Tests.ps1",
        "tests\InstallNoAdmin.Tests.ps1"
    )

    $missing = @()
    foreach ($rel in $expected) {
        if (-not (Test-Path -LiteralPath (Join-Path $DevKitRoot $rel))) { $missing += $rel }
    }

    if ($missing.Count -eq 0) {
        Write-Check "Archivos del kit" "completos ($($expected.Count))" 'ok'
    }
    else {
        Write-Check "Archivos del kit" "faltan $($missing.Count)" 'fail'
        foreach ($m in $missing) { Write-Detail $m }
    }
}

# --------------------------------------------------------------------------

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Doctor-Env - Diagnostico del entorno" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

Test-KitIntegrity
Test-Host
Test-Network
Test-AngularInstall
Test-PythonInstall
Test-JavaInstall
Test-NodeInstall
Test-GitInstall
Test-BuildToolInstall -Titulo "Maven" -Root $MavenRoot -Prefijo 'maven' `
                      -ExeRel 'bin\mvn.cmd' -ShellPrefijo 'mvn' `
                      -JarGlob 'lib\maven-core-*.jar' -JarRegex 'maven-core-([\d.]+)\.jar' `
                      -SetupBat '.\Setup-MavenEnv.bat'
Test-BuildToolInstall -Titulo "Gradle" -Root $GradleRoot -Prefijo 'gradle' `
                      -ExeRel 'bin\gradle.bat' -ShellPrefijo 'gradle' `
                      -JarGlob 'lib\gradle-launcher-*.jar' -JarRegex 'gradle-launcher-([\d.]+)\.jar' `
                      -SetupBat '.\Setup-GradleEnv.bat'
Test-DotnetInstall
Test-VSCodeInstall
Test-PortableApps
Test-UserPath
Test-PathConflicts

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
if ($script:Problems -eq 0 -and $script:Warnings -eq 0) {
    Write-Host "  Todo correcto." -ForegroundColor Green
}
elseif ($script:Problems -eq 0) {
    Write-Host "  $($script:Warnings) aviso(s), ningun problema grave." -ForegroundColor Yellow
}
else {
    Write-Host "  $($script:Problems) problema(s) y $($script:Warnings) aviso(s)." -ForegroundColor Red
}
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# --------------------------------------------------------------------------
# Informe
# --------------------------------------------------------------------------

function Save-DoctorReport {
    <#
        Vuelca el diagnostico a un markdown listo para adjuntar a un ticket.

        Se escribe ANTES de las reparaciones a proposito: el informe debe
        retratar el problema tal como estaba, no como quedo despues de -Fix. Si
        alguien lo manda a IT tras reparar, lo util es lo que fallaba.
    #>
    param([string]$Destino)

    if ([string]::IsNullOrWhiteSpace($Destino)) {
        $dir = Join-Path $env:LOCALAPPDATA "AssassinSkipAdm\informes"
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $Destino = Join-Path $dir ("doctor-{0}.md" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }
    else {
        $padre = Split-Path -Parent $Destino
        if ($padre -and -not (Test-Path -LiteralPath $padre)) {
            New-Item -ItemType Directory -Path $padre -Force | Out-Null
        }
    }

    $resumen = if ($script:Problems -eq 0 -and $script:Warnings -eq 0) { "Todo correcto." }
               elseif ($script:Problems -eq 0) { "$($script:Warnings) aviso(s), ningun problema grave." }
               else { "$($script:Problems) problema(s) y $($script:Warnings) aviso(s)." }

    $cabecera = @(
        "# Diagnostico del entorno de desarrollo",
        "",
        "| | |",
        "|---|---|",
        "| Generado | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') |",
        "| Version del kit | $KitVersion |",
        "| Equipo | $env:COMPUTERNAME |",
        "| Usuario | $env:USERNAME |",
        "| Windows | $([Environment]::OSVersion.Version) |",
        "| PowerShell | $($PSVersionTable.PSVersion) |",
        "| Resultado | **$resumen** |",
        "",
        # El backtick es el escape de PowerShell: para que salga literal en el
        # markdown hay que duplicarlo.
        "> Este informe se puede adjuntar tal cual a un ticket. Si hay un proxy",
        "> configurado, su contrasena aparece enmascarada como ``***``.",
        ""
    )

    $pie = @(
        "",
        "---",
        "",
        "## Resumen",
        "",
        "**$resumen**",
        ""
    )
    if ($script:Fixes.Count -gt 0) {
        $pie += "Reparable automaticamente con ``.\Doctor-Env.bat -Fix``:"
        $pie += ""
        foreach ($f in $script:Fixes) { $pie += "- $($f.Description)" }
        $pie += ""
    }
    if ($env:ASSASSINSKIPADM_LOGFILE) {
        $pie += "Registro de esta ejecucion: ``$(Split-Path -Leaf $env:ASSASSINSKIPADM_LOGFILE)``"
        $pie += ""
    }

    try {
        Set-Content -LiteralPath $Destino -Value ($cabecera + $script:ReportLines + $pie) -Encoding UTF8
        return $Destino
    }
    catch {
        Write-Log "No se pudo escribir el informe: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

if ($Report) {
    $archivo = Save-DoctorReport -Destino $ReportPath
    if ($archivo) {
        Write-Host "Informe guardado en:" -ForegroundColor Green
        Write-Host "  $archivo"
        Write-Host ""
        Write-Host "Se puede adjuntar tal cual a un ticket: la clave del proxy va enmascarada." -ForegroundColor Gray
        Write-Host ""
    }
}

# --------------------------------------------------------------------------
# Reparaciones
# --------------------------------------------------------------------------

if ($script:Fixes.Count -eq 0) {
    if ($Fix) {
        Write-Host "No hay nada reparable automaticamente." -ForegroundColor Gray
        Write-Host "Lo que quede arriba necesita reinstalar o decidirlo tu." -ForegroundColor Gray
        Write-Host ""
    }
    if ($script:Problems -gt 0) { exit 1 }
    exit 0
}

Write-Host "Reparable automaticamente ($($script:Fixes.Count)):" -ForegroundColor Yellow
foreach ($f in $script:Fixes) { Write-Host "  - $($f.Description)" }
Write-Host ""

if (-not $Fix) {
    Write-Host "Para arreglarlo:  .\Doctor-Env.bat -Fix" -ForegroundColor Cyan
    Write-Host ""
    if ($script:Problems -gt 0) { exit 1 }
    exit 0
}

if (-not $Force) {
    Write-Host "Se modificara tu PATH de usuario y/o archivos del kit." -ForegroundColor Yellow
    Write-Host "Cada cambio del PATH deja copia en %LOCALAPPDATA%\AssassinSkipAdm." -ForegroundColor Gray
    Write-Host ""
    $answer = Read-Host "Confirmas? (escribe SI)"
    if ($answer -ne 'SI') {
        Write-Host "Cancelado. No se ha tocado nada." -ForegroundColor Yellow
        exit 0
    }
    Write-Host ""
}

$hechas = 0
$fallidas = 0
foreach ($f in $script:Fixes) {
    try {
        $fixArgs = $f.Arguments
        & $f.Action @fixArgs
        Write-Log $f.Description "SUCCESS"
        $hechas++
    }
    catch {
        Write-Log "fallo: $($f.Description)" "ERROR"
        Write-Log "  $($_.Exception.Message)" "ERROR"
        $fallidas++
    }
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  $hechas reparada(s), $fallidas con error" -ForegroundColor $(if ($fallidas -eq 0) { 'Cyan' } else { 'Red' })
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Vuelve a ejecutar .\Doctor-Env.bat para comprobar." -ForegroundColor Gray
Write-Host ""

if ($fallidas -gt 0) { exit 1 }
exit 0
