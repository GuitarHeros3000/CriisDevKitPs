#Requires -Version 5.1
<#
    Abrir ejecutables e instaladores sin ejecutarlos

    Parte de lib\Common.ps1, que es quien carga este archivo. No se toma
    por separado: los scripts siguen haciendo un unico dot-source de
    Common.ps1 y no se enteran de esta division.

    Todo lo de aqui LEE: la cabecera de un .exe o una .dll, los contenedores
    de un bundle WiX Burn, la base de datos de un MSI. Nada se instala ni se
    lanza, y por eso funciona igual en un equipo donde una directiva de empresa
    bloquea msiexec o la ejecucion de instaladores.
#>

# --------------------------------------------------------------------------
# Cabecera PE
# --------------------------------------------------------------------------

function Get-PeInfo {
    <#
    .SYNOPSIS
        Lo que dice la cabecera de un ejecutable PE (.exe o .dll).
    .DESCRIPTION
        Devuelve la arquitectura, las secciones y las DLL que importa, o $null
        si el archivo no es un PE o esta truncado.

        La arquitectura es la del BINARIO, no la del equipo, y es la que decide
        que DLL puede cargar: un .exe de 32 bits en un Windows de 64 no carga
        una DLL de 64 aunque se llame igual. Windows responde con un 0xc000007b
        que no explica nada, y es justo el error de copiar a mano las DLL de
        C:\Windows\System32, donde en un Windows de 64 bits estan las de 64.

        Las importaciones incluyen las de carga diferida (delay-load): tambien
        son DLL que el programa necesita, solo que las pide mas tarde, y no
        tenerlas da el mismo error en mitad de la ejecucion.

        Se lee con saltos sobre el archivo y no cargandolo entero: tambien pasan
        por aqui instaladores de varios GB.
    #>
    param([Parameter(Mandatory=$true)][string]$FilePath)

    try {
        $fs = [System.IO.File]::OpenRead($FilePath)
    }
    catch {
        return $null
    }

    try {
        $br = New-Object System.IO.BinaryReader($fs)
        if ($fs.Length -lt 0x40) { return $null }

        if ($br.ReadUInt16() -ne 0x5A4D) { return $null }      # "MZ"

        # La cabecera DOS guarda en 0x3C el desplazamiento de la firma PE.
        $fs.Position = 0x3C
        $pe = $br.ReadInt32()
        if ($pe -le 0 -or $pe -ge ($fs.Length - 24)) { return $null }

        $fs.Position = $pe
        if ($br.ReadUInt32() -ne 0x00004550) { return $null }  # "PE\0\0"

        # Cabecera COFF: maquina, numero de secciones y tamano de la cabecera
        # opcional, que es lo que separa la cabecera de la tabla de secciones.
        $machine     = $br.ReadUInt16()
        $nSecciones  = $br.ReadUInt16()
        $fs.Position = $pe + 20
        $tamOpcional = $br.ReadUInt16()
        $opcional    = $pe + 24

        $arquitectura = switch ($machine) {
            0x014C  { 'x86' }
            0x8664  { 'x64' }
            0xAA64  { 'arm64' }
            default { 'desconocida' }
        }

        $secciones = @()
        $fs.Position = $opcional + $tamOpcional
        for ($i = 0; $i -lt $nSecciones; $i++) {
            $raw = $br.ReadBytes(40)
            if ($raw.Length -lt 40) { break }
            $secciones += [PSCustomObject]@{
                Nombre        = ([System.Text.Encoding]::ASCII.GetString($raw, 0, 8)).TrimEnd([char]0)
                TamanoVirtual = [BitConverter]::ToUInt32($raw, 8)
                Rva           = [BitConverter]::ToUInt32($raw, 12)
                Tamano        = [BitConverter]::ToUInt32($raw, 16)
                Puntero       = [BitConverter]::ToUInt32($raw, 20)
            }
        }

        # PE32 (32 bits) y PE32+ (64 bits) ponen el directorio de datos en
        # sitios distintos, porque en PE32+ la direccion base ocupa 8 bytes y
        # no 4. Leerlo siempre en el sitio de PE32 da importaciones basura en
        # cualquier binario de 64 bits.
        $fs.Position = $opcional
        $magic = $br.ReadUInt16()
        $dirs = $null
        $imageBase = 0
        if ($magic -eq 0x10B -and $tamOpcional -ge 96) {
            $fs.Position = $opcional + 28; $imageBase = $br.ReadUInt32()
            $fs.Position = $opcional + 92; $nDirs = $br.ReadUInt32(); $dirs = $opcional + 96
        }
        elseif ($magic -eq 0x20B -and $tamOpcional -ge 112) {
            $fs.Position = $opcional + 24; $imageBase = $br.ReadUInt64()
            $fs.Position = $opcional + 108; $nDirs = $br.ReadUInt32(); $dirs = $opcional + 112
        }

        # Una direccion de memoria (RVA) a su posicion en el archivo: la de la
        # seccion que la contiene.
        $aPosicion = {
            param([uint64]$Rva)
            foreach ($s in $secciones) {
                $alcance = [Math]::Max($s.TamanoVirtual, $s.Tamano)
                if ($Rva -ge $s.Rva -and $Rva -lt ($s.Rva + $alcance)) {
                    return [int64]($Rva - $s.Rva + $s.Puntero)
                }
            }
            return $null
        }

        $leerNombre = {
            param([int64]$Posicion)
            if ($Posicion -lt 0 -or $Posicion -ge $fs.Length) { return $null }
            $fs.Position = $Posicion
            $bytes = $br.ReadBytes(260)
            $fin = [Array]::IndexOf($bytes, [byte]0)
            if ($fin -lt 0) { $fin = $bytes.Length }
            return [System.Text.Encoding]::ASCII.GetString($bytes, 0, $fin)
        }

        $importa = New-Object 'System.Collections.Generic.List[string]'
        $diferidas = New-Object 'System.Collections.Generic.List[string]'
        $vistas  = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

        # Entrada 1 del directorio: importaciones normales, 20 bytes por DLL.
        # Entrada 13: carga diferida, 32 bytes por DLL. Las dos acaban en una
        # entrada sin nombre. El tope de 4096 es por si el archivo esta roto.
        $tablas = @(
            @{ Indice = 1;  Tamano = 20; CampoNombre = 12 }
            @{ Indice = 13; Tamano = 32; CampoNombre = 4 }
        )
        foreach ($t in $tablas) {
            if ($null -eq $dirs -or $nDirs -le $t.Indice) { continue }

            $fs.Position = $dirs + 8 * $t.Indice
            $rvaTabla = $br.ReadUInt32()
            if ($rvaTabla -eq 0) { continue }

            $inicio = & $aPosicion $rvaTabla
            if ($null -eq $inicio) { continue }

            for ($i = 0; $i -lt 4096; $i++) {
                $fs.Position = $inicio + $t.Tamano * $i
                $d = $br.ReadBytes($t.Tamano)
                if ($d.Length -lt $t.Tamano) { break }

                [uint64]$rvaNombre = [BitConverter]::ToUInt32($d, $t.CampoNombre)
                if ($rvaNombre -eq 0) { break }

                # Las de carga diferida de VC6 guardaban una direccion absoluta
                # y no una RVA; las marca el bit 0 de sus atributos apagado.
                if ($t.Indice -eq 13 -and ([BitConverter]::ToUInt32($d, 0) -band 1) -eq 0) {
                    if ($rvaNombre -lt $imageBase) { continue }
                    $rvaNombre = $rvaNombre - $imageBase
                }

                $pos = & $aPosicion $rvaNombre
                if ($null -eq $pos) { continue }
                $nombre = & $leerNombre $pos
                if ($nombre -and $vistas.Add($nombre)) {
                    $importa.Add($nombre)
                    if ($t.Indice -eq 13) { $diferidas.Add($nombre) }
                }
            }
        }

        # Entrada 14: la cabecera de .NET. Un programa .NET solo importa
        # mscoree.dll; lo que le falta, si le falta algo, es el runtime de .NET.
        $esDotNet = $false
        if ($null -ne $dirs -and $nDirs -gt 14) {
            $fs.Position = $dirs + 8 * 14
            $esDotNet = ($br.ReadUInt32() -ne 0)
        }

        return [PSCustomObject]@{
            Arquitectura = $arquitectura
            Machine      = $machine
            Secciones    = $secciones
            # Todas, incluidas las diferidas; Diferidas dice cuales lo son.
            Importa      = @($importa)
            Diferidas    = @($diferidas)
            EsDotNet     = $esDotNet
        }
    }
    catch {
        return $null
    }
    finally {
        $fs.Dispose()
    }
}

# --------------------------------------------------------------------------
# CAB
# --------------------------------------------------------------------------

function Expand-Cabinet {
    <#
        Abre un .cab con expand.exe, que viene con Windows. Devuelve $true si
        termino bien; quien llama comprueba que salio lo que esperaba, porque
        expand.exe no siempre devuelve error cuando no extrae nada.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$CabPath,
        [Parameter(Mandatory=$true)][string]$DestDir
    )

    if (-not (Test-Path -LiteralPath $DestDir)) {
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    }

    # Ruta completa y no "expand": un expand.exe cualquiera en el PATH o en la
    # carpeta actual no deberia poder colarse aqui.
    #
    # -R es imprescindible. Con un CAB de UN solo archivo, expand.exe lo saca
    # con el nombre del propio .cab y no con el que lleva dentro, como si
    # fuera un archivo comprimido suelto. Un bundle con una sola carga en su
    # contenedor -lo normal si lleva un unico MSI- se quedaba sin ella.
    $expand = Join-Path $env:SystemRoot 'System32\expand.exe'
    $run = Invoke-NativeCommand -FilePath $expand -Arguments @('-R', '-F:*', $CabPath, $DestDir) -Quiet
    return ($run.ExitCode -eq 0)
}

function Expand-ZipArchive {
    <#
    .SYNOPSIS
        Saca un .zip a una carpeta. Es lo que usa el kit en vez de Expand-Archive.
    .DESCRIPTION
        Mismo motor de .NET que Expand-Archive, sin su contabilidad por archivo,
        que es donde se le iba el tiempo: el zip de Node (2.032 archivos) tardaba
        8,1 s y ahora 3,0; encima de una instalacion previa, 11,4 s frente a 2,8.

        Se extrae primero a una carpeta hermana y solo al final se pone en su
        sitio, asi que un fallo a mitad no deja en -Destino media instalacion que
        la siguiente ejecucion daria por buena.

        Al ponerla en su sitio, lo que trae el zip SUSTITUYE a lo que hubiera con
        el mismo nombre, y lo demas se respeta: el data\ de VS Code, que no viene
        en el zip, sigue ahi despues de actualizarlo.

        -QuitarEnvoltorio: si todo el zip cuelga de una sola carpeta
        (jdk-21.0.12+8\, apache-maven-3.9.9\), su contenido sube un nivel. Era el
        mismo bloque de "extraer, mirar y mover" copiado en seis sitios.

        Nada sale de -Destino: una entrada con ..\ en el nombre (zip slip) hace
        fallar la extraccion entera antes de escribir nada.

        Lanza una excepcion si algo falla, igual que Expand-Archive.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Destino,
        [switch]$QuitarEnvoltorio
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $destino = [IO.Path]::GetFullPath($Destino).TrimEnd('\')
    $temp = "$destino.part-" + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $base = $temp + '\'

    $zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Path).ProviderPath)
    try {
        $entradas = @($zip.Entries)
        $nombres = @($entradas | ForEach-Object { $_.FullName -replace '\\', '/' })

        $quitar = 0
        if ($QuitarEnvoltorio -and $nombres.Count -gt 0) {
            $raices = @($nombres | ForEach-Object { $_.Split('/')[0] } | Select-Object -Unique)
            $sueltas = @($nombres | Where-Object { $_ -notmatch '^[^/]+/' })
            if ($raices.Count -eq 1 -and $sueltas.Count -eq 0) { $quitar = $raices[0].Length + 1 }
        }

        # Primero se calcula y comprueba cada destino; despues se escribe.
        $plan = New-Object 'System.Collections.Generic.List[object]'
        for ($i = 0; $i -lt $entradas.Count; $i++) {
            $rel = $nombres[$i].Substring($quitar)
            if (-not $rel) { continue }
            $t = [IO.Path]::GetFullPath([IO.Path]::Combine($base, $rel))
            if (-not $t.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
                throw "El zip intenta escribir fuera de su carpeta: $($entradas[$i].FullName)"
            }
            $plan.Add(@($entradas[$i], $t, $rel.EndsWith('/')))
        }

        [void][IO.Directory]::CreateDirectory($temp)
        foreach ($p in $plan) {
            if ($p[2]) { [void][IO.Directory]::CreateDirectory($p[1]); continue }
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($p[1]))
            [IO.Compression.ZipFileExtensions]::ExtractToFile($p[0], $p[1], $true)
        }
    }
    catch {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
    finally { $zip.Dispose() }

    Publish-ExtractedFolder -Temporal $temp -Destino $destino
}

function Publish-ExtractedFolder {
    <#
        Pone en -Destino lo que se acaba de extraer en -Temporal, y borra la
        temporal. Si -Destino no existe, es un renombrado (mismo volumen: nada
        que copiar). Si existe, cada cosa de la temporal SUSTITUYE a la del
        mismo nombre y lo demas se queda: ver Expand-ZipArchive.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Temporal,
        [Parameter(Mandatory=$true)][string]$Destino
    )

    try {
        if (-not (Test-Path -LiteralPath $Destino)) {
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Destino))
            Move-Item -LiteralPath $Temporal -Destination $Destino
            return
        }
        foreach ($h in @(Get-ChildItem -LiteralPath $Temporal -Force)) {
            $d = Join-Path $Destino $h.Name
            if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force }
            Move-Item -LiteralPath $h.FullName -Destination $d
        }
    }
    finally {
        Remove-Item -LiteralPath $Temporal -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Expand-TarArchive {
    <#
    .SYNOPSIS
        Saca un .tar.gz a una carpeta, con las mismas garantias que Expand-ZipArchive.
    .DESCRIPTION
        Con el tar.exe que trae Windows desde la version 1803 (bsdtar), por ruta
        completa: uno cualquiera en el PATH -el de Git, por ejemplo, que no
        entiende las rutas de Windows- no deberia colarse aqui.

        bsdtar ya se niega a escribir fuera de la carpeta (rutas con .. o
        absolutas), y se extrae a una temporal hermana: un fallo a mitad no deja
        nada en -Destino.

        -QuitarEnvoltorio: si todo cuelga de una sola carpeta (el python\ de
        python-build-standalone), su contenido sube un nivel.

        Lanza una excepcion si algo falla.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Destino,
        [switch]$QuitarEnvoltorio
    )

    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (-not (Test-Path -LiteralPath $tar)) {
        throw "Este Windows no trae tar.exe (llego con Windows 10 1803); no se puede abrir $Path."
    }

    $destino = [IO.Path]::GetFullPath($Destino).TrimEnd('\')
    $temp = "$destino.part-" + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    [void][IO.Directory]::CreateDirectory($temp)

    try {
        $r = Invoke-NativeCommand -FilePath $tar -Arguments @('-xzf', (Resolve-Path -LiteralPath $Path).ProviderPath, '-C', $temp) -Quiet
        if ($r.ExitCode -ne 0) { throw "tar no pudo abrir $Path (codigo $($r.ExitCode)): $($r.Output.Trim())" }

        $origen = $temp
        if ($QuitarEnvoltorio) {
            $hijos = @(Get-ChildItem -LiteralPath $temp -Force)
            if ($hijos.Count -eq 1 -and $hijos[0].PSIsContainer) { $origen = $hijos[0].FullName }
        }
    }
    catch {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }

    if ($origen -ne $temp) {
        # La carpeta de dentro pasa a ser la temporal: asi Publish la trata igual.
        $plano = "$temp-x"
        Move-Item -LiteralPath $origen -Destination $plano
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        $temp = $plano
    }
    Publish-ExtractedFolder -Temporal $temp -Destino $destino
}

function Copy-FileRange {
    <# Copia un trozo de un archivo a otro, sin cargarlo entero en memoria. #>
    param(
        [string]$Source,
        [int64]$Offset,
        [int64]$Length,
        [string]$Destination
    )

    $in = [System.IO.File]::OpenRead($Source)
    try {
        $out = [System.IO.File]::Create($Destination)
        try {
            $in.Position = $Offset
            $buffer = New-Object byte[] 1048576
            $quedan = $Length
            while ($quedan -gt 0) {
                $n = $in.Read($buffer, 0, [int][Math]::Min($buffer.Length, $quedan))
                if ($n -le 0) { throw "El archivo se acaba antes de lo que dice su cabecera." }
                $out.Write($buffer, 0, $n)
                $quedan -= $n
            }
        }
        finally { $out.Dispose() }
    }
    finally { $in.Dispose() }
}

# --------------------------------------------------------------------------
# Bundles WiX Burn
# --------------------------------------------------------------------------

function Get-BurnContainerInfo {
    <#
    .SYNOPSIS
        Donde estan los contenedores de un bundle WiX Burn.
    .DESCRIPTION
        Un bundle Burn es un .exe normal -el motor, que Burn llama stub- con sus
        contenedores pegados detras, cada uno un CAB. El primero lleva la
        interfaz del instalador y el manifiesto; los siguientes, las cargas de
        verdad (MSI, CAB...). Los tamanos de todos estan en la seccion
        .wixburn del propio stub.

        Leerlos de ahi y no buscando la cabecera "MSCF" de los CAB por el
        archivo es lo que lo hace fiable: esos cuatro bytes pueden aparecer por
        casualidad dentro de cualquier binario grande.

        Los contenedores NO van todos seguidos. Un bundle firmado se firma dos
        veces: primero el motor con la interfaz, y despues el bundle entero. La
        primera firma se queda en medio, entre el primer contenedor y el
        segundo, y la cabecera dice donde empieza y cuanto mide. Contar desde
        el final del primer contenedor cae 16 KB antes de tiempo: comprobado
        con el redistribuible de Visual C++ 2012.

        Devuelve $null si no es un bundle, o si la cabecera no tiene la forma
        esperada: mejor eso que recortar el archivo por donde no es.
    #>
    param([Parameter(Mandatory=$true)][string]$FilePath)

    $pe = Get-PeInfo -FilePath $FilePath
    if (-not $pe) { return $null }

    $seccion = @($pe.Secciones | Where-Object { $_.Nombre -eq '.wixburn' })
    if ($seccion.Count -eq 0) { return $null }

    try {
        $fs = [System.IO.File]::OpenRead($FilePath)
    }
    catch {
        return $null
    }

    try {
        $br = New-Object System.IO.BinaryReader($fs)
        $fs.Position = $seccion[0].Puntero

        # magic, version, GUID del bundle (16), stub, checksum, donde quedo la
        # firma original y cuanto mide, formato y numero de contenedores;
        # detras, el tamano de cada uno.
        if ($br.ReadUInt32() -ne 0x00F14300) { return $null }
        $version  = $br.ReadUInt32()
        $null     = $br.ReadBytes(16)
        $stub     = [int64]$br.ReadUInt32()
        $null     = $br.ReadUInt32()
        $firmaPos = [int64]$br.ReadUInt32()
        $firmaTam = [int64]$br.ReadUInt32()
        $formato  = $br.ReadUInt32()
        $n        = $br.ReadUInt32()

        # Formato 1 es CAB, el unico que existe. 64 contenedores es un tope
        # holgado: cualquier cifra mayor es una cabecera rota.
        if ($formato -ne 1 -or $n -lt 1 -or $n -gt 64) { return $null }

        $contenedores = @()
        $pos = $stub
        for ($i = 0; $i -lt $n; $i++) {
            $tam = [int64]$br.ReadUInt32()
            $contenedores += [PSCustomObject]@{ Indice = $i; Offset = $pos; Tamano = $tam }
            $pos += $tam

            # Tras el primero, la firma original del motor si la hay.
            if ($i -eq 0 -and $firmaPos -gt 0 -and ($firmaPos + $firmaTam) -gt $pos) {
                $pos = $firmaPos + $firmaTam
            }
        }
        if ($pos -gt $fs.Length) { return $null }

        # Cada contenedor tiene que empezar como un CAB. Si no, la cabecera
        # no es la que creemos y lo que saliera de aqui seria basura.
        foreach ($c in $contenedores) {
            $fs.Position = $c.Offset
            if ($br.ReadUInt32() -ne 0x4643534D) { return $null }    # "MSCF"
        }

        return [PSCustomObject]@{
            Version      = $version
            Stub         = $stub
            Contenedores = $contenedores
        }
    }
    catch {
        return $null
    }
    finally {
        $fs.Dispose()
    }
}

function Test-PayloadHash {
    <#
        Comprueba un archivo contra el hash que declara un manifiesto. El
        algoritmo se deduce de la longitud: WiX 3 usa SHA-1 y versiones
        posteriores SHA-256 o SHA-512. Sin hash, o con uno que no se reconoce,
        la respuesta es $false: no comprobado no es lo mismo que correcto.
    #>
    param([string]$FilePath, [string]$Hash)

    if ([string]::IsNullOrWhiteSpace($Hash)) { return $false }
    $algoritmo = switch ($Hash.Length) {
        40      { 'SHA1' }
        64      { 'SHA256' }
        128     { 'SHA512' }
        default { $null }
    }
    if (-not $algoritmo) { return $false }

    return ((Get-FileHash -LiteralPath $FilePath -Algorithm $algoritmo).Hash -eq $Hash.ToUpperInvariant())
}

function Expand-BurnBundle {
    <#
    .SYNOPSIS
        Saca las cargas de un bundle WiX Burn sin ejecutarlo.
    .DESCRIPTION
        Es lo que "/layout" no hace cuando las cargas van EMBEBIDAS, que es lo
        normal en un instalador de un solo archivo: ahi /layout devuelve 0 y
        solo copia el propio .exe. Antes la unica salida era dark.exe, del WiX
        Toolset, que no hay forma de tener en un equipo bloqueado.

        Tres pasos, y ninguno ejecuta el bundle:

          1. Cada contenedor se recorta a un .cab aparte (Get-BurnContainerInfo
             dice donde empieza y cuanto mide) y se abre con expand.exe.
          2. El manifiesto -el archivo "0" del primer contenedor- dice el
             nombre real de cada carga, en que contenedor va y su hash.
          3. Cada carga se comprueba contra ese hash antes de dejarla en su
             sitio, con la misma estructura de carpetas que dejaria /layout.

        El hash no sobra aunque el bundle este firmado. La firma dice que el
        .exe no ha cambiado; el hash, que lo que el kit ha sacado de dentro es
        exactamente lo que el bundle declaraba. Un recorte desplazado un byte
        produciria un archivo con el nombre correcto y el contenido roto.

        Devuelve las cargas extraidas y las que el bundle NO lleva dentro (las
        descarga de internet al instalar), o $null si algo falla, despues de
        explicar el motivo.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$DestDir
    )

    $info = Get-BurnContainerInfo -FilePath $Path
    if (-not $info) {
        Write-Log "No tiene la forma de un bundle WiX Burn que el kit sepa abrir." "ERROR"
        return $null
    }

    $trabajo = Join-Path ([System.IO.Path]::GetTempPath()) ("criisdevkit-burn-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $trabajo -Force | Out-Null

    try {
        $dirs = @{}
        foreach ($c in $info.Contenedores) {
            $cab = Join-Path $trabajo "c$($c.Indice).cab"
            $dir = Join-Path $trabajo "c$($c.Indice)"
            Copy-FileRange -Source $Path -Offset $c.Offset -Length $c.Tamano -Destination $cab
            if (-not (Expand-Cabinet -CabPath $cab -DestDir $dir)) {
                Write-Log "expand.exe no pudo abrir el contenedor $($c.Indice) del bundle." "ERROR"
                return $null
            }
            $dirs[$c.Indice] = $dir
        }

        $rutaManifiesto = Join-Path $dirs[0] '0'
        if (-not (Test-Path -LiteralPath $rutaManifiesto)) {
            Write-Log "El bundle no lleva manifiesto donde Burn lo pone." "ERROR"
            return $null
        }

        # XmlResolver a $null: el manifiesto viene de un archivo ajeno, y no
        # tiene por que ir a buscar nada fuera.
        $doc = New-Object System.Xml.XmlDocument
        $doc.XmlResolver = $null
        $doc.Load($rutaManifiesto)

        $indices = @{}
        foreach ($c in $doc.SelectNodes("/*[local-name()='BurnManifest']/*[local-name()='Container']")) {
            if ($c.GetAttribute('Attached') -eq 'yes' -and $c.GetAttribute('AttachedIndex')) {
                $indices[$c.GetAttribute('Id')] = [int]$c.GetAttribute('AttachedIndex')
            }
        }

        $extraidas = @()
        $externas  = @()
        foreach ($p in $doc.SelectNodes("/*[local-name()='BurnManifest']/*[local-name()='Payload']")) {
            $relativa = $p.GetAttribute('FilePath')

            # Una ruta absoluta o con ".." en el manifiesto escribiria fuera de
            # la carpeta destino. Ningun bundle legitimo lo necesita.
            if ([string]::IsNullOrWhiteSpace($relativa) -or [System.IO.Path]::IsPathRooted($relativa) -or
                ($relativa -split '[\\/]') -contains '..') {
                Write-Log "El manifiesto declara una carga con una ruta no valida: '$relativa'" "ERROR"
                return $null
            }

            $contenedor = $p.GetAttribute('Container')
            if (-not $contenedor) { $externas += $relativa; continue }
            if (-not $indices.ContainsKey($contenedor) -or -not $dirs.ContainsKey($indices[$contenedor])) {
                Write-Log "La carga $relativa dice ir en un contenedor que el bundle no tiene." "ERROR"
                return $null
            }

            $origen = Join-Path $dirs[$indices[$contenedor]] $p.GetAttribute('SourcePath')
            if (-not (Test-Path -LiteralPath $origen)) {
                Write-Log "Falta la carga $relativa dentro de su contenedor." "ERROR"
                return $null
            }
            if (-not (Test-PayloadHash -FilePath $origen -Hash $p.GetAttribute('Hash'))) {
                Write-Log "La carga $relativa no coincide con el hash que declara el bundle." "ERROR"
                Write-Log "  No se usa: o el bundle esta danado o el kit lo ha leido mal." "WARN"
                return $null
            }

            $destino = Join-Path $DestDir $relativa
            $padre = Split-Path -Parent $destino
            if (-not (Test-Path -LiteralPath $padre)) { New-Item -ItemType Directory -Path $padre -Force | Out-Null }
            Copy-Item -LiteralPath $origen -Destination $destino -Force
            $extraidas += $relativa
        }

        if ($extraidas.Count -eq 0) {
            Write-Log "El bundle no lleva ninguna carga dentro." "ERROR"
            if ($externas.Count -gt 0) {
                Write-Log "  Las $($externas.Count) que declara las descarga de internet al instalar." "WARN"
            }
            return $null
        }

        return [PSCustomObject]@{
            Extraidas = $extraidas
            Externas  = $externas
        }
    }
    catch {
        Write-Log "No se pudo abrir el bundle: $($_.Exception.Message)" "ERROR"
        return $null
    }
    finally {
        Remove-Item -LiteralPath $trabajo -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --------------------------------------------------------------------------
# MSI
# --------------------------------------------------------------------------

function Invoke-ComMember {
    <#
        WindowsInstaller.Installer es un objeto COM sin biblioteca de tipos que
        PowerShell sepa leer: $installer.OpenDatabase(...) falla con "no
        contiene un metodo llamado OpenDatabase". Hay que llamarlo a mano.
    #>
    param(
        $Objeto,
        [string]$Nombre,
        [ValidateSet('InvokeMethod', 'GetProperty')][string]$Tipo = 'InvokeMethod',
        [object[]]$Argumentos = @()
    )

    # PowerShell envuelve casi todo en un PSObject (lo que devuelve Join-Path,
    # por ejemplo), y COM no sabe que hacer con eso: "los tipos no coinciden".
    $crudos = [object[]]@($Argumentos | ForEach-Object { $_.PSObject.BaseObject })
    return $Objeto.GetType().InvokeMember($Nombre, [System.Reflection.BindingFlags]$Tipo, $null, $Objeto, $crudos)
}

function Get-MsiRows {
    <# Las filas de una consulta a la base de datos de un MSI, como texto. #>
    param($Database, [string]$Query, [int]$Columnas)

    $vista = Invoke-ComMember $Database 'OpenView' -Argumentos @($Query)
    try {
        Invoke-ComMember $vista 'Execute' | Out-Null
        $filas = @()
        while ($registro = Invoke-ComMember $vista 'Fetch') {
            $fila = @()
            for ($i = 1; $i -le $Columnas; $i++) {
                $fila += [string](Invoke-ComMember $registro 'StringData' 'GetProperty' @($i))
            }
            $filas += , $fila
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($registro)
        }
        return , $filas
    }
    finally {
        Invoke-ComMember $vista 'Close' | Out-Null
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($vista)
    }
}

function Expand-MsiFiles {
    <#
    .SYNOPSIS
        Saca los archivos de un MSI sin instalarlo y sin msiexec.
    .DESCRIPTION
        Un MSI es una base de datos. Su tabla File dice como se llama de verdad
        cada archivo, y su tabla Media en que CAB va. Dentro del CAB los
        archivos no llevan su nombre sino su clave en la tabla
        (F_CENTRAL_msvcr110_x86 y no msvcr110.dll). Asi que se abre la base de
        datos en solo lectura, se abre el CAB con expand.exe y se renombra.

        "msiexec /a" hace lo mismo en un paso, y es lo que usa Install-NoAdmin.
        Pero es una instalacion -administrativa, pero instalacion- y una
        directiva de empresa puede bloquearla. Leer una base de datos no lo es.

        Solo sabe de CAB externos, junto al MSI, que es como salen de un bundle
        Burn. Uno embebido en el propio MSI ("#cab1.cab") lo rechaza diciendolo,
        en vez de devolver una carpeta vacia.

        Deja los archivos en DestDir, sin subcarpetas. Devuelve sus nombres, o
        $null si algo falla.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$MsiPath,
        [Parameter(Mandatory=$true)][string]$DestDir
    )

    $MsiPath = (Resolve-Path -LiteralPath $MsiPath).Path
    $nombreMsi = Split-Path -Leaf $MsiPath
    $installer = $null
    $db = $null

    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        # 0 = msiOpenDatabaseModeReadOnly
        $db = Invoke-ComMember $installer 'OpenDatabase' -Argumentos @($MsiPath, 0)
        $archivos = Get-MsiRows -Database $db -Query 'SELECT `File`, `FileName` FROM `File`' -Columnas 2
        $medios   = Get-MsiRows -Database $db -Query 'SELECT `Cabinet` FROM `Media`' -Columnas 1
    }
    catch {
        Write-Log "No se pudo leer $nombreMsi como base de datos: $($_.Exception.Message)" "ERROR"
        return $null
    }
    finally {
        # Sin soltarla, la base de datos deja el .msi abierto y quien llama no
        # puede borrar su carpeta temporal.
        if ($db)        { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($db) }
        if ($installer) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($installer) }
    }

    if ($archivos.Count -eq 0) {
        Write-Log "$nombreMsi no lleva ningun archivo." "ERROR"
        return $null
    }

    $cabs = @($medios | ForEach-Object { $_[0] } | Where-Object { $_ })
    $embebidos = @($cabs | Where-Object { $_.StartsWith('#') })
    if ($embebidos.Count -gt 0) {
        Write-Log "$nombreMsi lleva sus archivos dentro del propio MSI ($($embebidos -join ', '))." "ERROR"
        Write-Log "  Este camino solo sabe de CAB sueltos junto al MSI." "WARN"
        return $null
    }
    if ($cabs.Count -eq 0) {
        Write-Log "$nombreMsi no dice en que CAB van sus archivos." "ERROR"
        return $null
    }

    $trabajo = Join-Path ([System.IO.Path]::GetTempPath()) ("criisdevkit-msi-" + [Guid]::NewGuid().ToString('N'))
    try {
        foreach ($cab in $cabs) {
            $ruta = Join-Path (Split-Path -Parent $MsiPath) $cab
            if (-not (Test-Path -LiteralPath $ruta)) {
                Write-Log "Falta $cab junto a $nombreMsi." "ERROR"
                return $null
            }
            if (-not (Expand-Cabinet -CabPath $ruta -DestDir $trabajo)) {
                Write-Log "expand.exe no pudo abrir $cab." "ERROR"
                return $null
            }
        }

        # Primero se comprueba todo y despues se copia: un fallo a mitad dejaria
        # en DestDir media extraccion con aspecto de completa.
        $plan = @()
        foreach ($f in $archivos) {
            # FileName es "corto|largo", o solo uno si ya cabe en 8.3.
            $nombre = ($f[1] -split '\|')[-1]
            if (@($plan | Where-Object { $_.Nombre -eq $nombre }).Count -gt 0) {
                Write-Log "$nombreMsi instala dos archivos llamados $nombre en carpetas distintas." "ERROR"
                Write-Log "  Sin subcarpetas no caben los dos, y no se extrae a medias." "WARN"
                return $null
            }

            $origen = Join-Path $trabajo $f[0]
            if (-not (Test-Path -LiteralPath $origen)) {
                Write-Log "$nombre ($($f[0])) no esta en el CAB de $nombreMsi." "ERROR"
                return $null
            }
            $plan += [PSCustomObject]@{ Nombre = $nombre; Origen = $origen }
        }

        if (-not (Test-Path -LiteralPath $DestDir)) {
            New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
        }
        foreach ($p in $plan) {
            Copy-Item -LiteralPath $p.Origen -Destination (Join-Path $DestDir $p.Nombre) -Force
        }

        return @($plan.Nombre)
    }
    finally {
        Remove-Item -LiteralPath $trabajo -Recurse -Force -ErrorAction SilentlyContinue
    }
}
