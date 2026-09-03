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

    [ValidateSet('Angular', 'Python', 'Java', 'Node', 'Git', 'Maven', 'Gradle', 'Dotnet', 'VSCode')]
    [string]$Runtime,

    [switch]$WhatIf,

    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Common.ps1")

$AngularRoot = Join-Path $WorkspaceRoot "Angular"
$PythonRoot  = Join-Path $WorkspaceRoot "Python"
$JavaRoot    = Join-Path $WorkspaceRoot "Java"

# 2 desde que el manifiesto lleva la seccion "otros" con los seis runtimes que
# antes no se empaquetaban. Los bundles v1 se siguen leyendo: solo les falta esa
# seccion y la lista sale vacia.
$SupportedManifest = 2


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
        [string]$Label,
        # Verifica y COPIA el archivo sin extraerlo. Lo necesitan los runtimes
        # que no vienen en zip -PortableGit es un autoextraible- o que se
        # descomprimen de otra forma; de eso se encarga Expand-BundledRuntime.
        [switch]$SoloCopiar
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

    if (-not (Test-Path -LiteralPath $DestDir)) {
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    }

    if ($SoloCopiar) {
        Copy-Item -LiteralPath $archive -Destination $DestDir -Force
        return $true
    }

    if (-not (Test-ZipIntegrity -ZipPath $archive)) {
        Write-Log "$Label : el zip del bundle esta danado" "ERROR"
        return $false
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

$bundleDir = Join-Path $env:TEMP ("criisdevkit-import-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))

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

    # La version del kit es informativa, no bloqueante: quien decide si el bundle
    # se puede importar es manifestVersion, que describe el formato. Esto solo
    # sirve para que, si algo sale raro, se sepa que no se generaron con el mismo.
    if ($m.kitVersion -and $m.kitVersion -ne $KitVersion) {
        Write-Log "El bundle lo genero un kit v$($m.kitVersion) y este es v$KitVersion." "WARN"
    }

    Write-Host "Bundle creado el $($m.created)" -ForegroundColor Gray
    Write-Host "en la maquina '$($m.createdOn)'" -ForegroundColor Gray
    Write-Host ""

    $angular = @(if (Test-RuntimeSelected -Name 'Angular' -Selected $Runtime) { $m.angular })
    $python  = @(if (Test-RuntimeSelected -Name 'Python' -Selected $Runtime)  { $m.python })
    $java    = @(if (Test-RuntimeSelected -Name 'Java' -Selected $Runtime)    { $m.java })

    # Los seis restantes vienen en "otros", identificados por su clave del
    # catalogo. Un bundle v1 no trae esa seccion, y entonces la lista sale vacia.
    $otros = @()
    foreach ($o in @($m.otros)) {
        if (-not $o -or -not $o.clave) { continue }
        $e = @(Get-RuntimeCatalog | Where-Object { $_.Clave -eq $o.clave })
        if ($e.Count -eq 0) { continue }
        if (-not (Test-RuntimeSelected -Name $e[0].Carpeta -Selected $Runtime)) { continue }
        $otros += $o
    }

    Write-Host "Se va a instalar:" -ForegroundColor Yellow
    foreach ($a in $angular) { Write-Host "  Angular v$($a.version)  (CLI $($a.cliVersion), Node $($a.node))" }
    foreach ($p in $python)  { Write-Host "  Python $($p.full)  ($(@($p.packages).Count) paquetes)" }
    foreach ($j in $java)    { Write-Host "  Java $($j.version)  ($($j.release))" }
    foreach ($o in $otros)   {
        $n = @(Get-RuntimeCatalog | Where-Object { $_.Clave -eq $o.clave })[0].Nombre
        Write-Host "  $n $($o.version)"
    }
    if ($m.corpCa) {
        Write-Host ("  + la CA de la empresa: {0}" -f $m.corpCa.emisor) -ForegroundColor Yellow
        Write-Host ("    caduca el {0}; se pondra en los JDK, Git y pip" -f $m.corpCa.caduca) -ForegroundColor DarkGray
    }
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

        $nodeFolder = "node-v$($a.node)-win-$(Get-ArchToken -Fuente node)"
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

            # Misma marca de trazabilidad que deja Setup-PythonEnv. Aqui el hash
            # ya viene verificado en el manifiesto, asi que solo hay que
            # anotarlo: sin esto, un Python importado quedaba sin marca y Doctor
            # no lo mostraba, o sea que los dos caminos de instalacion dejaban
            # estados distintos.
            if ($p.sha256) {
                Set-Content -LiteralPath (Join-Path $pythonPath ".criisdevkit-sha256") `
                            -Value $p.sha256 -Encoding ASCII
            }
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
                Set-Content -LiteralPath (Join-Path $jdkPath ".criisdevkit-release") `
                            -Value $j.release -Encoding ASCII
            }
        }

        Write-JavaShell -JdkPath $jdkPath -Major $j.version -Release $j.release | Out-Null
        Write-Log "  shell regenerado con las rutas de esta maquina" "SUCCESS"
        $pathsToAdd += (Join-Path $jdkPath "bin")
    }

    # --- Los seis que van por el catalogo ---
    #
    # Un solo bucle para todos: como se extrae cada uno y donde va su bin sale
    # de los metadatos del catalogo, no de un caso por runtime. Anadir el
    # siguiente no deberia tocar este archivo.
    foreach ($o in $otros) {
        $e = @(Get-RuntimeCatalog | Where-Object { $_.Clave -eq $o.clave })
        if ($e.Count -eq 0) {
            Write-Log "El bundle trae '$($o.clave)', que este kit no conoce; se omite" "WARN"
            continue
        }
        $e = $e[0]

        Write-Log "Instalando $($e.Nombre) $($o.version)..."

        $raiz = Join-Path $WorkspaceRoot $e.Carpeta
        $nombre = switch ($e.Clave) {
            'node' { "node-$($o.linea)" }
            default { "$($e.Clave)-$($o.linea)" }
        }
        $destino = Join-Path $raiz $nombre

        if (Test-Path -LiteralPath $destino) {
            Write-Log "  ya existe $nombre; se conserva" "WARN"
        }
        else {
            # El archivo se verifica ANTES de extraer, igual que los demas: si el
            # bundle viajo en un USB y se corrompio, mejor enterarse aqui.
            $tmp = Join-Path $env:TEMP ("imp-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
            if (-not (Expand-BundleArchive -BundleDir $bundleDir -RelativePath $o.archive `
                                           -Sha256 $o.sha256 -DestDir $tmp -Label "$($e.Nombre) $($o.version)" -SoloCopiar)) {
                continue
            }

            if (-not (Test-Path -LiteralPath $raiz)) { New-Item -ItemType Directory -Path $raiz -Force | Out-Null }

            $archivo = @(Get-ChildItem -LiteralPath $tmp -File)[0].FullName
            $ok = Expand-BundledRuntime -Archivo $archivo -Destino $destino -Entrada $e
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

            if (-not $ok) {
                Write-Log "  no se pudo extraer; se omite" "ERROR"
                continue
            }

            # PortableGit necesita su post-install para dejar listo el entorno
            # de Git Bash. Sin esto, un Git importado quedaba a medias y Doctor
            # lo cazaba con "post-instalacion sin completar".
            if ($e.Clave -eq 'git') {
                Invoke-GitPostInstall -GitPath $destino | Out-Null
            }

            # VS Code solo es portable si existe data\; sin ella escribiria los
            # ajustes en el perfil del usuario sin avisar.
            if ($e.Clave -eq 'vscode') {
                $data = Join-Path $destino "data"
                if (-not (Test-Path -LiteralPath $data)) {
                    New-Item -ItemType Directory -Path $data -Force | Out-Null
                    Write-Log "  modo portable activado (carpeta data\)" "SUCCESS"
                }
            }
        }

        Write-RuntimeShell -Clave $e.Clave -Ruta $destino -Version $o.version -Linea $o.linea | Out-Null
        Write-Log "  shell regenerado con las rutas de esta maquina" "SUCCESS"

        # Cada uno publica una carpeta distinta en el PATH.
        $bin = switch ($e.Clave) {
            'node'   { $destino }
            'dotnet' { $destino }
            'git'    { Join-Path $destino "cmd" }
            default  { Join-Path $destino "bin" }
        }
        $pathsToAdd += $bin
    }

    # La CA de la empresa, si el bundle la trae. Antes que los shells: asi los
    # de Node y Angular ya se escriben con NODE_EXTRA_CA_CERTS puesto.
    if ($m.corpCa -and $m.corpCa.archivo) {
        $origen = Join-Path $bundleDir $m.corpCa.archivo
        if (Test-Path -LiteralPath $origen) {
            $destino = Split-Path -Parent $CorpCaFile
            if (-not (Test-Path -LiteralPath $destino)) { New-Item -ItemType Directory -Path $destino -Force | Out-Null }
            Copy-Item -LiteralPath $origen -Destination $CorpCaFile -Force
            Write-CorpCaPem | Out-Null
            Write-Log "CA de la empresa: $($m.corpCa.emisor)" "SUCCESS"
            foreach ($linea in @(Sync-CorpNet)) { Write-Log "  $linea" "SUCCESS" }
        }
        else {
            Write-Log "El manifiesto anuncia una CA que no viene en el bundle" "WARN"
        }
    }

    # Los shells por JDK de Maven y Gradle, una vez estan todos los runtimes en
    # su sitio. Aqui y no dentro del bucle: cada Write-RuntimeShell escribe solo
    # el shell por defecto, y hasta el final no se sabe cuantos JDK trae el
    # bundle. Sin esto, importar dos Java y un Maven daria un unico shell atado
    # al Java mas alto, justo lo contrario de lo que se importo.
    foreach ($linea in @(Sync-BuildToolShells)) {
        Write-Log "  $linea" "SUCCESS"
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
    Write-Host "Comprueba el resultado con:  .\bin\kit\Doctor-Env.bat" -ForegroundColor Gray
    Write-Host ""
}
finally {
    Remove-Item -LiteralPath $bundleDir -Recurse -Force -ErrorAction SilentlyContinue
}
