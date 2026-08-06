#Requires -Version 5.1
<#
.SYNOPSIS
    Import-Env.ps1 - Reproduce un entorno desde un bundle, sin internet.
.DESCRIPTION
    Instala lo que describe el env.json de un bundle generado por Export-Env,
    usando los binarios que el propio bundle lleva dentro. Verifica el SHA-256
    de cada archivo antes de extraerlo.

    Los shells (.bat) y las entradas de PATH se regeneran con las rutas de ESTA
    maquina: dentro del bundle van rutas absolutas de la maquina de origen, que
    aqui no valdrian.
.PARAMETER Path
    Ruta del .zip generado por Export-Env.
.PARAMETER Runtime
    Importa solo un runtime (Angular, Python o Java). Por defecto, todos.
.PARAMETER WhatIf
    Muestra que haria sin instalar nada.
.PARAMETER Force
    No pide confirmacion.
.EXAMPLE
    .\Import-Env.ps1 -Path D:\usb\mi-entorno.zip -WhatIf
.EXAMPLE
    .\Import-Env.ps1 -Path D:\usb\mi-entorno.zip
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Path,

    [ValidateSet('Angular', 'Python', 'Java')]
    [string]$Runtime,

    [switch]$WhatIf,

    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

$AngularRoot = Join-Path $WorkspaceRoot "Angular"
$PythonRoot  = Join-Path $WorkspaceRoot "Python"
$JavaRoot    = Join-Path $WorkspaceRoot "Java"

$SupportedManifest = 1


function Expand-BundleArchive {
    <#
        Extrae un archivo del bundle verificando su checksum antes. Si el
        bundle viajo en un USB y se corrompio, es mejor enterarse aqui que
        con un runtime a medias.
    #>
    param(
        [string]$BundleDir,
        [string]$RelativePath,
        [string]$Sha256,
        [string]$DestDir,
        [string]$Label
    )

    $archive = Join-Path $BundleDir ($RelativePath -replace '/', '\')
    if (-not (Test-Path -LiteralPath $archive)) {
        Write-Log "El bundle no contiene $RelativePath" "ERROR"
        return $false
    }

    if ($Sha256) {
        $actual = Get-FileSha256 -FilePath $archive
        if ($actual -ne $Sha256.ToLowerInvariant()) {
            Write-Log "$Label : el archivo del bundle no coincide con su checksum" "ERROR"
            Write-Log "  esperado: $($Sha256.ToLowerInvariant())" "ERROR"
            Write-Log "  obtenido: $actual" "ERROR"
            return $false
        }
        Write-Log "  SHA-256 verificado" "SUCCESS"
    }

    if (-not (Test-ZipIntegrity -ZipPath $archive)) {
        Write-Log "$Label : el zip del bundle esta danado" "ERROR"
        return $false
    }

    if (-not (Test-Path -LiteralPath $DestDir)) {
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    }
    Expand-Archive -Path $archive -DestinationPath $DestDir -Force
    return $true
}

# --------------------------------------------------------------------------

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Import-Env - Instalar desde un bundle" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Log "No existe el archivo: $Path" "ERROR"
    exit 1
}

$Path = (Resolve-Path -LiteralPath $Path).Path

if (-not (Test-ZipIntegrity -ZipPath $Path)) {
    Write-Log "El bundle esta danado o no es un zip valido." "ERROR"
    exit 1
}

$bundleDir = Join-Path $env:TEMP ("assassinskipadm-import-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))

try {
    Write-Log "Abriendo el bundle..."
    Expand-Archive -Path $Path -DestinationPath $bundleDir -Force

    $manifestPath = Join-Path $bundleDir "env.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        Write-Log "El zip no lleva env.json: no es un bundle de Export-Env." "ERROR"
        exit 1
    }

    $m = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

    if ($m.manifestVersion -gt $SupportedManifest) {
        Write-Log "El bundle usa un formato mas nuevo (v$($m.manifestVersion)) que este kit (v$SupportedManifest)." "ERROR"
        Write-Log "  Actualiza el kit en esta maquina." "WARN"
        exit 1
    }

    Write-Host "Bundle creado el $($m.created)" -ForegroundColor Gray
    Write-Host "en la maquina '$($m.createdOn)'" -ForegroundColor Gray
    Write-Host ""

    $angular = @(if (Test-RuntimeSelected -Name 'Angular' -Selected $Runtime) { $m.angular })
    $python  = @(if (Test-RuntimeSelected -Name 'Python' -Selected $Runtime)  { $m.python })
    $java    = @(if (Test-RuntimeSelected -Name 'Java' -Selected $Runtime)    { $m.java })

    Write-Host "Se va a instalar:" -ForegroundColor Yellow
    foreach ($a in $angular) { Write-Host "  Angular v$($a.version)  (CLI $($a.cliVersion), Node $($a.node))" }
    foreach ($p in $python)  { Write-Host "  Python $($p.full)  ($(@($p.packages).Count) paquetes)" }
    foreach ($j in $java)    { Write-Host "  Java $($j.version)  ($($j.release))" }
    Write-Host ""
    Write-Host "Destino: $WorkspaceRoot" -ForegroundColor Yellow
    Write-Host ""

    if (-not $m.includesBinaries) {
        Write-Log "Este bundle es solo manifiesto: hara falta internet." "WARN"
        Write-Log "  Usa los Setup-*Env.bat normales con estas versiones." "WARN"
        exit 0
    }

    if ($WhatIf) {
        Write-Host "-WhatIf: no se ha instalado nada." -ForegroundColor Cyan
        Write-Host ""
        exit 0
    }

    if (-not $Force) {
        $answer = Read-Host "Confirmas? (escribe SI)"
        if ($answer -ne 'SI') {
            Write-Host "Cancelado." -ForegroundColor Yellow
            exit 0
        }
        Write-Host ""
    }

    $pathsToAdd = @()

    # --- Angular ---
    foreach ($a in $angular) {
        Write-Log "Instalando Angular v$($a.version)..."

        $nodeFolder = "node-v$($a.node)-win-x64"
        $nodePath = Join-Path $AngularRoot $nodeFolder

        if (Test-Path (Join-Path $nodePath "node.exe")) {
            Write-Log "  Node v$($a.node) ya estaba" "SUCCESS"
        }
        elseif (-not (Expand-BundleArchive -BundleDir $bundleDir -RelativePath $a.nodeArchive `
                                           -Sha256 $a.nodeSha256 -DestDir $AngularRoot -Label "Node v$($a.node)")) {
            Write-Log "  se omite Angular v$($a.version)" "ERROR"
            continue
        }

        $angularPath = Join-Path $AngularRoot "angular-v$($a.version)"
        New-Item -ItemType Directory -Path (Join-Path $angularPath "projects") -Force | Out-Null

        if ($a.npmGlobal) {
            $src = Join-Path $bundleDir ($a.npmGlobal -replace '/', '\')
            $dst = Join-Path $angularPath "npm-global"
            if (Test-Path $src) {
                New-Item -ItemType Directory -Path $dst -Force | Out-Null
                Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force
                Write-Log "  Angular CLI copiado del bundle (sin tocar npm)" "SUCCESS"
            }
        }

        Write-AngularShell -AngularPath $angularPath -NodePath $nodePath -Version $a.version -NodeVersion $a.node | Out-Null
        Write-Log "  shell regenerado con las rutas de esta maquina" "SUCCESS"
        $pathsToAdd += $nodePath
    }

    # --- Python ---
    foreach ($p in $python) {
        Write-Log "Instalando Python $($p.full)..."

        $pythonPath = Join-Path $PythonRoot "python-$($p.version)"

        if (Test-Path (Join-Path $pythonPath "python.exe")) {
            Write-Log "  ya existe python-$($p.version); se conserva" "WARN"
        }
        else {
            $temp = Join-Path $PythonRoot "temp_import"
            if (-not (Expand-BundleArchive -BundleDir $bundleDir -RelativePath $p.archive `
                                           -Sha256 $p.sha256 -DestDir $temp -Label "Python $($p.full)")) {
                continue
            }
            New-Item -ItemType Directory -Path $pythonPath -Force | Out-Null
            Move-Item -Path "$temp\*" -Destination $pythonPath -Force
            Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path (Join-Path $pythonPath "Scripts") -Force | Out-Null
        }

        # El embeddable necesita el ._pth parcheado o pip no importa nada.
        $tag = $p.version -replace '\.', ''
        $pth = Join-Path $pythonPath "python$tag._pth"
        if (Test-Path $pth) {
            $lines = Get-Content $pth
            $lines = $lines | ForEach-Object { $_ -replace '^\s*#\s*import site\s*$', 'import site' }
            if ($lines -notcontains 'Lib\site-packages') { $lines += 'Lib\site-packages' }
            if ($lines -notcontains 'import site') { $lines += 'import site' }
            Set-Content -Path $pth -Value $lines -Encoding ASCII
            Write-Log "  ._pth configurado" "SUCCESS"
        }

        $exe = Join-Path $pythonPath "python.exe"

        if ($p.wheels) {
            $wheelDir = Join-Path $bundleDir ($p.wheels -replace '/', '\')
            $req = Join-Path $wheelDir "requirements.txt"

            if (Test-Path $req) {
                # --no-index deja pip totalmente offline: solo mira la carpeta
                # de wheels del bundle.
                # El embeddable no trae pip. Un .whl es un zip con un __main__,
                # asi que Python puede ejecutarlo directamente: es la forma
                # estandar de arrancar pip sin tener pip ni red.
                $tienePip = (Invoke-NativeCommand -FilePath $exe -Arguments @('-m', 'pip', '--version') -Quiet).ExitCode -eq 0

                if (-not $tienePip) {
                    $getPip = Join-Path $wheelDir "get-pip.py"
                    if (-not (Test-Path -LiteralPath $getPip)) {
                        Write-Log "  el bundle no trae get-pip.py: no se puede instalar pip sin red" "ERROR"
                        Write-Log "  reexporta con una version del kit que lo incluya" "WARN"
                    }
                    else {
                        # --no-index deja a get-pip.py totalmente offline: usa el
                        # pip que lleva embebido y la carpeta de wheels del bundle.
                        Write-Log "  arrancando pip con get-pip.py del bundle..."
                        $boot = Invoke-NativeCommand -FilePath $exe -Arguments @(
                            $getPip, '--no-index', '--find-links', $wheelDir, '--no-warn-script-location'
                        ) -Quiet
                        $tienePip = ($boot.ExitCode -eq 0)
                        if ($tienePip) { Write-Log "  pip instalado sin red" "SUCCESS" }
                        else { Write-Log "  no se pudo arrancar pip" "ERROR" }
                    }
                }

                if ($tienePip) {
                    $run = Invoke-NativeCommand -FilePath $exe -Arguments @(
                        '-m', 'pip', 'install', '--no-index', '--find-links', $wheelDir,
                        '-r', $req, '--disable-pip-version-check', '--no-warn-script-location'
                    )
                    if ($run.ExitCode -eq 0) {
                        Write-Log "  paquetes instalados sin red" "SUCCESS"
                    }
                    else {
                        Write-Log "  fallo la instalacion offline de paquetes" "WARN"
                    }
                }
            }
        }

        Write-PythonShell -PythonPath $pythonPath -Version $p.version | Out-Null
        Write-Log "  shell regenerado con las rutas de esta maquina" "SUCCESS"
        $pathsToAdd += $pythonPath
        $pathsToAdd += (Join-Path $pythonPath "Scripts")
    }

    # --- Java ---
    foreach ($j in $java) {
        Write-Log "Instalando Java $($j.version)..."

        $jdkPath = Join-Path $JavaRoot "jdk-$($j.version)"

        if (Test-Path (Join-Path $jdkPath "bin\java.exe")) {
            Write-Log "  ya existe jdk-$($j.version); se conserva" "WARN"
        }
        else {
            $temp = Join-Path $JavaRoot "temp_import"
            if (-not (Expand-BundleArchive -BundleDir $bundleDir -RelativePath $j.archive `
                                           -Sha256 $j.sha256 -DestDir $temp -Label "JDK $($j.release)")) {
                continue
            }
            # El zip del JDK trae una carpeta raiz con el nombre de la release.
            $inner = @(Get-ChildItem $temp -Directory)
            if ($inner.Count -eq 1) {
                Move-Item -LiteralPath $inner[0].FullName -Destination $jdkPath -Force
            }
            else {
                New-Item -ItemType Directory -Path $jdkPath -Force | Out-Null
                Move-Item -Path "$temp\*" -Destination $jdkPath -Force
            }
            Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue

            if ($j.release) {
                Set-Content -LiteralPath (Join-Path $jdkPath ".assassinskipadm-release") `
                            -Value $j.release -Encoding ASCII
            }
        }

        Write-JavaShell -JdkPath $jdkPath -Major $j.version -Release $j.release | Out-Null
        Write-Log "  shell regenerado con las rutas de esta maquina" "SUCCESS"
        $pathsToAdd += (Join-Path $jdkPath "bin")
    }

    if ($pathsToAdd.Count -gt 0) {
        Write-Log ""
        Add-UserPathEntry -Path $pathsToAdd
    }

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "  IMPORTACION COMPLETADA" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Comprueba el resultado con:  .\Doctor-Env.bat" -ForegroundColor Gray
    Write-Host ""
}
finally {
    Remove-Item -LiteralPath $bundleDir -Recurse -Force -ErrorAction SilentlyContinue
}
