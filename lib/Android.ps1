#Requires -Version 5.1
<#
    El SDK de Android: leer el indice de Google e instalar sus paquetes sin sdkmanager

    NO lo carga Common.ps1: lo cargan Setup-AndroidEnv, Start-AndroidEmulator,
    Doctor y sus pruebas.

    Por que sin sdkmanager. Es lo que usa Android Studio, y son 148 MB de Java
    que hacen falta solo para descargar. Ademas no sabe pasar por un proxy que
    pide usuario y clave, que es justo el de la empresa. El kit ya descarga con
    proxy, reanudando y con cache; aqui solo hace falta leer el mismo indice que
    lee sdkmanager (repository2-3.xml y los de imagenes del sistema), bajar cada
    paquete contra el SHA-1 que publica Google, y dejar junto a el el
    package.xml que dejaria sdkmanager, que es por donde Gradle y el emulador
    saben que esta instalado. Comprobado contra el sdkmanager oficial: lista
    como instalado lo que pone el kit.
#>

$AndroidRepoBase = 'https://dl.google.com/android/repository/'
$AndroidRoot     = Join-Path $WorkspaceRoot 'Android'
$AndroidSdk      = Join-Path $AndroidRoot 'sdk'

# Los telefonos virtuales escriben gigas mientras funcionan. Van fuera de la
# carpeta de trabajo, que puede estar en OneDrive, y fuera del perfil movil.
$AndroidAvdHome  = Join-Path $env:LOCALAPPDATA 'CriisDevKit\android-avd'

# Lo que Gradle busca en sdk\licenses para saber que se acepto cada licencia.
# Se fijan aqui y no se calculan: el valor es el que escribe el sdkmanager
# oficial (comprobado con su version 19), y no sale de ninguna cuenta evidente
# sobre el texto. Texto es el SHA-256 del texto al que corresponde: si Google
# lo cambia, el kit lo nota y no escribe una aceptacion que ya no vale.
$AndroidLicenseHashes = @{
    'android-sdk-license' = [PSCustomObject]@{
        Aceptacion = '24333f8a63b6825ea9c5514f83c2829b004d1fee'
        Texto      = '1f8729233617b193fd619213792ae16a41b95d2bbbf525dfe66998252ba68b16'
    }
    'android-sdk-preview-license' = [PSCustomObject]@{
        Aceptacion = '84831b9409646a918e30573bab4c9c91346d8abd'
        Texto      = 'a7d8b9f305bf049f683cbf7ca694184c84736275cf9371377084913648bca5ec'
    }
}

# Lo que pide cada version del plugin de Android para Gradle (AGP), de la mas
# nueva a la mas vieja: desde que version rige cada fila.
#
# BuildTools es la que usa si el proyecto no dice otra, que no es la mas
# reciente (AGP 9.5.1 usa las 36.0.0 aunque esten las 37). Si el kit pusiera
# otras, AGP bajaria las suyas por su cuenta la primera vez. Sacadas de los
# propios JAR de AGP, la ultima de cada rama desde la 3.2 (ToolsRevisionUtils,
# o AndroidBuilder hasta la 3.4); la 3.0 y la 3.1 las guardan como numeros
# sueltos y no se leen, y para esas no se fija ninguna.
#
# Jdk es el que hace falta para ejecutar Gradle con ese AGP: la 7.0 pide 11 y
# la 8.0 pide 17, y antes de la 7 lo suyo es el 8 (un Gradle 5 no arranca con
# un JDK de despues del 11). Paso con un proyecto de 2019, AGP 3.4.2 y Gradle
# 5.1.1: con el JDK 21 del kit no compilaba.
$AndroidAgpRequisitos = @(
    [PSCustomObject]@{ Desde = '9.0'; BuildTools = '36.0.0'; Jdk = 17 }
    [PSCustomObject]@{ Desde = '8.8'; BuildTools = '35.0.0'; Jdk = 17 }
    [PSCustomObject]@{ Desde = '8.2'; BuildTools = '34.0.0'; Jdk = 17 }
    [PSCustomObject]@{ Desde = '8.1'; BuildTools = '33.0.1'; Jdk = 17 }
    [PSCustomObject]@{ Desde = '8.0'; BuildTools = '30.0.3'; Jdk = 17 }
    [PSCustomObject]@{ Desde = '7.1'; BuildTools = '30.0.3'; Jdk = 11 }
    [PSCustomObject]@{ Desde = '7.0'; BuildTools = '30.0.2'; Jdk = 11 }
    [PSCustomObject]@{ Desde = '4.2'; BuildTools = '30.0.2'; Jdk = 8 }
    [PSCustomObject]@{ Desde = '4.0'; BuildTools = '29.0.2'; Jdk = 8 }
    [PSCustomObject]@{ Desde = '3.2'; BuildTools = '28.0.3'; Jdk = 8 }
)

# Las del AGP actual: las que se instalan si no se sabe de que proyecto se trata.
$AndroidBuildToolsAgp = $AndroidAgpRequisitos[0].BuildTools

# Gradle con tope de memoria (1,5 GB, 2 procesos) y SIN daemon. El daemon se
# queda escuchando en todas las direcciones del equipo, y eso es lo que hacia
# saltar el aviso del firewall en cada compilacion; sin el no se abre ningun
# puerto (comprobado con un java.exe que el firewall no conocia, con Gradle 5
# y con Gradle 9), y la memoria se libera al terminar. -Xmx va igual en la JVM
# que arranca y en org.gradle.jvmargs: si no coinciden, Gradle abre otra JVM
# aparte para respetar los segundos.
$AndroidGradleOpts = '-Xmx1536m -Dorg.gradle.jvmargs=-Xmx1536m -Dorg.gradle.workers.max=2 -Dorg.gradle.daemon=false'

# El ultimo proyecto que se compilo con Start-AndroidApp: el menu lo ofrece.
$AndroidUltimoProyecto = Join-Path $env:LOCALAPPDATA 'CriisDevKit\android-proyecto.txt'

$script:AndroidIndexCache = @{}

function Get-AndroidIndex {
    <# Un indice del SDK ya leido como XML, o $null. Se guarda por ejecucion. #>
    param([Parameter(Mandatory=$true)][string]$Lista)

    if (-not $script:AndroidIndexCache.ContainsKey($Lista)) {
        $texto = Get-WebText -Uri ($AndroidRepoBase + $Lista) -Quiet
        $xml = $null
        if ($texto) { try { $xml = [xml]$texto } catch { $xml = $null } }
        $script:AndroidIndexCache[$Lista] = $xml
    }
    return $script:AndroidIndexCache[$Lista]
}

function ConvertFrom-AndroidIndex {
    <#
        Los paquetes de un indice, con su archivo para Windows: Path
        (platform-tools, platforms;android-34...), Version, Orden (para
        comparar), Estable, Nombre, Licencia, Url, Sha1, Bytes y Nodo (el
        elemento del XML, para escribir despues su package.xml).

        Los archivos de los indices de imagenes van relativos a SU carpeta
        (sys-img/android/), no a la del indice principal.
    #>
    param(
        [Parameter(Mandatory=$true)][xml]$Xml,
        [string]$Lista = 'repository2-3.xml'
    )

    $carpeta = $AndroidRepoBase
    if ($Lista -match '/') { $carpeta += ($Lista.Substring(0, $Lista.LastIndexOf('/') + 1)) }

    $paquetes = @()
    foreach ($p in @($Xml.DocumentElement.ChildNodes | Where-Object { $_.LocalName -eq 'remotePackage' })) {
        $archivos = @($p.archives.archive | Where-Object { $_ -and (-not $_.'host-os' -or $_.'host-os' -eq 'windows') })
        if ($archivos.Count -eq 0) { continue }
        # El emulador de Windows ya publica uno por arquitectura del equipo.
        $a = @($archivos | Where-Object { -not $_.'host-arch' -or $_.'host-arch' -eq 'x64' })[0]
        if (-not $a) { continue }

        $r = $p.revision
        $partes = @($r.major, $r.minor, $r.micro) | Where-Object { $null -ne $_ -and "$_" -ne '' }
        $version = ($partes -join '.')
        $orden = [version](@($r.major, $(if ($r.minor) { $r.minor } else { 0 }), $(if ($r.micro) { $r.micro } else { 0 })) -join '.')
        $canal = if ($p.channelRef) { $p.channelRef.ref } else { 'channel-0' }
        $url = $a.complete.url
        if ($url -notmatch '^https?://') { $url = $carpeta + $url }

        $paquetes += [PSCustomObject]@{
            Path     = $p.path
            Version  = $version
            Orden    = $orden
            Estable  = ($canal -eq 'channel-0')
            Nombre   = $p.'display-name'
            Licencia = $p.'uses-license'.ref
            Url      = $url
            Sha1     = ([string]$a.complete.checksum.'#text').ToLowerInvariant()
            Bytes    = [long]$a.complete.size
            Nodo     = $p
        }
    }
    return $paquetes
}

function Get-AndroidIndexLicenses {
    <# Las licencias de un indice: id -> texto. #>
    param([Parameter(Mandatory=$true)][xml]$Xml)
    $h = @{}
    foreach ($l in @($Xml.DocumentElement.ChildNodes | Where-Object { $_.LocalName -eq 'license' })) { $h[$l.id] = $l.InnerText }
    return $h
}

function Select-AndroidPackage {
    <# La version estable mas alta de un paquete por su ruta exacta, o $null. #>
    param([AllowEmptyCollection()][object[]]$Paquetes = @(), [Parameter(Mandatory=$true)][string]$Path)
    return @($Paquetes | Where-Object { $_.Path -eq $Path -and $_.Estable } | Sort-Object Orden -Descending)[0]
}

function Select-AndroidPlatform {
    <#
        La plataforma para compilar. Con -Api, esa (android-34, o android-37.0,
        que es como se llaman desde la 37). Sin ella, la estable mas alta.
        Nunca una -ext, una beta o una version menor (36.1): son para quien las
        pide por su nombre.
    #>
    param([AllowEmptyCollection()][object[]]$Paquetes = @(), [string]$Api)

    $candidatas = @($Paquetes | Where-Object { $_.Estable -and $_.Path -match '^platforms;android-(\d+)(?:\.(\d+))?$' -and (-not $Matches[2] -or $Matches[2] -eq '0') })
    if ($Api) {
        $a = $Api.Trim()
        return @($candidatas | Where-Object { $_.Path -eq "platforms;android-$a" -or $_.Path -eq "platforms;android-$a.0" } | Sort-Object Orden -Descending)[0]
    }
    return @($candidatas | Sort-Object { [int](($_.Path -replace '^platforms;android-', '') -replace '\..*$', '') }, Orden -Descending)[0]
}

function Select-AndroidBuildTools {
    <#
        Las build-tools de -Version si estan en el indice; si no, o sin ella, las
        estables mas recientes, sin las -rc.
    #>
    param([AllowEmptyCollection()][object[]]$Paquetes = @(), [string]$Version)

    if ($Version) {
        $exacta = @($Paquetes | Where-Object { $_.Path -eq "build-tools;$($Version.Trim())" } | Sort-Object Orden -Descending)[0]
        if ($exacta) { return $exacta }
    }
    return @($Paquetes | Where-Object { $_.Estable -and $_.Path -match '^build-tools;\d+\.\d+\.\d+$' } |
        Sort-Object { [version]($_.Path -replace '^build-tools;', '') } -Descending)[0]
}

function Select-AndroidSystemImage {
    <#
        La imagen del sistema de una API para el emulador. x86_64 si la hay, y
        si no x86 (las antiguas): es lo que corre acelerado en un PC.
    #>
    param(
        [AllowEmptyCollection()][object[]]$Paquetes = @(),
        [Parameter(Mandatory=$true)][string]$Api,
        [string]$Tipo = 'default'
    )
    foreach ($abi in @('x86_64', 'x86')) {
        $p = @($Paquetes | Where-Object { $_.Estable -and ($_.Path -eq "system-images;android-$Api;$Tipo;$abi" -or $_.Path -eq "system-images;android-$Api.0;$Tipo;$abi") } | Sort-Object Orden -Descending)[0]
        if ($p) { return $p }
    }
    return $null
}

function Get-AndroidSystemImageList {
    <#
        En que indice estan las imagenes de un tipo. Las "default" viven en
        sys-img/android/ y no en sys-img/default/: pedir esa ultima da un 404.
    #>
    param([Parameter(Mandatory=$true)][string]$Tipo)
    $carpeta = if ($Tipo -eq 'default') { 'android' } else { $Tipo }
    return "sys-img/$carpeta/sys-img2-3.xml"
}

function Get-AndroidPackageFolder {
    <# Donde vive un paquete dentro del SDK: "platforms;android-34" -> sdk\platforms\android-34. #>
    param([Parameter(Mandatory=$true)][string]$Sdk, [Parameter(Mandatory=$true)][string]$Path)
    return (Join-Path $Sdk ($Path -replace ';', '\'))
}

function ConvertTo-AndroidPackageXml {
    <#
        El package.xml que deja sdkmanager junto a cada paquete: el mismo
        elemento del indice como localPackage, sin archivos ni canal, y con el
        texto de su licencia. Los type-details del indice usan prefijos
        (generic:, sys-img:...) que tienen que existir en este documento con el
        mismo espacio de nombres, asi que se copian todos los del indice.
    #>
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$Paquete,
        [AllowEmptyString()][string]$LicenciaTexto
    )

    $doc = New-Object System.Xml.XmlDocument
    [void]$doc.AppendChild($doc.CreateXmlDeclaration('1.0', 'UTF-8', $null))
    $raiz = $doc.CreateElement('ns2', 'repository', 'http://schemas.android.com/repository/android/common/02')
    foreach ($at in @($Paquete.Nodo.OwnerDocument.DocumentElement.Attributes)) {
        if ($at.Prefix -eq 'xmlns' -and $at.LocalName -ne 'ns2') { $raiz.SetAttribute($at.Name, $at.Value) }
    }
    [void]$doc.AppendChild($raiz)

    if ($Paquete.Licencia -and $LicenciaTexto) {
        $l = $doc.CreateElement('license')
        $l.SetAttribute('id', $Paquete.Licencia)
        $l.SetAttribute('type', 'text')
        $l.InnerText = $LicenciaTexto
        [void]$raiz.AppendChild($l)
    }

    $lp = $doc.CreateElement('localPackage')
    $lp.SetAttribute('path', $Paquete.Path)
    $lp.SetAttribute('obsolete', 'false')
    foreach ($hijo in @($Paquete.Nodo.ChildNodes)) {
        if ($hijo.NodeType -ne 'Element' -or $hijo.LocalName -in @('channelRef', 'archives')) { continue }
        [void]$lp.AppendChild($doc.ImportNode($hijo, $true))
    }
    [void]$raiz.AppendChild($lp)

    $sw = New-Object System.IO.StringWriter
    $ajustes = New-Object System.Xml.XmlWriterSettings
    $ajustes.Indent = $true
    $ajustes.Encoding = New-Object System.Text.UTF8Encoding($false)
    $w = [System.Xml.XmlWriter]::Create($sw, $ajustes)
    $doc.Save($w); $w.Dispose()
    # StringWriter dice utf-16 en la declaracion; el archivo se escribe en UTF-8.
    return ($sw.ToString() -replace 'encoding="utf-16"', 'encoding="UTF-8"')
}

function Install-AndroidPackage {
    <#
        Baja un paquete contra su SHA-1, lo deja en su carpeta del SDK y escribe
        su package.xml. Lo que hubiera en esa carpeta se sustituye. Devuelve
        $true o $false, y explica el fallo.
    #>
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$Paquete,
        [Parameter(Mandatory=$true)][string]$Sdk,
        [hashtable]$Licencias = @{}
    )

    $destino = Get-AndroidPackageFolder -Sdk $Sdk -Path $Paquete.Path
    $trabajo = Join-Path ([IO.Path]::GetTempPath()) ("criisdevkit-android-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $trabajo -Force | Out-Null
    try {
        $zip = Join-Path $trabajo (Split-Path -Leaf ($Paquete.Url -replace '\?.*$', ''))
        if (-not (Invoke-Download -Uri $Paquete.Url -OutFile $zip -Sha1 $Paquete.Sha1 -Description "$($Paquete.Nombre) $($Paquete.Version)")) {
            return $false
        }
        if (Test-Path -LiteralPath $destino) { Remove-Item -LiteralPath $destino -Recurse -Force }
        Expand-ZipArchive -Path $zip -Destino $destino -QuitarEnvoltorio

        $xml = ConvertTo-AndroidPackageXml -Paquete $Paquete -LicenciaTexto $Licencias[$Paquete.Licencia]
        [IO.File]::WriteAllText((Join-Path $destino 'package.xml'), $xml, (New-Object System.Text.UTF8Encoding($false)))
        return $true
    }
    catch {
        Write-Log "No se pudo instalar $($Paquete.Path): $($_.Exception.Message)" "ERROR"
        return $false
    }
    finally {
        Remove-Item -LiteralPath $trabajo -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-InstalledAndroidPackages {
    <# Lo instalado en un SDK, leido de sus package.xml: Path, Version y Carpeta. #>
    param([Parameter(Mandatory=$true)][string]$Sdk)

    if (-not (Test-Path -LiteralPath $Sdk)) { return @() }
    $res = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $Sdk -Filter 'package.xml' -Recurse -Depth 4 -File -ErrorAction SilentlyContinue)) {
        $t = [IO.File]::ReadAllText($f.FullName)
        $p = [regex]::Match($t, '<localPackage[^>]*\bpath="([^"]+)"')
        if (-not $p.Success) { continue }
        $v = @('major', 'minor', 'micro') | ForEach-Object {
            $m = [regex]::Match($t, "(?s)<revision>.*?<$_>(\d+)</$_>.*?</revision>")
            if ($m.Success) { $m.Groups[1].Value }
        }
        $res += [PSCustomObject]@{ Path = $p.Groups[1].Value; Version = (@($v) -join '.'); Carpeta = $f.DirectoryName }
    }
    return $res
}

function Write-AndroidLicenses {
    <#
        Deja en sdk\licenses la aceptacion de cada licencia que se le pida,
        solo si su texto es el mismo al que corresponde el hash fijado. Las que
        no cuadran (o no se conocen) se devuelven en Cambiadas, para decirlo.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Sdk,
        [Parameter(Mandatory=$true)][hashtable]$Licencias,
        [AllowEmptyCollection()][string[]]$Ids = @()
    )

    $res = [PSCustomObject]@{ Escritas = @(); Cambiadas = @() }
    $dir = Join-Path $Sdk 'licenses'
    $sha = [Security.Cryptography.SHA256]::Create()
    foreach ($id in ($Ids | Where-Object { $_ } | Select-Object -Unique)) {
        $fijada = $AndroidLicenseHashes[$id]
        $texto = $Licencias[$id]
        if (-not $fijada -or -not $texto) { $res.Cambiadas += $id; continue }
        $huella = (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($texto)) | ForEach-Object { $_.ToString('x2') }) -join '')
        if ($huella -ne $fijada.Texto) { $res.Cambiadas += $id; continue }

        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $f = Join-Path $dir $id
        $actual = if (Test-Path -LiteralPath $f) { [IO.File]::ReadAllText($f) } else { '' }
        if ($actual -notmatch [regex]::Escape($fijada.Aceptacion)) {
            # El mismo formato que sdkmanager: un salto y el hash, por licencia aceptada.
            [IO.File]::WriteAllText($f, $actual + "`r`n" + $fijada.Aceptacion)
        }
        $res.Escritas += $id
    }
    return $res
}

function Get-HypervisorPlatformState {
    <#
        Si Windows deja acelerar el emulador: la "Plataforma del hipervisor de
        Windows" activada, y el hipervisor en marcha. Se lee sin admin. Va
        antes de bajar nada: el emulador y una imagen son mas de 1 GB.
    #>
    $activada = $false; $presente = $false
    try {
        $f = Get-CimInstance -ClassName Win32_OptionalFeature -Filter "Name='HypervisorPlatform'" -ErrorAction Stop
        $activada = ($f.InstallState -eq 1)
    } catch { }
    try { $presente = [bool](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).HypervisorPresent } catch { }
    return [PSCustomObject]@{ Activada = $activada; Hipervisor = $presente }
}

function Test-AndroidEmulatorAccel {
    <# La palabra final la tiene el propio emulador: -accel-check. #>
    param([Parameter(Mandatory=$true)][string]$Sdk)
    $exe = Join-Path $Sdk 'emulator\emulator.exe'
    if (-not (Test-Path -LiteralPath $exe)) { return [PSCustomObject]@{ Ok = $false; Texto = 'el emulador no esta instalado' } }
    $r = Invoke-NativeCommand -FilePath $exe -Arguments @('-accel-check') -Quiet
    $lineas = @($r.Output -split "`r?`n" | Where-Object { $_.Trim() -and $_ -notmatch '^accel:?$|^\d+$' })
    return [PSCustomObject]@{ Ok = ($r.ExitCode -eq 0); Texto = (($lineas | Select-Object -Last 1) -as [string]).Trim() }
}

function New-AndroidAvd {
    <#
        Un telefono virtual pensado para un equipo justo de recursos: 1,5 GB de
        RAM, 2 nucleos, pantalla de 720x1280 (la grafica es lo que mas carga),
        sin audio ni camaras, y arranque rapido para que la segunda vez reanude
        en segundos. Se escribe a mano lo que escribiria avdmanager, que es otra
        herramienta de Java que asi no hace falta.

        -ImagePath es la ruta del paquete (system-images;android-34;default;x86_64).
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Nombre,
        [Parameter(Mandatory=$true)][string]$AvdHome,
        [Parameter(Mandatory=$true)][string]$ImagePath,
        [string]$TagNombre = 'Default Android System Image',
        [int]$RamMb = 1536
    )

    $p = $ImagePath.Split(';')
    $api = $p[1] -replace '^android-', ''
    $tag = $p[2]
    $abi = $p[3]
    $carpeta = Join-Path $AvdHome "$Nombre.avd"
    New-Item -ItemType Directory -Path $carpeta -Force | Out-Null

    $config = @(
        "AvdId=$Nombre"
        "avd.ini.displayname=$Nombre"
        "avd.ini.encoding=UTF-8"
        "abi.type=$abi"
        "hw.cpu.arch=$abi"
        "image.sysdir.1=$(($ImagePath -replace ';', '\'))\"
        "tag.id=$tag"
        "tag.display=$TagNombre"
        "PlayStore.enabled=false"
        "hw.ramSize=$RamMb"
        "vm.heapSize=256"
        "hw.cpu.ncore=2"
        "hw.lcd.width=720"
        "hw.lcd.height=1280"
        "hw.lcd.density=320"
        "hw.keyboard=yes"
        # Barra de navegacion en pantalla, como un telefono de verdad. Sin
        # esto el emulador supone botones fisicos y no la dibuja, y en
        # Android 8.0 la interfaz del sistema revienta en cuanto una app se
        # abre sobre la pantalla de bloqueo (NavigationBarFragment nulo).
        "hw.mainKeys=no"
        "hw.gpu.enabled=yes"
        "hw.gpu.mode=auto"
        "hw.audioInput=no"
        "hw.audioOutput=no"
        "hw.camera.back=none"
        "hw.camera.front=none"
        "disk.dataPartition.size=2G"
        "fastboot.forceColdBoot=no"
        "fastboot.forceFastBoot=yes"
        "showDeviceFrame=no"
        "hw.initialOrientation=portrait"
    )
    Set-Content -LiteralPath (Join-Path $carpeta 'config.ini') -Value $config -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $AvdHome "$Nombre.ini") -Encoding ASCII -Value @(
        "avd.ini.encoding=UTF-8"
        "path=$carpeta"
        "path.rel=avd\$Nombre.avd"
        "target=android-$api"
    )
    return $carpeta
}

function Get-AndroidAvds {
    <# Los telefonos virtuales que hay, por nombre. #>
    param([string]$AvdHome = $AndroidAvdHome)
    if (-not (Test-Path -LiteralPath $AvdHome)) { return @() }
    return @(Get-ChildItem -LiteralPath $AvdHome -Filter '*.ini' -File | ForEach-Object { $_.BaseName } | Sort-Object)
}

function Get-AgpRequirements {
    <#
        Que pide una version de AGP: BuildTools (o $null, antes de la 3.2) y
        Jdk. $null si la version no se entiende.
    #>
    param([AllowEmptyString()][string]$Agp)
    $m = [regex]::Match([string]$Agp, '^(\d+)\.(\d+)')
    if (-not $m.Success) { return $null }
    $v = [version]"$($m.Groups[1].Value).$($m.Groups[2].Value)"
    $fila = @($AndroidAgpRequisitos | Where-Object { $v -ge [version]$_.Desde })[0]
    if ($fila) { return [PSCustomObject]@{ BuildTools = $fila.BuildTools; Jdk = $fila.Jdk } }
    return [PSCustomObject]@{ BuildTools = $null; Jdk = 8 }
}

function Get-KitJdkForAndroid {
    <#
        El JDK del kit para Gradle, o $null. Sin -Mayor, el mas alto de 17 o
        mas, que es lo que pide AGP desde la 8; con -Mayor, ese (los
        proyectos con un AGP de antes de la 7 van con el 8).
    #>
    param([int]$Mayor)
    $raiz = Join-Path $WorkspaceRoot 'Java'
    $jdk = @(Get-ChildItem -LiteralPath $raiz -Directory -Filter 'jdk-*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^jdk-(\d+)$' -and $(if ($Mayor) { [int]$Matches[1] -eq $Mayor } else { [int]$Matches[1] -ge 17 }) -and (Test-Path (Join-Path $_.FullName 'bin\java.exe')) } |
        Sort-Object { [int]($_.Name -replace 'jdk-', '') } -Descending)[0]
    if ($jdk) { return $jdk.FullName }
    return $null
}

function Get-AndroidEnvironment {
    <#
        Las variables y las rutas que necesitan Gradle, adb y el emulador. Las
        usan el shell que se genera y Start-AndroidEmulator, para que sean las
        mismas.
    #>
    param([Parameter(Mandatory=$true)][string]$Sdk, [string]$Jdk)
    # ADB_MDNS=0: adb deja de buscar telefonos por la red (mDNS), que abre un
    # puerto UDP en todas las direcciones y hacia saltar el aviso del firewall.
    # Para el emulador no hace falta: va por 127.0.0.1.
    $vars = [ordered]@{ ANDROID_HOME = $Sdk; ANDROID_SDK_ROOT = $Sdk; ANDROID_AVD_HOME = $AndroidAvdHome; ADB_MDNS = '0' }
    $rutas = @((Join-Path $Sdk 'platform-tools'), (Join-Path $Sdk 'emulator'))
    if ($Jdk) { $vars['JAVA_HOME'] = $Jdk; $rutas += (Join-Path $Jdk 'bin') }
    return [PSCustomObject]@{ Variables = $vars; Rutas = $rutas }
}

function Write-AndroidShell {
    <#
        android-shell.bat: una consola con todo puesto. Gradle va con un tope de
        memoria y de procesos (GRADLE_OPTS, solo en esta consola: no toca la
        configuracion del usuario), porque compilar Kotlin se come facilmente
        2 GB y el equipo no esta para eso.

        Termina en "cmd /k", como las demas consolas del kit: con doble clic la
        ventana se queda abierta. Por cada JDK de -OtrosJdk deja ademas
        android-javaN-shell.bat, que es la misma con ese JDK: un doble clic no
        puede pasar argumentos.
    #>
    param([Parameter(Mandatory=$true)][string]$Sdk, [string]$Jdk, [int[]]$OtrosJdk = @(), [string]$JavaRoot = (Join-Path $WorkspaceRoot 'Java'))

    # El JDK va aparte de las demas rutas: "android-shell.bat 8" lo cambia por
    # el jdk-8 del kit, para un proyecto con un AGP de antes de la 7. Con un
    # if por linea y sin bloques entre parentesis, que una ruta con ")" rompe.
    $e = Get-AndroidEnvironment -Sdk $Sdk
    $java = ConvertTo-CmdLiteral $JavaRoot
    $l = @('@echo off', 'rem Generado por Setup-AndroidEnv del kit CriisDevKit. No editar a mano.', 'title Android')
    foreach ($k in $e.Variables.Keys) { $l += "set `"$k=$(ConvertTo-CmdLiteral $e.Variables[$k])`"" }
    if ($Jdk) { $l += "set `"JAVA_HOME=$(ConvertTo-CmdLiteral $Jdk)`"" }
    $l += "if not `"%~1`"==`"`" if exist `"$java\jdk-%~1\bin\java.exe`" set `"JAVA_HOME=$java\jdk-%~1`""
    $l += "if not `"%~1`"==`"`" if not exist `"$java\jdk-%~1\bin\java.exe`" echo   No hay JDK %~1 del kit: se queda el de siempre. Instalalo con Setup-JavaEnv -JavaVersion %~1"
    $l += "set `"PATH=$((@($e.Rutas) | ForEach-Object { ConvertTo-CmdLiteral $_ }) -join ';');%JAVA_HOME%\bin;%PATH%`""
    # Sin "%GRADLE_OPTS%" detras: otro -Xmx que trajera el usuario ganaria al
    # nuestro, y con el descuadre Gradle volveria a abrir otra JVM.
    $l += "set `"GRADLE_OPTS=$AndroidGradleOpts`""
    $l += @(Get-GradleProxyLine)
    $l += 'echo.'
    # El JDK por un for y no con %JAVA_HOME% en el echo: una ruta con "&"
    # partiria la linea. La variable del for se expande despues de eso.
    $l += 'echo   Android listo: adb, emulator y Gradle con tope de memoria.'
    $l += 'if defined JAVA_HOME for %%i in ("%JAVA_HOME%") do echo   JDK: %%~nxi'
    $l += 'echo.'
    $l += 'echo   En la carpeta del proyecto:'
    $l += 'echo     gradlew assembleDebug     compila; la app sale en app\build\outputs\apk\debug'
    $l += 'echo   Lo mas sencillo, compilar y abrirla en el telefono de una vez: Menu.bat, opcion 60.'
    $l += 'echo.'
    $l += 'echo Escribe exit para cerrar'
    $l += 'cmd /k'
    $carpeta = Split-Path -Parent $Sdk
    $bat = Join-Path $carpeta 'android-shell.bat'
    New-Item -ItemType Directory -Path $carpeta -Force | Out-Null
    Set-Content -LiteralPath $bat -Value $l -Encoding ASCII

    foreach ($n in @($OtrosJdk | Where-Object { $_ } | Select-Object -Unique)) {
        Set-Content -LiteralPath (Join-Path $carpeta "android-java$n-shell.bat") -Encoding ASCII -Value @(
            '@echo off', 'rem Generado por Setup-AndroidEnv del kit CriisDevKit. No editar a mano.'
            "call `"%~dp0android-shell.bat`" $n")
    }
    return $bat
}

function Get-AndroidShellJdks {
    <# Los JDK que ya tienen su android-javaN-shell.bat, para no perderlos al regenerar. #>
    param([string]$Carpeta = $AndroidRoot)
    # El -match dentro del ForEach-Object: en un Where-Object, $Matches se queda
    # en su ambito y el ForEach leeria otro (ver Update-GeneratedShells).
    return @(Get-ChildItem -LiteralPath $Carpeta -Filter 'android-java*-shell.bat' -File -ErrorAction SilentlyContinue |
        ForEach-Object { if ($_.Name -match '^android-java(\d+)-shell\.bat$') { [int]$Matches[1] } } | Sort-Object)
}

function Get-AndroidUserHome {
    <# El ANDROID_HOME de usuario. Aparte para que las pruebas lo puedan fingir. #>
    return [Environment]::GetEnvironmentVariable('ANDROID_HOME', 'User')
}

function Set-AndroidUserEnv {
    <#
        ANDROID_HOME de usuario, para que Gradle encuentre el SDK desde
        cualquier terminal o desde VS Code. Si ya apuntaba a OTRO SDK (el de un
        Android Studio, por ejemplo) no se toca: se devuelve para decirlo.
    #>
    param([Parameter(Mandatory=$true)][string]$Sdk, [switch]$Force)
    $actual = Get-AndroidUserHome
    if ($actual -and $actual.TrimEnd('\') -ne $Sdk.TrimEnd('\') -and (Test-Path -LiteralPath $actual) -and -not $Force) {
        return [PSCustomObject]@{ Puesto = $false; Habia = $actual }
    }
    [Environment]::SetEnvironmentVariable('ANDROID_HOME', $Sdk, 'User')
    return [PSCustomObject]@{ Puesto = $true; Habia = $actual }
}

function ConvertFrom-AaptBadging {
    <# Del "aapt2 dump badging" de un APK: su paquete y la actividad con la que arranca. #>
    param([AllowEmptyString()][string]$Texto)
    $p = [regex]::Match($Texto, "(?m)^package: name='([^']+)'")
    $a = [regex]::Match($Texto, "(?m)^launchable-activity: name='([^']+)'")
    return [PSCustomObject]@{
        Paquete   = if ($p.Success) { $p.Groups[1].Value } else { $null }
        Actividad = if ($a.Success) { $a.Groups[1].Value } else { $null }
    }
}

function Get-AndroidApkInfo {
    <#
        El paquete de un APK, con las build-tools instaladas, o $null. Se prueba
        aapt2 y despues aapt: el aapt2 de las 28.0.3 (las de AGP 3.x) no tiene
        "dump badging", y con solo esas instaladas la app se instalaba pero no
        se abria.
    #>
    param([Parameter(Mandatory=$true)][string]$Apk, [Parameter(Mandatory=$true)][string]$Sdk)
    $herramientas = @(Get-ChildItem -LiteralPath (Join-Path $Sdk 'build-tools') -Directory -ErrorAction SilentlyContinue |
        Sort-Object { try { [version]$_.Name } catch { [version]'0.0' } } -Descending |
        ForEach-Object { Join-Path $_.FullName 'aapt2.exe'; Join-Path $_.FullName 'aapt.exe' } | Where-Object { Test-Path -LiteralPath $_ })
    foreach ($h in $herramientas) {
        $r = Invoke-NativeCommand -FilePath $h -Arguments @('dump', 'badging', $Apk) -Quiet
        if ($r.ExitCode -ne 0) { continue }
        $info = ConvertFrom-AaptBadging -Texto $r.Output
        if ($info.Paquete) { return $info }
    }
    return $null
}

# --------------------------------------------------------------------------
# Start-AndroidApp: de la carpeta del proyecto a la app abierta en el telefono
# --------------------------------------------------------------------------

function Get-AndroidAppPlan {
    <#
        Que necesita un proyecto (lo que devuelve Get-AndroidProjectInfo) para
        compilarse y abrirse en el telefono de -Api, y que falta de eso en este
        equipo. Solo mira el disco: sin red, y en un segundo, para que la
        segunda vez no haga falta ni leer el indice de Google.

        Devuelve JdkMayor, Jdk (la ruta, o $null), BuildTools, Faltan (para
        decirlo) y SetupArgs (lo que hay que pasarle a Setup-AndroidEnv).
    #>
    param([Parameter(Mandatory=$true)]$Info, [string]$Api = '26', [switch]$SoloCompilar, [string]$Sdk = $AndroidSdk)

    $req = Get-AgpRequirements -Agp $Info.Agp
    $jdkMayor = if ($req) { $req.Jdk } else { 17 }
    $bt = if ($Info.BuildTools) { $Info.BuildTools } elseif ($req) { $req.BuildTools } else { $null }
    $inst = @{}
    foreach ($p in @(Get-InstalledAndroidPackages -Sdk $Sdk)) { $inst[$p.Path] = $true }

    $faltan = @()
    $jdk = if ($jdkMayor -lt 17) { Get-KitJdkForAndroid -Mayor $jdkMayor } else { Get-KitJdkForAndroid }
    if (-not $jdk) { $faltan += "el JDK $jdkMayor" }
    if (-not $inst['platform-tools']) { $faltan += 'adb (platform-tools)' }
    if ($Info.CompileSdk) {
        if (-not ($inst["platforms;android-$($Info.CompileSdk)"] -or $inst["platforms;android-$($Info.CompileSdk).0"])) { $faltan += "la plataforma android-$($Info.CompileSdk)" }
    }
    elseif (-not @($inst.Keys | Where-Object { $_ -like 'platforms;*' }).Count) { $faltan += 'una plataforma' }
    if ($bt -and -not $inst["build-tools;$bt"]) { $faltan += "las build-tools $bt" }
    if (-not $SoloCompilar) {
        if (-not $inst['emulator']) { $faltan += 'el emulador' }
        if (-not @($inst.Keys | Where-Object { $_ -match "^system-images;android-$([regex]::Escape($Api))(\.0)?;default;(x86_64|x86)$" }).Count) { $faltan += "Android API $Api para el telefono" }
        if ((Get-AndroidAvds) -notcontains "kit-api$Api") { $faltan += "el telefono kit-api$Api" }
    }

    $a = @{}
    if ($Info.CompileSdk) { $a['Plataforma'] = $Info.CompileSdk }
    if ($bt) { $a['BuildTools'] = $bt }
    if ($jdkMayor -lt 17) { $a['Jdk'] = $jdkMayor }
    if (-not $SoloCompilar) { $a['Emulador'] = $true; $a['Api'] = $Api }
    $a['SinResumen'] = $true
    return [PSCustomObject]@{ JdkMayor = $jdkMayor; Jdk = $jdk; BuildTools = $bt; Faltan = $faltan; SetupArgs = $a }
}

function Select-GradleLine {
    <#
        Si una linea de la salida de Gradle se ensena o es ruido conocido. Un
        AGP de antes de 2020 se queja de cada paquete del SDK de ahora con una
        traza de un centenar de lineas (campos base-extension y extension-level
        que no conocia) y compila igual: asustaba y escondia lo que importa.

        Devuelve la linea, $null si es ruido, o un aviso de una linea la primera
        vez que oculta algo. -Estado guarda entre llamadas si se esta dentro de
        una de esas trazas. Las trazas de un error de verdad se ensenan: solo
        se ocultan las que empiezan por una de esas quejas.
    #>
    param([AllowEmptyString()][string]$Linea, [Parameter(Mandatory=$true)][hashtable]$Estado)

    $campo = '(base-extension|extension-level)'
    $ruido = ($Linea -match '^Mapping new ns http://schemas\.android\.com/') -or
             ($Linea -match "cvc-complex-type\.2\.4\.a.*$campo") -or
             ($Linea -match "(elemento inesperado|unexpected element) \(URI:`"`", local:`"$campo`"\)")
    if ($Linea -match "SAXParseException.*$campo") { $ruido = $true; $Estado.EnTraza = $true }
    elseif ($Estado.EnTraza) {
        if ($Linea -match '^\s+at |^\s*\.\.\. \d+ more|^\s*$') { $ruido = $true }
        else { $Estado.EnTraza = $false }
    }
    if (-not $ruido) { return $Linea }
    if (-not $Estado.Avisado) {
        $Estado.Avisado = $true
        return '  (El plugin de Android de este proyecto no conoce el formato del SDK de ahora y lo avisa con trazas largas. No afecta: se ocultan.)'
    }
    return $null
}

function Invoke-AndroidBuild {
    <#
        Compila con el gradlew del proyecto, el JDK que se le diga y el mismo
        entorno que android-shell.bat (sin daemon: sin avisos del firewall),
        ensenando la salida segun sale pero sin el ruido de Select-GradleLine.
        Deja las variables del proceso como estaban. Devuelve Ok y Codigo, o
        $null si el proyecto no trae gradlew.bat.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Proyecto,
        [Parameter(Mandatory=$true)][string]$Jdk,
        [string]$Sdk = $AndroidSdk,
        [string]$Tarea = 'assembleDebug'
    )

    $gw = Join-Path $Proyecto 'gradlew.bat'
    if (-not (Test-Path -LiteralPath $gw)) { return $null }

    $e = Get-AndroidEnvironment -Sdk $Sdk -Jdk $Jdk
    $nombres = @($e.Variables.Keys) + @('GRADLE_OPTS', 'PATH')
    $previo = @{}
    foreach ($k in $nombres) { $previo[$k] = [Environment]::GetEnvironmentVariable($k, 'Process') }
    $estado = @{ EnTraza = $false; Avisado = $false }
    $codigo = 1
    try {
        foreach ($k in $e.Variables.Keys) { Set-Item -LiteralPath "Env:\$k" -Value $e.Variables[$k] }
        $env:PATH = (@($e.Rutas) -join ';') + ';' + $env:PATH
        $env:GRADLE_OPTS = ("$AndroidGradleOpts $(Get-GradleProxyProps)").Trim()

        # Continue y no Stop: la salida de error de Gradle llega como registros
        # de error de PowerShell, y con Stop el primero cortaria la compilacion.
        $eap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        Push-Location -LiteralPath $Proyecto
        try {
            & $gw $Tarea '--console=plain' 2>&1 | ForEach-Object {
                $l = Select-GradleLine -Linea "$_" -Estado $estado
                if ($null -ne $l) { Write-Host $l }
            }
            $codigo = $LASTEXITCODE
        }
        finally { Pop-Location; $ErrorActionPreference = $eap }
    }
    finally {
        foreach ($k in $nombres) { [Environment]::SetEnvironmentVariable($k, $previo[$k], 'Process') }
    }
    return [PSCustomObject]@{ Ok = ($codigo -eq 0); Codigo = $codigo }
}

function Get-AndroidBuiltApk {
    <#
        La APK de depuracion mas reciente de un modulo, o $null. La mas
        reciente y no "la de despues de compilar": si nada cambio, Gradle no la
        reescribe, y sigue siendo la buena.
    #>
    param([Parameter(Mandatory=$true)][string]$Proyecto, [string]$Modulo)
    $base = if ($Modulo) { Join-Path $Proyecto $Modulo } else { $Proyecto }
    return @(Get-ChildItem -LiteralPath (Join-Path $base 'build\outputs\apk') -Recurse -Filter '*.apk' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\androidTest\\' } | Sort-Object LastWriteTime -Descending)[0]
}

function Get-AndroidLastProject {
    <# La carpeta del ultimo proyecto de Start-AndroidApp, si sigue existiendo. #>
    param([string]$Archivo = $AndroidUltimoProyecto)
    if (-not (Test-Path -LiteralPath $Archivo)) { return $null }
    $r = ([IO.File]::ReadAllText($Archivo)).Trim()
    if ($r -and (Test-Path -LiteralPath $r -PathType Container)) { return $r }
    return $null
}

function Set-AndroidLastProject {
    param([Parameter(Mandatory=$true)][string]$Ruta, [string]$Archivo = $AndroidUltimoProyecto)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Archivo) -Force | Out-Null
    [IO.File]::WriteAllText($Archivo, $Ruta)
}
