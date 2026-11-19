#Requires -Version 5.1
<#
.SYNOPSIS
    Setup-Project.ps1 - Deja listo un proyecto: su Python, su .venv y sus dependencias.
.DESCRIPTION
    En la carpeta de un proyecto, lee lo que pide -de .python-version,
    pyproject.toml, requirements.txt, package.json, .nvmrc o pom.xml- y lo
    deja funcionando:

      Python  instala la linea que pide, crea su .venv con ESA y le instala
              las dependencias (requirements.txt o las de pyproject.toml)
      Node    instala la Node que pide y ejecuta npm ci (o npm install)
      Java    instala el JDK que pide, y Maven o Gradle si el proyecto no
              trae su propio lanzador (mvnw, gradlew). No compila nada.
      Android el SDK con la plataforma de su compileSdk (sin el emulador,
              que es mas de 1 GB: se dice como ponerlo).

    Es lo que faltaba despues de "ya instale Python": saber cual pedia el
    proyecto y montar su entorno con el.

    Un .venv que ya existe se respeta. Si esta roto (su Python ya no existe,
    lo normal al copiar un proyecto de otra maquina) o es de otra linea, se
    dice, y con -Force se rehace.
.PARAMETER Path
    La carpeta del proyecto. Por defecto, la actual.
.PARAMETER WhatIf
    Dice lo que haria y no toca nada.
.PARAMETER Force
    Rehace un .venv roto o de otra linea, y vuelve a instalar las
    dependencias de Node aunque ya este node_modules.
.PARAMETER SinDependencias
    Solo los runtimes y el .venv; no instala paquetes.
.EXAMPLE
    .\Setup-Project.ps1 -Path C:\proyectos\mi-app
.EXAMPLE
    .\Setup-Project.ps1 -WhatIf
#>

param(
    [string]$Path,

    [switch]$WhatIf,

    [switch]$Force,

    [switch]$SinDependencias
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Common.ps1")
# Lo que lee los archivos del proyecto (ver su cabecera: no lo carga Common).
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Project.ps1")
# Lo que pide cada version del plugin de Android (tampoco lo carga Common).
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Android.ps1")

if ([string]::IsNullOrWhiteSpace($Path)) { $Path = (Get-Location).Path }
$Path = $Path.Trim().Trim('"')
if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    Write-Log "No existe la carpeta: $Path" "ERROR"
    exit 1
}
$Path = (Resolve-Path -LiteralPath $Path).ProviderPath

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Setup-Project - Dejar listo un proyecto" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  $Path" -ForegroundColor White
Write-Host ""

$entradaPython = @(Get-RuntimeCatalog | Where-Object { $_.Clave -eq 'python' })[0]
$pyInstaladas = @(Get-InstalledRuntimeLines -Entrada $entradaPython)
$n = Get-ProjectNeeds -Ruta $Path -PythonInstaladas $pyInstaladas

if (-not $n.Python -and -not $n.Node -and -not $n.Java) {
    Write-Log "No reconozco nada que preparar aqui." "WARN"
    Write-Log "  Busco pyproject.toml, requirements.txt, .python-version, package.json, pom.xml o build.gradle (tambien de Android)." "WARN"
    exit 0
}

function Invoke-KitSetup {
    <#
        Un Setup-*Env del kit, en este proceso. $LASTEXITCODE se pone a 0
        antes: un .ps1 sin exit explicito no lo toca (ver Restore-Env).
    #>
    param([string]$Script, [hashtable]$Argumentos = @{})
    $s = Resolve-KitScript -Nombre $Script
    $global:LASTEXITCODE = 0
    try { & $s @Argumentos } catch { Write-Log "$Script fallo: $($_.Exception.Message)" "ERROR"; return $false }
    return ($null -eq $LASTEXITCODE -or $LASTEXITCODE -eq 0)
}

function Set-ToolNetworkEnv {
    <#
        Proxy y CA de la empresa para pip y npm, solo en este proceso. pip por
        PIP_PROXY (no por --proxy, que deja la clave a la vista en la linea de
        comandos) y PIP_CERT; npm y Node por NODE_EXTRA_CA_CERTS. Devuelve lo
        que habia, para dejarlo como estaba.
    #>
    $previo = @{ PIP_PROXY = $env:PIP_PROXY; PIP_CERT = $env:PIP_CERT; NODE_EXTRA_CA_CERTS = $env:NODE_EXTRA_CA_CERTS }
    $proxy = Resolve-DownloadProxy -Uri ([Uri]"https://pypi.org")
    if ($proxy) { $env:PIP_PROXY = $proxy }
    if (Test-Path -LiteralPath $CorpCaPem) {
        $env:PIP_CERT = $CorpCaPem
        $env:NODE_EXTRA_CA_CERTS = $CorpCaPem
    }
    return $previo
}

# --------------------------------------------------------------------------
# El plan
# --------------------------------------------------------------------------

Write-Host "Lo que pide:" -ForegroundColor Yellow
if ($n.DevEnv) {
    Write-Host "  (trae devenv.json: Restore-Env instala exactamente lo que dice)" -ForegroundColor DarkGray
}

$py = $n.Python
$venv = Join-Path $Path '.venv'
$venvInfo = $null
if ($py) {
    $pedida = if ($py.Exacta) { $py.Exacta } else { $py.Linea }
    Write-Host "  Python $pedida   ($($py.Fuente))"
    $venvInfo = Get-VenvInfo -Ruta $venv
    if (-not $venvInfo.Existe) { Write-Host "    .venv: no existe; se crea con Python $($py.Linea)" }
    elseif (-not $venvInfo.BaseExiste) { Write-Host "    .venv: ROTO, su Python ya no existe ($($venvInfo.Base))" -ForegroundColor Yellow }
    elseif ($venvInfo.Linea -and $venvInfo.Linea -ne $py.Linea) { Write-Host "    .venv: es de Python $($venvInfo.Linea), no de $($py.Linea)" -ForegroundColor Yellow }
    else { Write-Host "    .venv: ya existe y sirve" }
    switch ($py.Dependencias) {
        'requirements' { Write-Host "    dependencias: requirements.txt" }
        'pyproject'    { Write-Host "    dependencias: $(@($py.Paquetes).Count) de pyproject.toml" }
        default        { Write-Host "    dependencias: no declara ninguna" -ForegroundColor DarkGray }
    }
    foreach ($a in $py.Avisos) { Write-Host "    $a" -ForegroundColor Yellow }
}

$nodo = $n.Node
if ($nodo) {
    $pista = if ($nodo.Pista) { "$($nodo.Pista.Valor)   ($($nodo.Pista.Fuente))" } else { "(no la dice; la que haya o la ultima LTS)" }
    Write-Host "  Node $pista"
    Write-Host "    dependencias: $(if ($nodo.Lock) { 'npm ci (hay package-lock.json)' } else { 'npm install' })"
}

$java = $n.Java
$android = $n.Android

# En un proyecto Android, el JDK con que corre Gradle lo decide la version de
# su plugin (AGP), no el sourceCompatibility, que es el del bytecode; y sus
# build-tools, las que use ese AGP si el proyecto no dice otras.
$agpReq = if ($android) { Get-AgpRequirements -Agp $android.Agp } else { $null }
$jdkAndroid = if ($agpReq) { $agpReq.Jdk } else { $null }
$btAndroid = if ($android -and $android.BuildTools) { $android.BuildTools } elseif ($agpReq) { $agpReq.BuildTools } else { $null }

if ($java) {
    $j = if ($android) { "Java $(if ($jdkAndroid) { "$jdkAndroid   (el que pide AGP $($android.Agp))" } else { "17 o mas   (no se ve que AGP usa)" })" }
         elseif ($java.Mayor) { "Java $($java.Mayor)   ($($java.Fuente))" } else { "Java   ($($java.Fuente) no dice que version)" }
    Write-Host "  $j"
    if ($java.Maven)  { Write-Host "    y Maven: no trae mvnw" }
    if ($java.Gradle) { Write-Host "    y Gradle: no trae gradlew" }
}
if ($android) {
    Write-Host "  Android: plataforma $(if ($android.CompileSdk) { "android-$($android.CompileSdk)" } else { '(no la dice; la mas reciente)' })   ($($android.Fuente))"
    if ($btAndroid) { Write-Host "    build-tools $btAndroid$(if (-not $android.BuildTools) { "   (las de AGP $($android.Agp))" })" }
    if ($android.MinSdk) { Write-Host "    minimo Android API $($android.MinSdk)" }
}
Write-Host ""

if ($WhatIf) {
    Write-Host "-WhatIf: no se ha tocado nada." -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

$fallos = @()
$uso = @()

# --------------------------------------------------------------------------
# Python
# --------------------------------------------------------------------------

if ($py) {
    Write-Host "--- Python ---" -ForegroundColor Cyan
    $base = Join-Path $WorkspaceRoot "Python\python-$($py.Linea)"
    $exe = Join-Path $base 'python.exe'

    if (-not (Test-Path -LiteralPath $exe)) {
        $v = if ($py.Exacta) { $py.Exacta } else { $py.Linea }
        if (-not (Invoke-KitSetup -Script 'Setup-PythonEnv.ps1' -Argumentos @{ PythonVersion = $v })) { $fallos += 'Python' }
    }
    else {
        Write-Log "Python $($py.Linea) ya esta instalado" "SUCCESS"
    }

    $listo = (Test-Path -LiteralPath $exe) -and ($fallos -notcontains 'Python')
    if ($listo -and (Get-ChildItem -LiteralPath $base -Filter 'python*._pth' -File -ErrorAction SilentlyContinue)) {
        Write-Log "El Python $($py.Linea) instalado es el embeddable de antes: no sabe crear un .venv." "ERROR"
        Write-Log "  Cambialo por el completo:  .\bin\setup\Setup-PythonEnv.bat -PythonVersion $($py.Linea) -Force" "WARN"
        $fallos += 'Python (.venv)'
        $listo = $false
    }

    if ($listo) {
        $rehacer = $venvInfo.Existe -and (-not $venvInfo.BaseExiste -or ($venvInfo.Linea -and $venvInfo.Linea -ne $py.Linea))
        if ($rehacer -and -not $Force) {
            if (-not $venvInfo.BaseExiste) {
                Write-Log ".venv esta roto: apunta a $($venvInfo.Base), que aqui no existe." "WARN"
                Write-Log "  Para rehacerlo con Python $($py.Linea):  .\bin\env\Setup-Project.bat -Path `"$Path`" -Force" "WARN"
                $fallos += 'Python (.venv)'
                $listo = $false
            }
            else {
                Write-Log ".venv es de Python $($venvInfo.Linea) y el proyecto pide $($py.Linea); se deja como esta." "WARN"
                Write-Log "  Para rehacerlo con $($py.Linea):  -Force" "WARN"
            }
        }
        elseif ($rehacer) {
            Write-Log "-Force: se rehace .venv con Python $($py.Linea)" "WARN"
            Remove-Item -LiteralPath $venv -Recurse -Force
            $venvInfo = Get-VenvInfo -Ruta $venv
        }
    }

    if ($listo -and -not $venvInfo.Existe) {
        Write-Log "Creando .venv con Python $($py.Linea)..."
        $r = Invoke-NativeCommand -FilePath $exe -Arguments @('-m', 'venv', $venv) -Quiet
        if ($r.ExitCode -ne 0) {
            Write-Log "No se pudo crear el .venv: $($r.Output.Trim())" "ERROR"
            $fallos += 'Python (.venv)'
            $listo = $false
        }
        else { Write-Log ".venv creado" "SUCCESS" }
    }

    if ($listo -and -not $SinDependencias -and $py.Dependencias) {
        $vpy = Join-Path $venv 'Scripts\python.exe'
        $argsPip = @('-m', 'pip', 'install', '--disable-pip-version-check')
        $argsPip += if ($py.Dependencias -eq 'requirements') { @('-r', (Join-Path $Path 'requirements.txt')) } else { @($py.Paquetes) }

        Write-Log "Instalando dependencias en .venv..."
        $previo = Set-ToolNetworkEnv
        try { $r = Invoke-NativeCommand -FilePath $vpy -Arguments $argsPip }
        finally { foreach ($k in $previo.Keys) { Restore-EnvVar -Name $k -Value $previo[$k] } }

        if ($r.ExitCode -eq 0) { Write-Log "Dependencias instaladas" "SUCCESS" }
        else {
            Write-Log "pip fallo (codigo $($r.ExitCode)). Arriba esta lo que dijo." "ERROR"
            $fallos += 'Python (dependencias)'
        }
    }

    if ($listo) {
        $uso += "Python:  .venv\Scripts\activate   (o sin activar:  .venv\Scripts\python main.py)"
    }
}

# --------------------------------------------------------------------------
# Node
# --------------------------------------------------------------------------

if ($nodo) {
    Write-Host ""
    Write-Host "--- Node ---" -ForegroundColor Cyan
    $nodeRoot = Join-Path $WorkspaceRoot 'Node'
    $instaladas = @(Get-ChildItem -LiteralPath $nodeRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^node-(\d+)$' -and (Test-Path (Join-Path $_.FullName 'node.exe')) } |
        ForEach-Object { [int]($_.Name -replace 'node-', '') } | Sort-Object -Descending)

    $mayor = $null
    if ($nodo.Pista -and $nodo.Pista.Tipo -eq 'mayor') { $mayor = [int]$nodo.Pista.Valor }
    elseif ($nodo.Pista -and $nodo.Pista.Tipo -eq 'rango') {
        # Primero una ya instalada que cumpla el rango; si no, la LTS mas alta
        # que lo cumpla, con su version exacta y no con la mayor a secas.
        foreach ($m in $instaladas) {
            $v = (Invoke-NativeCommand -FilePath (Join-Path $nodeRoot "node-$m\node.exe") -Arguments @('--version') -Quiet).Output.Trim().TrimStart('v')
            if ($v -and (Test-SemverRange -Version $v -Range $nodo.Pista.Valor)) { $mayor = $m; break }
        }
        if (-not $mayor) {
            $lts = @(Get-NodeLtsReleases | Sort-Object Major -Descending)
            $ok = @($lts | Where-Object { Test-SemverRange -Version $_.Version -Range $nodo.Pista.Valor })[0]
            if ($ok) { $mayor = $ok.Major }
            else { Write-Log "Ninguna LTS cumple engines.node `"$($nodo.Pista.Valor)`"; se usa la ultima." "WARN" }
        }
    }
    elseif (-not $nodo.Pista -and $instaladas.Count -gt 0) { $mayor = $instaladas[0] }

    $listoNode = $true
    if (-not $mayor -or $instaladas -notcontains $mayor) {
        $a = if ($mayor) { @{ NodeVersion = "$mayor" } } else { @{} }
        if (-not (Invoke-KitSetup -Script 'Setup-NodeEnv.ps1' -Argumentos $a)) { $fallos += 'Node'; $listoNode = $false }
        if (-not $mayor) {
            $mayor = @(Get-ChildItem -LiteralPath $nodeRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^node-(\d+)$' } | ForEach-Object { [int]($_.Name -replace 'node-', '') } | Sort-Object -Descending)[0]
        }
    }
    else { Write-Log "Node $mayor ya esta instalado" "SUCCESS" }

    $nodeDir = Join-Path $nodeRoot "node-$mayor"
    if ($listoNode -and (Test-Path (Join-Path $nodeDir 'npm.cmd')) -and -not $SinDependencias) {
        $hay = Test-Path -LiteralPath (Join-Path $Path 'node_modules')
        if ($hay -and -not $Force) {
            Write-Log "node_modules ya existe; no se reinstala (con -Force, si)" "SUCCESS"
        }
        else {
            $orden = if ($nodo.Lock) { 'ci' } else { 'install' }
            Write-Log "npm $orden con Node $mayor..."
            $previo = Set-ToolNetworkEnv
            $pathPrevio = $env:PATH
            $env:PATH = "$nodeDir;$env:PATH"
            Push-Location -LiteralPath $Path
            try { $r = Invoke-NativeCommand -FilePath (Join-Path $nodeDir 'npm.cmd') -Arguments @($orden, '--no-fund', '--no-audit') }
            finally {
                Pop-Location
                $env:PATH = $pathPrevio
                foreach ($k in $previo.Keys) { Restore-EnvVar -Name $k -Value $previo[$k] }
            }
            if ($r.ExitCode -eq 0) { Write-Log "Dependencias de Node instaladas" "SUCCESS" }
            else { Write-Log "npm $orden fallo (codigo $($r.ExitCode))" "ERROR"; $fallos += 'Node (dependencias)' }
        }
    }
    if ($listoNode) { $uso += "Node:    ..\Node\node-$mayor\node$mayor-shell.bat  (o activalo con Use-Env)" }
}

# --------------------------------------------------------------------------
# Java
# --------------------------------------------------------------------------

if ($java) {
    Write-Host ""
    Write-Host "--- Java ---" -ForegroundColor Cyan
    if ($android) { Write-Log "El JDK lo pone el SDK de Android$(if ($jdkAndroid) { ": el $jdkAndroid, el que pide AGP $($android.Agp)" } else { " (17 o mas)" })." }
    elseif ($java.Mayor) {
        if (Test-Path -LiteralPath (Join-Path $WorkspaceRoot "Java\jdk-$($java.Mayor)\bin\java.exe")) {
            Write-Log "Java $($java.Mayor) ya esta instalado" "SUCCESS"
        }
        elseif (-not (Invoke-KitSetup -Script 'Setup-JavaEnv.ps1' -Argumentos @{ JavaVersion = $java.Mayor })) { $fallos += 'Java' }
        $uso += "Java:    ..\Java\jdk-$($java.Mayor)\java$($java.Mayor)-shell.bat"
    }
    else {
        Write-Log "$($java.Fuente) no dice que version de Java pide; no se instala ninguna." "WARN"
        Write-Log "  La que quieras:  .\bin\setup\Setup-JavaEnv.bat -JavaVersion 21" "WARN"
    }

    $conJava = if ($jdkAndroid) { @{ JavaVersion = $jdkAndroid } } elseif ($java.Mayor -and -not $android) { @{ JavaVersion = $java.Mayor } } else { @{} }
    if ($java.Maven -and -not (Get-ChildItem -LiteralPath (Join-Path $WorkspaceRoot 'Maven') -Directory -Filter 'maven-*' -ErrorAction SilentlyContinue)) {
        if (-not (Invoke-KitSetup -Script 'Setup-MavenEnv.ps1' -Argumentos $conJava)) { $fallos += 'Maven' }
    }
    if ($java.Gradle -and -not (Get-ChildItem -LiteralPath (Join-Path $WorkspaceRoot 'Gradle') -Directory -Filter 'gradle-*' -ErrorAction SilentlyContinue)) {
        if (-not (Invoke-KitSetup -Script 'Setup-GradleEnv.ps1' -Argumentos $conJava)) { $fallos += 'Gradle' }
    }
}

# --------------------------------------------------------------------------
# Android
# --------------------------------------------------------------------------

if ($android) {
    Write-Host ""
    Write-Host "--- Android ---" -ForegroundColor Cyan
    # Sin -AceptarLicencias: la licencia de Google la acepta quien la lee.
    $a = @{}
    if ($android.CompileSdk) { $a['Plataforma'] = $android.CompileSdk }
    if ($btAndroid) { $a['BuildTools'] = $btAndroid }
    # Solo si es de antes de 17: uno de 17 o mas ya lo pone Setup-AndroidEnv.
    $conOtroJdk = ($jdkAndroid -and $jdkAndroid -lt 17)
    if ($conOtroJdk) { $a['Jdk'] = $jdkAndroid }
    if (Invoke-KitSetup -Script 'Setup-AndroidEnv.ps1' -Argumentos $a) {
        $uso += "Android: compilarla y abrirla en el telefono, de una vez:  Menu.bat, opcion 60"
        $uso += "         (o .\bin\start\Start-AndroidApp.bat -Path `"$Path`")"
        $uso += "         a mano:  ..\Android\android-$(if ($conOtroJdk) { "java$jdkAndroid-" })shell.bat   y despues  gradlew assembleDebug"
    }
    else { $fallos += 'Android' }
}

# --------------------------------------------------------------------------

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
if ($fallos.Count -eq 0) {
    Write-Host "  PROYECTO LISTO" -ForegroundColor Cyan
}
else {
    Write-Host "  A medias: falta $($fallos -join ', ')" -ForegroundColor Red
}
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
if ($uso.Count -gt 0) {
    Write-Host "Para trabajar en el, desde su carpeta:" -ForegroundColor Yellow
    foreach ($u in $uso) { Write-Host "  $u" -ForegroundColor White }
    Write-Host ""
}

if ($fallos.Count -gt 0) { exit 1 }
exit 0
