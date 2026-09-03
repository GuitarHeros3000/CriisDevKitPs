#Requires -Version 5.1
<#
.SYNOPSIS
    Update-Env.ps1 - Dice que actualizaciones hay para lo que tienes instalado.
.DESCRIPTION
    Hasta ahora solo te enterabas de que existia un patch nuevo si reejecutabas
    el setup correspondiente. Este comando compara lo instalado contra lo que
    publican las fuentes oficiales y te lo dice de una vez.

    Sin -Apply NO instala nada, como Doctor sin -Fix: se limita a decirte el
    comando exacto que actualizaria cada cosa.

    Sale con codigo 1 si hay alguna actualizacion disponible, para poder
    encadenarlo ("avisame si hay algo nuevo"). Codigo 0 si esta todo al dia.
.PARAMETER Runtime
    Comprueba solo uno: Angular, Python, Java o Node.
.PARAMETER Apply
    Ejecuta las actualizaciones en vez de solo listarlas. Son EXACTAMENTE los
    mismos comandos que se imprimen sin este parametro, uno detras de otro.

    Pide confirmacion, y no por formalidad: actualizar implica -Force, que
    reinstala desde cero, y en Python eso se lleva por delante los paquetes pip
    de esa version. Se avisa antes y nombrando cual.
.PARAMETER Force
    Con -Apply, no pide confirmacion. Mismo significado que en Doctor.
.EXAMPLE
    .\Update-Env.ps1
.EXAMPLE
    .\Update-Env.ps1 -Runtime Java
.EXAMPLE
    .\Update-Env.ps1 -Runtime Java -Apply
#>

param(
    [ValidateSet('Angular', 'Python', 'Java', 'Node', 'Git', 'Maven', 'Gradle', 'Dotnet', 'VSCode')]
    [string]$Runtime,

    [switch]$Apply,

    [switch]$Force
)

$ProgressPreference = "SilentlyContinue"

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Common.ps1")

$AngularRoot = Join-Path $WorkspaceRoot "Angular"
$PythonRoot  = Join-Path $WorkspaceRoot "Python"
$JavaRoot    = Join-Path $WorkspaceRoot "Java"
$NodeRoot    = Join-Path $WorkspaceRoot "Node"
$GitRoot     = Join-Path $WorkspaceRoot "Git"
$MavenRoot   = Join-Path $WorkspaceRoot "Maven"
$GradleRoot  = Join-Path $WorkspaceRoot "Gradle"
$DotnetRoot  = Join-Path $WorkspaceRoot "Dotnet"
$VSCodeRoot  = Join-Path $WorkspaceRoot "VSCode"

# Cada fila: que es, que hay, que se publica, y como actualizarlo.
$script:Filas = @()
$script:SinRed = $false

function Add-Fila {
    param(
        [string]$Que,
        [string]$Instalado,
        [string]$Disponible,
        [string]$Comando
    )

    $estado = if (-not $Disponible)                 { 'desconocido' }
              elseif ($Disponible -eq $Instalado)   { 'al dia' }
              else                                  { 'actualizable' }

    # El comando se parte AQUI, en el unico sitio, y no en los nueve
    # Test-*Updates. La cadena no viene de fuera: la construye el propio kit dos
    # lineas mas arriba con una version que acaba de resolver, asi que partirla
    # por espacios es seguro. Y el .bat se resuelve con Resolve-KitCommand, el
    # mismo que usa el menu, para que -Apply no se entere si manana se mueven de
    # carpeta otra vez.
    $bat = $null
    $argumentos = @()

    if ($Comando) {
        $partes = @($Comando -split '\s+' | Where-Object { $_ })
        if ($partes.Count -gt 0) {
            $bat = Resolve-KitCommand -Nombre (Split-Path -Leaf $partes[0])
            if ($partes.Count -gt 1) { $argumentos = @($partes[1..($partes.Count - 1)]) }
        }
    }

    $script:Filas += [PSCustomObject]@{
        Que        = $Que
        Instalado  = $Instalado
        Disponible = if ($Disponible) { $Disponible } else { '?' }
        Estado     = $estado
        Comando    = $Comando
        Bat        = $bat
        Argumentos = $argumentos
    }
    if ($estado -eq 'desconocido') { $script:SinRed = $true }
}

function Get-VersionDe {
    <#
        Lee la version que reporta un binario. Devuelve $null si no arranca, que
        Doctor ya trata como instalacion corrupta; aqui simplemente no se compara.
    #>
    param([string]$Exe, [string[]]$Args_ = @('--version'), [string]$Patron = '(\d+\.\d+\.\d+)')

    if (-not (Test-Path $Exe)) { return $null }
    $run = Invoke-NativeCommand -FilePath $Exe -Arguments $Args_ -Quiet
    if ($run.ExitCode -ne 0) { return $null }
    if ($run.Output -match $Patron) { return $Matches[1] }
    return $null
}

# --------------------------------------------------------------------------

function Test-PythonUpdates {
    if (-not (Test-Path $PythonRoot)) { return }

    foreach ($d in (Get-ChildItem $PythonRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -notmatch '^python-(\d+\.\d+)$') { continue }
        $serie = $Matches[1]

        $instalada = Get-VersionDe -Exe (Join-Path $d.FullName "python.exe")
        if (-not $instalada) { continue }

        Write-Host "  consultando python.org ($serie)..." -ForegroundColor DarkGray
        $ultima = Get-LatestPythonPatch -MinorPrefix $serie

        Add-Fila -Que "Python $serie" -Instalado $instalada `
                 -Disponible $(if ($ultima) { $ultima.Version } else { $null }) `
                 -Comando ".\bin\setup\Setup-PythonEnv.bat -PythonVersion $serie -Force"
    }
}

function Test-JavaUpdates {
    if (-not (Test-Path $JavaRoot)) { return }

    foreach ($d in (Get-ChildItem $JavaRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -notmatch '^jdk-(\d+)$') { continue }
        $major = $Matches[1]

        # Se compara la marca de release que deja el setup, no lo que dice
        # "java -version": los formatos no coinciden entre familias y comparar
        # como texto da falsos positivos.
        $marca = Join-Path $d.FullName ".criisdevkit-release"
        $instalada = if (Test-Path $marca) { (Get-Content -LiteralPath $marca -Raw).Trim() } else { $null }
        if (-not $instalada) {
            $v = Get-VersionDe -Exe (Join-Path $d.FullName "bin\java.exe") -Args_ @('-version') -Patron 'version "([^"]+)"'
            Add-Fila -Que "Java $major" -Instalado $(if ($v) { "$v (sin marca)" } else { '?' }) `
                     -Disponible $null -Comando ".\bin\setup\Setup-JavaEnv.bat -JavaVersion $major -Force"
            continue
        }

        Write-Host "  consultando api.adoptium.net ($major)..." -ForegroundColor DarkGray
        $bin = Get-JavaArchiveInfo -Major ([int]$major)

        Add-Fila -Que "Java $major" -Instalado $instalada `
                 -Disponible $(if ($bin) { $bin.Release } else { $null }) `
                 -Comando ".\bin\setup\Setup-JavaEnv.bat -JavaVersion $major -Force"
    }
}

function Test-NodeUpdates {
    if (-not (Test-Path $NodeRoot)) { return }

    $dirs = @(Get-ChildItem $NodeRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^node-(\d+)$' })
    if ($dirs.Count -eq 0) { return }

    Write-Host "  consultando nodejs.org..." -ForegroundColor DarkGray
    $lts = @(Get-NodeLtsReleases)

    foreach ($d in $dirs) {
        $null = $d.Name -match '^node-(\d+)$'
        $major = [int]$Matches[1]
        $instalada = Get-VersionDe -Exe (Join-Path $d.FullName "node.exe") -Patron 'v?(\d+\.\d+\.\d+)'
        if (-not $instalada) { continue }

        # Se compara contra la ultima de SU MISMA linea: saltar de major es una
        # decision distinta, no una actualizacion.
        $suLinea = @($lts | Where-Object { $_.Major -eq $major })
        $disponible = if ($suLinea.Count -gt 0) { $suLinea[0].Version } elseif ($lts.Count -eq 0) { $null } else { $instalada }

        # El comando lleva la version CONCRETA, no un marcador: la gracia de esta
        # pantalla es poder copiar y pegar la linea tal cual.
        $cmd = if ($disponible) { ".\bin\setup\Setup-NodeEnv.bat -NodeVersion $disponible -Force" }
               else             { ".\bin\setup\Setup-NodeEnv.bat -Force" }

        Add-Fila -Que "Node $major (suelto)" -Instalado $instalada -Disponible $disponible -Comando $cmd
    }
}

function Test-GitUpdates {
    if (-not (Test-Path $GitRoot)) { return }

    $dirs = @(Get-ChildItem $GitRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^git-(\d+\.\d+)$' })
    if ($dirs.Count -eq 0) { return }

    Write-Host "  consultando las releases de Git for Windows..." -ForegroundColor DarkGray
    $ultima = Get-GitPortableRelease

    foreach ($d in $dirs) {
        $null = $d.Name -match '^git-(\d+\.\d+)$'
        $linea = $Matches[1]

        # ConvertFrom-GitVersionOutput y no un patron propio: es la version tal
        # como se llama el archivo publicado ("2.55.0.5"), que es lo que espera
        # -GitVersion y lo que se compara mas abajo.
        $bruta = Get-VersionDe -Exe (Join-Path $d.FullName "cmd\git.exe") -Patron '(git version .+)'
        $instalada = ConvertFrom-GitVersionOutput -Output $bruta
        if (-not $instalada) { continue }

        # A diferencia de Node o Python, aqui NO se filtra por linea: Git no
        # mantiene ramas en paralelo, solo avanza. La 2.56 es la sucesora de la
        # 2.55, no una linea distinta que haya que elegir aparte.
        $disponible = if ($ultima) { $ultima.Version } else { $null }

        $cmd = if ($disponible) { ".\bin\setup\Setup-GitEnv.bat -GitVersion $disponible -Force" }
               else             { ".\bin\setup\Setup-GitEnv.bat -Force" }

        Add-Fila -Que "Git $linea" -Instalado $instalada -Disponible $disponible -Comando $cmd
    }
}

function Test-BuildToolUpdates {
    <#
        Maven y Gradle comparten forma: carpeta por linea, version leida de un
        jar, y una sola version "actual" publicada rio arriba. Igual que Git y a
        diferencia de Node o Python, no se filtra por linea: no mantienen ramas
        en paralelo, solo avanzan.
    #>
    param(
        [string]$Titulo, [string]$Root, [string]$Prefijo,
        [string]$JarGlob, [string]$JarRegex,
        [scriptblock]$Consultar, [string]$SetupBat, [string]$Parametro
    )

    if (-not (Test-Path $Root)) { return }

    $dirs = @(Get-ChildItem $Root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "^$Prefijo-(\d+\.\d+)$" })
    if ($dirs.Count -eq 0) { return }

    Write-Host "  consultando la version actual de $Titulo..." -ForegroundColor DarkGray
    $ultima = & $Consultar

    foreach ($d in $dirs) {
        $null = $d.Name -match "^$Prefijo-(\d+\.\d+)$"
        $linea = $Matches[1]

        $instalada = $null
        $jar = @(Get-ChildItem -Path (Join-Path $d.FullName $JarGlob) -ErrorAction SilentlyContinue)
        if ($jar.Count -gt 0 -and $jar[0].Name -match $JarRegex) { $instalada = $Matches[1] }
        if (-not $instalada) { continue }

        $disponible = if ($ultima) { $ultima.Version } else { $null }
        $cmd = if ($disponible) { "$SetupBat $Parametro $disponible -Force" } else { "$SetupBat -Force" }

        Add-Fila -Que "$Titulo $linea" -Instalado $instalada -Disponible $disponible -Comando $cmd
    }
}

function Test-DotnetUpdates {
    if (-not (Test-Path $DotnetRoot)) { return }

    $dirs = @(Get-ChildItem $DotnetRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^dotnet-(\d+\.\d+)$' })
    if ($dirs.Count -eq 0) { return }

    Write-Host "  consultando los canales de .NET..." -ForegroundColor DarkGray

    foreach ($d in $dirs) {
        $null = $d.Name -match '^dotnet-(\d+\.\d+)$'
        $canal = $Matches[1]

        $sdks = @(Get-ChildItem -LiteralPath (Join-Path $d.FullName "sdk") -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -match '^\d+\.\d+\.\d+' })
        if ($sdks.Count -eq 0) { continue }
        $instalada = @($sdks | Sort-Object Name -Descending)[0].Name

        # Se compara contra SU MISMO canal: saltar de canal es una decision
        # distinta, no una actualizacion.
        $rel = Get-DotnetRelease -Channel $canal
        $disponible = if ($rel) { $rel.SdkVersion } else { $null }

        Add-Fila -Que ".NET $canal" -Instalado $instalada -Disponible $disponible `
                 -Comando ".\bin\setup\Setup-DotnetEnv.bat -Channel $canal -Force"
    }
}

function Test-VSCodeUpdates {
    if (-not (Test-Path $VSCodeRoot)) { return }

    $dirs = @(Get-ChildItem $VSCodeRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^vscode-(\d+\.\d+)$' })
    if ($dirs.Count -eq 0) { return }

    Write-Host "  consultando la version estable de VS Code..." -ForegroundColor DarkGray
    $ultima = Get-VSCodeRelease

    foreach ($d in $dirs) {
        $null = $d.Name -match '^vscode-(\d+\.\d+)$'
        $linea = $Matches[1]

        $exe = Join-Path $d.FullName "Code.exe"
        if (-not (Test-Path $exe)) { continue }
        $instalada = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
        if ($instalada -match '(\d+\.\d+\.\d+)') { $instalada = $Matches[1] }

        $disponible = if ($ultima) { $ultima.Version } else { $null }

        # -KeepData en el comando sugerido: sin el, actualizar borraria los
        # ajustes y las extensiones del usuario.
        Add-Fila -Que "VS Code $linea" -Instalado $instalada -Disponible $disponible `
                 -Comando ".\bin\setup\Setup-VSCodeEnv.bat -Force -KeepData"
    }
}

function Test-AngularUpdates {
    if (-not (Test-Path $AngularRoot)) { return }

    foreach ($d in (Get-ChildItem $AngularRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -notmatch '^angular-v(\d+)$') { continue }
        $major = [int]$Matches[1]

        $pkg = Join-Path $d.FullName "npm-global\node_modules\@angular\cli\package.json"
        $instalada = $null
        if (Test-Path $pkg) {
            try { $instalada = (Get-Content $pkg -Raw | ConvertFrom-Json).version } catch { }
        }
        if (-not $instalada) { continue }

        Write-Host "  consultando registry.npmjs.org (v$major)..." -ForegroundColor DarkGray
        $ultima = Get-LatestAngularCliVersion -Major $major

        Add-Fila -Que "Angular CLI $major" -Instalado $instalada `
                 -Disponible $(if ([string]::IsNullOrEmpty($ultima)) { $null } else { $ultima }) `
                 -Comando ".\bin\setup\Setup-AngularEnv.bat -AngularVersion $major"
    }

    # La Node que Angular instala para si mismo, que es distinta de la suelta.
    foreach ($d in (Get-ChildItem $AngularRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -notmatch '^node-v(\d+)\.') { continue }
        $major = [int]$Matches[1]
        $instalada = Get-VersionDe -Exe (Join-Path $d.FullName "node.exe") -Patron 'v?(\d+\.\d+\.\d+)'
        if (-not $instalada) { continue }

        $lts = @(Get-NodeLtsReleases | Where-Object { $_.Major -eq $major })
        $disponible = if ($lts.Count -gt 0) { $lts[0].Version } else { $null }

        Add-Fila -Que "Node $major (de Angular)" -Instalado $instalada -Disponible $disponible `
                 -Comando "la elige el CLI: .\bin\setup\Setup-AngularEnv.bat -AngularVersion <n>"
    }
}

# --------------------------------------------------------------------------

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Update-Env - Actualizaciones disponibles" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

if (Test-RuntimeSelected -Name 'Python'  -Selected $Runtime) { Test-PythonUpdates }
if (Test-RuntimeSelected -Name 'Java'    -Selected $Runtime) { Test-JavaUpdates }
if (Test-RuntimeSelected -Name 'Node'    -Selected $Runtime) { Test-NodeUpdates }
if (Test-RuntimeSelected -Name 'Git'     -Selected $Runtime) { Test-GitUpdates }
if (Test-RuntimeSelected -Name 'Maven'   -Selected $Runtime) {
    Test-BuildToolUpdates -Titulo 'Maven' -Root $MavenRoot -Prefijo 'maven' `
                          -JarGlob 'lib\maven-core-*.jar' -JarRegex 'maven-core-([\d.]+)\.jar' `
                          -Consultar { Get-MavenRelease } `
                          -SetupBat '.\bin\setup\Setup-MavenEnv.bat' -Parametro '-MavenVersion'
}
if (Test-RuntimeSelected -Name 'Gradle'  -Selected $Runtime) {
    Test-BuildToolUpdates -Titulo 'Gradle' -Root $GradleRoot -Prefijo 'gradle' `
                          -JarGlob 'lib\gradle-launcher-*.jar' -JarRegex 'gradle-launcher-([\d.]+)\.jar' `
                          -Consultar { Get-GradleRelease } `
                          -SetupBat '.\bin\setup\Setup-GradleEnv.bat' -Parametro '-GradleVersion'
}
if (Test-RuntimeSelected -Name 'Dotnet'  -Selected $Runtime) { Test-DotnetUpdates }
if (Test-RuntimeSelected -Name 'VSCode'  -Selected $Runtime) { Test-VSCodeUpdates }
if (Test-RuntimeSelected -Name 'Angular' -Selected $Runtime) { Test-AngularUpdates }

Write-Host ""

if ($script:Filas.Count -eq 0) {
    Write-Host "No hay nada instalado por el kit$(if ($Runtime) { " de $Runtime" })." -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

$anchoQue = ([int](($script:Filas | ForEach-Object { $_.Que.Length } | Measure-Object -Maximum).Maximum)) + 2
Write-Host ("  {0}{1,-16}{2,-16}" -f "Runtime".PadRight($anchoQue), "Instalado", "Disponible") -ForegroundColor Gray
Write-Host ("  " + ("-" * ($anchoQue + 32 + 14))) -ForegroundColor DarkGray

foreach ($f in $script:Filas) {
    $color = switch ($f.Estado) {
        'actualizable' { 'Yellow' }
        'al dia'       { 'Green' }
        default        { 'DarkGray' }
    }
    Write-Host ("  {0}{1,-16}{2,-16}{3}" -f $f.Que.PadRight($anchoQue), $f.Instalado, $f.Disponible, $f.Estado) -ForegroundColor $color
}

$actualizables = @($script:Filas | Where-Object { $_.Estado -eq 'actualizable' })

Write-Host ""
if ($script:SinRed) {
    Write-Host "Algunas no se pudieron comprobar: revisa la red o el proxy con .\bin\kit\Doctor-Env.bat" -ForegroundColor DarkGray
    Write-Host ""
}

if ($actualizables.Count -eq 0) {
    Write-Host "Todo al dia." -ForegroundColor Green
    Write-Host ""
    exit 0
}

Write-Host "Para actualizar:" -ForegroundColor Yellow
foreach ($f in $actualizables) {
    Write-Host ("  {0,-24} {1}" -f $f.Que, $f.Comando)
}
Write-Host ""

# --------------------------------------------------------------------------
# -Apply
# --------------------------------------------------------------------------

$conPip = @($actualizables | Where-Object { $_.Que -like 'Python *' })

if (-not $Apply) {
    Write-Host "Ojo: -Force reinstala desde cero. En Python eso borra los paquetes pip" -ForegroundColor DarkGray
    Write-Host "de esa version; anotalos antes con  pip freeze > requirements.txt" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Para aplicarlas:  .\bin\env\Update-Env.bat -Apply" -ForegroundColor Cyan
    Write-Host ""

    # Codigo 1 = hay algo que actualizar, para poder encadenarlo. Mismo criterio
    # que Doctor, que sale con 1 cuando encuentra algo que mirar.
    exit 1
}

# Una fila actualizable cuyo comando no se pudo resolver no se ejecuta a medias:
# se para todo. Ejecutar la mitad de una tanda deja el entorno en un estado que
# nadie pidio y que ademas no se ve.
$sinResolver = @($actualizables | Where-Object { -not $_.Bat })
if ($sinResolver.Count -gt 0) {
    Write-Host "No se encuentra el comando de:" -ForegroundColor Red
    foreach ($f in $sinResolver) { Write-Host "  $($f.Que) -> $($f.Comando)" -ForegroundColor Red }
    Write-Host ""
    Write-Host "No se aplica nada. Revisa la instalacion del kit con .\bin\kit\Doctor-Env.bat" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

if (-not $Force) {
    Write-Host "Se van a reinstalar desde cero $($actualizables.Count) runtime(s)." -ForegroundColor Yellow

    # El aviso de pip, donde de verdad se lee: justo antes de decidir, y
    # nombrando que versiones perderian sus paquetes. Enterrado al final de la
    # lista no lo leia nadie.
    if ($conPip.Count -gt 0) {
        Write-Host ""
        Write-Host "OJO: reinstalar Python BORRA sus paquetes pip. Afecta a:" -ForegroundColor Yellow
        foreach ($f in $conPip) { Write-Host "  $($f.Que)" -ForegroundColor Yellow }
        Write-Host "Anotalos antes, desde su shell:  pip freeze > requirements.txt" -ForegroundColor Gray
    }

    Write-Host ""
    $respuesta = Read-Host "Confirmas? (escribe SI)"
    if ($respuesta -ne 'SI') {
        Write-Host "Cancelado. No se ha tocado nada." -ForegroundColor Yellow
        Write-Host ""
        exit 0
    }
}

# Los .bat del kit hacen pause al terminar, y aqui van varios seguidos: sin
# esto habria que pulsar una tecla entre cada uno. Se restaura al salir para no
# cambiarle el entorno a quien nos llamo.
$pausePrevio = $env:CRIISDEVKIT_NOPAUSE
$env:CRIISDEVKIT_NOPAUSE = "1"

$hechas = 0
$fallidas = @()

try {
    foreach ($f in $actualizables) {
        Write-Host ""
        Write-Host "============================================" -ForegroundColor Cyan
        Write-Host "  $($f.Que): $($f.Instalado) -> $($f.Disponible)" -ForegroundColor Cyan
        Write-Host "============================================" -ForegroundColor Cyan
        Write-Host "  > $($f.Comando)" -ForegroundColor DarkGray
        Write-Host ""

        & $f.Bat @($f.Argumentos)

        if ($LASTEXITCODE -eq 0) {
            $hechas++
        }
        else {
            # No se corta la tanda: que falle el JDK no es razon para no
            # actualizar Maven. Se apunta y se dice todo junto al final.
            $fallidas += $f
            Write-Host ""
            Write-Host "  $($f.Que) fallo (codigo $LASTEXITCODE). Se sigue con el resto." -ForegroundColor Red
        }
    }
}
finally {
    $env:CRIISDEVKIT_NOPAUSE = $pausePrevio
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  $hechas actualizada(s), $($fallidas.Count) con error" -ForegroundColor $(if ($fallidas.Count -eq 0) { 'Green' } else { 'Red' })
Write-Host "============================================" -ForegroundColor Cyan

if ($fallidas.Count -gt 0) {
    Write-Host ""
    Write-Host "Con error:" -ForegroundColor Red
    foreach ($f in $fallidas) { Write-Host "  $($f.Que) -> $($f.Comando)" -ForegroundColor Red }
}

Write-Host ""
Write-Host "Comprueba como quedo:  .\bin\env\Verify-Env.bat" -ForegroundColor Gray
Write-Host ""

if ($fallidas.Count -gt 0) { exit 1 }
exit 0
