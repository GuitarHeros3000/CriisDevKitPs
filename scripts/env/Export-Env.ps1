#Requires -Version 5.1
<#
.SYNOPSIS
    Export-Env.ps1 - Empaqueta el entorno instalado para llevarlo a otra maquina.
.DESCRIPTION
    Genera un .zip con un manifiesto (env.json) y todo lo necesario para
    reproducir el entorno SIN internet en la maquina destino.

    Esto existe porque el kit depende de seis dominios (nodejs.org,
    registry.npmjs.org, python.org, pypi.org, api.adoptium.net y github.com).
    En una laptop corporativa basta con que bloqueen uno para que ese runtime
    sea inalcanzable. Con el bundle se pasa por USB y se instala en local.

    Que lleva dentro:
      - runtimes\  : los zip originales de Node, Python y el JDK, con su checksum.
      - npm-global\: el arbol del Angular CLI ya instalado, para no depender
                     del registro de npm en destino.
      - wheels\    : los paquetes pip descargados como .whl.
.PARAMETER Output
    Ruta del .zip a generar. Por defecto: entorno-<fecha>.zip junto al kit.
.PARAMETER Runtime
    Exporta solo un runtime (Angular, Python o Java). Por defecto, todos.
.PARAMETER SkipBinaries
    Genera solo el manifiesto, sin descargar los binarios. El .zip pesa unos KB
    pero la maquina destino necesitara internet.
.EXAMPLE
    .\Export-Env.ps1
.EXAMPLE
    .\Export-Env.ps1 -Output D:\usb\mi-entorno.zip
.EXAMPLE
    .\Export-Env.ps1 -Runtime Python -SkipBinaries
#>

param(
    [string]$Output,

    [ValidateSet('Angular', 'Python', 'Java', 'Node', 'Git', 'Maven', 'Gradle', 'Dotnet', 'VSCode')]
    [string]$Runtime,

    [switch]$SkipBinaries,

    # No metas la CA de la empresa en el bundle.
    [switch]$SkipCert
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Common.ps1")

$AngularRoot = Join-Path $WorkspaceRoot "Angular"
$PythonRoot  = Join-Path $WorkspaceRoot "Python"
$JavaRoot    = Join-Path $WorkspaceRoot "Java"

# 2 porque el manifiesto lleva ahora la seccion "otros", con los seis runtimes
# que antes se quedaban fuera. Un Import viejo debe RECHAZAR un bundle nuevo en
# vez de importarlo a medias sin decir nada.
$ManifestVersion = 2

if ([string]::IsNullOrWhiteSpace($Output)) {
    $Output = Join-Path $DevKitRoot ("entorno-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".zip")
}


# --------------------------------------------------------------------------
# Deteccion de lo instalado
# --------------------------------------------------------------------------

function Get-AngularEntries {
    if (-not (Test-Path $AngularRoot)) { return @() }

    $entries = @()
    foreach ($dir in (Get-ChildItem $AngularRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($dir.Name -notmatch '^angular-v(\d+)$') { continue }
        $version = $Matches[1]

        # La version de Node se deduce del shell generado: es la unica fuente
        # que sabe con cual se instalo realmente esa version de Angular.
        $shell = Join-Path $dir.FullName "shell-v$version.bat"
        $node = $null
        if (Test-Path $shell) {
            foreach ($line in (Get-Content $shell)) {
                if ($line -match 'node-v([\d\.]+)-win-x64') { $node = $Matches[1]; break }
            }
        }

        if (-not $node) {
            Write-Log "Angular v${version}: no se pudo deducir su Node; se omite" "WARN"
            continue
        }

        $cliVersion = $null
        $pkg = Join-Path $dir.FullName "npm-global\node_modules\@angular\cli\package.json"
        if (Test-Path $pkg) {
            try { $cliVersion = (Get-Content $pkg -Raw | ConvertFrom-Json).version } catch { }
        }

        $entries += [PSCustomObject]@{
            Version    = $version
            Node       = $node
            CliVersion = $cliVersion
            NpmGlobal  = (Join-Path $dir.FullName "npm-global")
        }
    }
    return $entries
}

function Get-PythonEntries {
    if (-not (Test-Path $PythonRoot)) { return @() }

    $entries = @()
    foreach ($dir in (Get-ChildItem $PythonRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($dir.Name -notmatch '^python-(\d+\.\d+)$') { continue }
        $minor = $Matches[1]

        $exe = Join-Path $dir.FullName "python.exe"
        if (-not (Test-Path $exe)) { continue }

        $full = $null
        $probe = Invoke-NativeCommand -FilePath $exe -Arguments @('--version') -Quiet
        if ($probe.ExitCode -eq 0 -and $probe.Output -match '(\d+\.\d+\.\d+)') { $full = $Matches[1] }
        if (-not $full) {
            Write-Log "Python ${minor}: el interprete no responde; se omite" "WARN"
            continue
        }

        # pip freeze da las versiones exactas, que es lo que hace reproducible
        # el entorno en destino.
        $packages = @()
        $frozen = Invoke-NativeCommand -FilePath $exe -Arguments @('-m', 'pip', 'freeze', '--disable-pip-version-check') -Quiet
        if ($frozen.ExitCode -eq 0) {
            $packages = @($frozen.Output -split "`r?`n" |
                Where-Object { $_.Trim() -ne '' -and $_ -notmatch '^\s*#' -and $_ -notlike '*@*file:*' })
        }

        $entries += [PSCustomObject]@{
            Version  = $minor
            Full     = $full
            Packages = $packages
            Exe      = $exe
        }
    }
    return $entries
}

function Get-JavaEntries {
    if (-not (Test-Path $JavaRoot)) { return @() }

    $entries = @()
    foreach ($dir in (Get-ChildItem $JavaRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($dir.Name -notmatch '^jdk-(\d+)$') { continue }
        $major = [int]$Matches[1]

        $marker = Join-Path $dir.FullName ".assassinskipadm-release"
        $release = if (Test-Path $marker) { (Get-Content $marker -Raw).Trim() } else { $null }

        $entries += [PSCustomObject]@{
            Version = $major
            Release = $release
        }
    }
    return $entries
}

# --------------------------------------------------------------------------
# Recoleccion de binarios
# --------------------------------------------------------------------------

function Save-RuntimeArchive {
    <#
        Vuelve a descargar el archivo original del runtime. Los setups lo borran
        tras extraerlo, asi que aqui hay que traerlo de nuevo. Devuelve el
        nombre del archivo dentro del bundle y su sha256, o $null si fallo.
    #>
    param(
        [string]$Url,
        [string]$FileName,
        [string]$Sha256,
        [string]$DestDir,
        [string]$Label
    )

    $dest = Join-Path $DestDir $FileName
    if (Test-Path $dest) {
        Write-Log "  ya estaba en el bundle: $FileName"
        return [PSCustomObject]@{ File = $FileName; Sha256 = (Get-FileSha256 -FilePath $dest) }
    }

    Write-Log "  descargando $Label..."
    if (-not (Invoke-Download -Uri $Url -OutFile $dest -Sha256 $Sha256 -Description $Label)) {
        return $null
    }

    return [PSCustomObject]@{ File = $FileName; Sha256 = (Get-FileSha256 -FilePath $dest) }
}

# --------------------------------------------------------------------------

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Export-Env - Bundle portable del entorno" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

$angular = @(if (Test-RuntimeSelected -Name 'Angular' -Selected $Runtime) { Get-AngularEntries })
$python  = @(if (Test-RuntimeSelected -Name 'Python' -Selected $Runtime)  { Get-PythonEntries })
$java    = @(if (Test-RuntimeSelected -Name 'Java' -Selected $Runtime)    { Get-JavaEntries })

# Los demas runtimes salen del CATALOGO y no de una lista escrita a mano. Es lo
# que fallo antes: se anadieron seis runtimes al kit y este comando se quedo en
# tres, asi que el bundle "portable" ignoraba en silencio Git, Maven, Gradle,
# .NET y VS Code.
$otros = @()
foreach ($e in (Get-RuntimeCatalog | Where-Object { $_.Bundle })) {
    if (-not (Test-RuntimeSelected -Name $e.Carpeta -Selected $Runtime)) { continue }
    foreach ($linea in (Get-InstalledRuntimeLines -Entrada $e)) {
        $exacta = Get-InstalledRuntimeVersion -Entrada $e -Linea $linea
        if (-not $exacta) {
            Write-Log "$($e.Nombre) $linea : no se pudo leer su version; se omite" "WARN"
            continue
        }
        $otros += [PSCustomObject]@{ Entrada = $e; Linea = $linea; Version = $exacta }
    }
}

if ($angular.Count -eq 0 -and $python.Count -eq 0 -and $java.Count -eq 0 -and $otros.Count -eq 0) {
    Write-Log "No hay nada instalado que exportar." "WARN"
    Write-Log "  Instala algo primero, o revisa con  .\bin\kit\Doctor-Env.bat" "WARN"
    exit 0
}

Write-Host "Se va a exportar:" -ForegroundColor Yellow
foreach ($a in $angular) { Write-Host "  Angular v$($a.Version)  (CLI $($a.CliVersion), Node $($a.Node))" }
foreach ($p in $python)  { Write-Host "  Python $($p.Full)  ($($p.Packages.Count) paquetes pip)" }
foreach ($j in $java)    { Write-Host "  Java $($j.Version)  ($($j.Release))" }
foreach ($o in $otros)   { Write-Host "  $($o.Entrada.Nombre) $($o.Version)" }
Write-Host ""

# --- Carpeta temporal donde se arma el bundle ---
$staging = Join-Path $env:TEMP ("assassinskipadm-export-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $staging -Force | Out-Null

try {
    $runtimesDir = Join-Path $staging "runtimes"
    $wheelsDir   = Join-Path $staging "wheels"
    $npmDir      = Join-Path $staging "npm-global"

    $manifest = [ordered]@{
        manifestVersion = $ManifestVersion
        kitVersion      = $KitVersion
        created         = (Get-Date -Format "o")
        createdOn       = $env:COMPUTERNAME
        includesBinaries = (-not $SkipBinaries)
        angular         = @()
        python          = @()
        java            = @()
        otros           = @()
    }

    # --- La CA de la empresa ---
    #
    # Viaja con el bundle a proposito: el segundo equipo suele ser de la MISMA
    # empresa, con el mismo proxy inspeccionando, y sin esto habria que volver a
    # pedirsela a IT para que Maven, pip o git funcionen alli.
    #
    # No es un secreto -es el certificado publico que la empresa presenta a todo
    # el que navega- pero identifica a la empresa, asi que se dice en voz alta y
    # se puede dejar fuera con -SkipCert.
    if ((Test-Path -LiteralPath $CorpCaFile) -and -not $SkipCert) {
        Copy-Item -LiteralPath $CorpCaFile -Destination (Join-Path $staging "corp-ca.cer") -Force
        $x = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CorpCaFile)
        $manifest.corpCa = [ordered]@{
            archivo = "corp-ca.cer"
            emisor  = $x.Subject
            huella  = $x.Thumbprint
            caduca  = $x.NotAfter.ToString('yyyy-MM-dd')
        }
        Write-Log "CA de la empresa incluida: $($x.Subject)" "WARN"
        Write-Log "  Identifica a tu empresa. Para dejarla fuera:  -SkipCert" "WARN"
    }

    # --- Angular ---
    foreach ($a in $angular) {
        Write-Log "Angular v$($a.Version)..."
        $entry = [ordered]@{
            version    = $a.Version
            node       = $a.Node
            cliVersion = $a.CliVersion
        }

        if (-not $SkipBinaries) {
            New-Item -ItemType Directory -Path $runtimesDir -Force | Out-Null
            $info = Get-NodeArchiveInfo -Version $a.Node
            $sha = Get-Sha256FromShasums -Uri $info.ShasumsUrl -FileName $info.FileName
            $saved = Save-RuntimeArchive -Url $info.Url -FileName $info.FileName -Sha256 $sha `
                                         -DestDir $runtimesDir -Label "Node v$($a.Node)"
            if (-not $saved) {
                Write-Log "  no se pudo traer Node v$($a.Node); se omite Angular v$($a.Version)" "ERROR"
                continue
            }
            $entry.nodeArchive = "runtimes/$($saved.File)"
            $entry.nodeSha256  = $saved.Sha256

            # El arbol de npm-global evita depender del registro de npm en destino.
            # Los shims que genera npm usan rutas relativas (%~dp0), asi que
            # sobreviven al cambio de carpeta.
            if (Test-Path $a.NpmGlobal) {
                $target = Join-Path $npmDir "angular-v$($a.Version)"
                New-Item -ItemType Directory -Path $target -Force | Out-Null
                Write-Log "  copiando el Angular CLI ya instalado..."
                Copy-Item -Path (Join-Path $a.NpmGlobal '*') -Destination $target -Recurse -Force
                $entry.npmGlobal = "npm-global/angular-v$($a.Version)"
            }
        }

        $manifest.angular += $entry
    }

    # --- Python ---
    foreach ($p in $python) {
        Write-Log "Python $($p.Full)..."
        $entry = [ordered]@{
            version  = $p.Version
            full     = $p.Full
            packages = $p.Packages
        }

        if (-not $SkipBinaries) {
            New-Item -ItemType Directory -Path $runtimesDir -Force | Out-Null
            $info = Get-PythonArchiveInfo -FullVersion $p.Full
            $saved = Save-RuntimeArchive -Url $info.Url -FileName $info.FileName -Sha256 $null `
                                         -DestDir $runtimesDir -Label "Python $($p.Full)"
            if (-not $saved) {
                Write-Log "  no se pudo traer Python $($p.Full); se omite" "ERROR"
                continue
            }
            $entry.archive = "runtimes/$($saved.File)"
            $entry.sha256  = $saved.Sha256

            if ($p.Packages.Count -gt 0) {
                $target = Join-Path $wheelsDir "python-$($p.Version)"
                New-Item -ItemType Directory -Path $target -Force | Out-Null

                $req = Join-Path $target "requirements.txt"
                Set-Content -LiteralPath $req -Value $p.Packages -Encoding ASCII

                Write-Log "  descargando $($p.Packages.Count) paquetes como .whl..."
                $dl = Invoke-NativeCommand -FilePath $p.Exe -Arguments @(
                    '-m', 'pip', 'download', '-r', $req, '-d', $target,
                    '--disable-pip-version-check'
                )

                # El Python embeddable no trae pip, y "pip freeze" nunca se lista
                # a si mismo. Para instalarlo sin red hacen falta LAS DOS COSAS:
                #   - get-pip.py : arranca un pip temporal con el que ejecutar
                #   - pip-*.whl  : el paquete que ese pip instalara
                # get-pip.py con --no-index NO instala el pip que lleva dentro:
                # lo busca en --find-links, asi que sin el wheel falla.
                $getPip = Join-Path $target "get-pip.py"
                $gotPip = Invoke-Download -Uri "https://bootstrap.pypa.io/get-pip.py" `
                                          -OutFile $getPip -Description "get-pip.py"

                $dlPip = Invoke-NativeCommand -FilePath $p.Exe -Arguments @(
                    '-m', 'pip', 'download', 'pip', '-d', $target,
                    '--disable-pip-version-check'
                ) -Quiet

                if ($dl.ExitCode -eq 0 -and $gotPip -and $dlPip.ExitCode -eq 0) {
                    $entry.wheels = "wheels/python-$($p.Version)"
                    Write-Log "  incluidos get-pip.py y el wheel de pip" "SUCCESS"
                }
                else {
                    Write-Log "  pip download fallo; el destino necesitara acceso a pypi.org" "WARN"
                    Remove-Item $target -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }

        $manifest.python += $entry
    }

    # --- Java ---
    foreach ($j in $java) {
        Write-Log "Java $($j.Version)..."
        $entry = [ordered]@{
            version = $j.Version
            release = $j.Release
        }

        if (-not $SkipBinaries) {
            New-Item -ItemType Directory -Path $runtimesDir -Force | Out-Null
            $info = Get-JavaArchiveInfo -Major $j.Version
            if (-not $info) {
                Write-Log "  Adoptium no respondio; se omite Java $($j.Version)" "ERROR"
                continue
            }
            $saved = Save-RuntimeArchive -Url $info.Url -FileName $info.FileName -Sha256 $info.Sha256 `
                                         -DestDir $runtimesDir -Label "JDK $($info.Release)"
            if (-not $saved) { continue }

            $entry.archive = "runtimes/$($saved.File)"
            $entry.sha256  = $saved.Sha256
            $entry.release = $info.Release
        }

        $manifest.java += $entry
    }

    # --- Los seis que van por el catalogo ---
    #
    # Todos comparten forma: un archivo que se vuelve a descargar y que en
    # destino se extrae segun sus metadatos (con envoltorio, plano, o
    # autoextraible). No hay nada por runtime aqui, y esa es la idea: el
    # proximo entra solo con anadirlo al catalogo.
    foreach ($o in $otros) {
        $e = $o.Entrada
        Write-Log "$($e.Nombre) $($o.Version)..."

        $entry = [ordered]@{
            clave   = $e.Clave
            linea   = $o.Linea
            version = $o.Version
        }

        if (-not $SkipBinaries) {
            New-Item -ItemType Directory -Path $runtimesDir -Force | Out-Null

            $info = Get-BundleArchiveInfo -Clave $e.Clave -Version $o.Version
            if (-not $info) {
                Write-Log "  no se pudo resolver su descarga; se omite" "ERROR"
                continue
            }

            $saved = Save-RuntimeArchive -Url $info.Url -FileName $info.FileName -Sha256 $info.Sha256 `
                                         -DestDir $runtimesDir -Label "$($e.Nombre) $($o.Version)"
            if (-not $saved) {
                Write-Log "  no se pudo traer el archivo; se omite" "ERROR"
                continue
            }

            $entry.archive = "runtimes/$($saved.File)"
            $entry.sha256  = $saved.Sha256
        }

        $manifest.otros += $entry
    }

    # --- Manifiesto ---
    $manifestPath = Join-Path $staging "env.json"
    ($manifest | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    # --- Empaquetado ---
    Write-Log ""
    Write-Log "Comprimiendo..."
    if (Test-Path -LiteralPath $Output) { Remove-Item -LiteralPath $Output -Force }

    $outDir = Split-Path -Parent $Output
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($staging, $Output)

    $sizeMb = [math]::Round((Get-Item $Output).Length / 1MB, 1)

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "  BUNDLE CREADO" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  $Output" -ForegroundColor White
    Write-Host "  $sizeMb MB" -ForegroundColor Gray
    Write-Host ""
    if ($SkipBinaries) {
        Write-Host "Solo manifiesto: la maquina destino necesitara internet." -ForegroundColor Yellow
    }
    else {
        Write-Host "Instalalo en la otra maquina con:" -ForegroundColor Yellow
        Write-Host "  .\bin\env\Import-Env.bat -Path <ruta del zip>" -ForegroundColor White
    }
    Write-Host ""
}
finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}
