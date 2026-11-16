#Requires -Version 5.1
<#
    Los runtimes de Visual C++ que necesitan programas ajenos: 2012, 2013 y
    2015-2022

    Parte de lib\Common.ps1, que es quien carga este archivo. No se toma
    por separado: los scripts siguen haciendo un unico dot-source de
    Common.ps1 y no se enteran de esta division.

    No es un runtime del catalogo, y no por descuido. Todo lo del catalogo es
    una herramienta que TU usas: tiene shell, va al PATH, se actualiza y viaja
    en un bundle. Esto son unas DLL que necesita un programa de otro, y su sitio
    es la carpeta de ese programa, que es el primer lugar donde Windows las
    busca. Desde Visual C++ 2010 el runtime no pasa por WinSxS, asi que
    Microsoft admite este despliegue "local" sin manifiestos ni registro.
#>

function Get-VCRuntimeCatalog {
    <#
        Una entrada por version. El redistribuible se fija por URL y SHA-256:
        Microsoft no publica un indice que consultar, como el de .NET, y no
        hace falta.

          2012 y 2013   salieron de soporte; su ultima build es la que habra,
                        asi que fijarla no caduca.
          2015-2022     es UN solo runtime, compatible hacia atras: sirve a un
                        programa hecho con cualquiera de esas versiones, siempre
                        que la build sea igual o mas nueva que la suya. Esta si
                        sigue saliendo; se fija una y se cambia a mano.

        Sufijo es como lleva la version en el nombre de sus DLL (msvcr110.dll).
        Basicas son las tres que se miran para saber si estan: la primera es la
        que no falta nunca (la marca de "ya extraido"), y la ultima la de MFC.
        Alias son los nombres con que alguien puede pedir esa version.

        Las URL de 2013 y 2015-2022 son las de destino de los enlaces aka.ms de
        Microsoft: el aka.ms cambia de archivo cuando sale otra build, y entonces
        el SHA-256 fijado aqui dejaria de cuadrar.
    #>
    return @(
        [PSCustomObject]@{
            Version = '2012'; Nombre = 'Visual C++ 2012'; Sufijo = '110'; Build = '11.0.61030'
            Basicas = @('msvcr110.dll', 'msvcp110.dll', 'mfc110.dll'); Alias = @('2012')
            Descargas = @{
                x86 = [PSCustomObject]@{
                    Url    = 'https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x86.exe'
                    Sha256 = 'b924ad8062eaf4e70437c8be50fa612162795ff0839479546ce907ffa8d6e386'
                }
                x64 = [PSCustomObject]@{
                    Url    = 'https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x64.exe'
                    Sha256 = '681be3e5ba9fd3da02c09d7e565adfa078640ed66a0d58583efad2c1e3cc4064'
                }
            }
        }
        [PSCustomObject]@{
            Version = '2013'; Nombre = 'Visual C++ 2013'; Sufijo = '120'; Build = '12.0.40664'
            Basicas = @('msvcr120.dll', 'msvcp120.dll', 'mfc120.dll'); Alias = @('2013')
            Descargas = @{
                x86 = [PSCustomObject]@{
                    Url    = 'https://download.visualstudio.microsoft.com/download/pr/10912113/5da66ddebb0ad32ebd4b922fd82e8e25/vcredist_x86.exe'
                    Sha256 = '53b605d1100ab0a88b867447bbf9274b5938125024ba01f5105a9e178a3dcdbd'
                }
                x64 = [PSCustomObject]@{
                    Url    = 'https://download.visualstudio.microsoft.com/download/pr/10912041/cee5d6bca2ddbcd039da727bf4acb48a/vcredist_x64.exe'
                    Sha256 = 'a4bba7701e355ae29c403431f871a537897c363e215cafe706615e270984f17c'
                }
            }
        }
        [PSCustomObject]@{
            Version = '2015-2022'; Nombre = 'Visual C++ 2015-2022'; Sufijo = '140'; Build = '14.44.35211'
            Basicas = @('vcruntime140.dll', 'msvcp140.dll', 'mfc140.dll'); Alias = @('2015', '2017', '2019', '2022', '2015-2022')
            Descargas = @{
                x86 = [PSCustomObject]@{
                    Url    = 'https://download.visualstudio.microsoft.com/download/pr/e9604e21-4b79-4096-a4b3-1b63d4b55b4d/0C09F2611660441084CE0DF425C51C11E147E6447963C3690F97E0B25C55ED64/VC_redist.x86.exe'
                    Sha256 = '0c09f2611660441084ce0df425c51c11e147e6447963c3690f97e0b25c55ed64'
                }
                x64 = [PSCustomObject]@{
                    Url    = 'https://download.visualstudio.microsoft.com/download/pr/e9604e21-4b79-4096-a4b3-1b63d4b55b4d/CC0FF0EB1DC3F5188AE6300FAEF32BF5BEEBA4BDD6E8E445A9184072096B713B/VC_redist.x64.exe'
                    Sha256 = 'cc0ff0eb1dc3f5188ae6300faef32bf5beeba4bdd6e8e445a9184072096b713b'
                }
            }
        }
    )
}

function Get-VCRuntimeEntry {
    <#
        La entrada del catalogo para un nombre de version, contando alias:
        2019 es 2015-2022. Devuelve $null si no hay ninguna.
    #>
    param([Parameter(Mandatory=$true)][string]$Version)
    return @(Get-VCRuntimeCatalog | Where-Object { $_.Alias -contains $Version.Trim() })[0]
}

function Get-VCRuntimeImportSuffix {
    <#
        Si una DLL tiene nombre de runtime de Visual C++, el numero de version
        que lleva (110 en mfc110u.dll, 140 en vcruntime140_1.dll). Si no, $null.

        msvcrt.dll NO cuenta: es de Windows, no de ninguna version de Visual C++.
    #>
    param([string]$Dll)
    if ($Dll -match '^(msvc[rp]|mfc|mfcm|vcomp|vcamp|vccorlib|atl|concrt|vcruntime)(\d{2,3})(u|d|ud|_[a-z0-9_]+)?\.dll$') {
        return $Matches[2]
    }
    return $null
}

function Get-VCRuntimeVersionsFor {
    <#
        Que versiones del catalogo pide un programa, mirando lo que importa.
        Puede ser mas de una: un .exe de 2015 que carga una DLL de 2012.
    #>
    param([AllowEmptyCollection()][string[]]$Importa = @())

    $sufijos = @($Importa | ForEach-Object { Get-VCRuntimeImportSuffix -Dll $_ } | Where-Object { $_ } | Select-Object -Unique)
    return @(Get-VCRuntimeCatalog | Where-Object { $sufijos -contains $_.Sufijo })
}

function Get-VCRuntimeFolder {
    <#
        Donde deja el kit las DLL de una version y arquitectura. Una carpeta
        hermana mas, como Python\ o Java\: VCRuntime\vc-2012\x86.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Version,
        [Parameter(Mandatory=$true)][ValidateSet('x86', 'x64')][string]$Arch
    )
    return (Join-Path $WorkspaceRoot "VCRuntime\vc-$Version\$Arch")
}

function Get-SystemDllFolder {
    <#
        Donde busca Windows las DLL del sistema para un programa de esa
        arquitectura. Es al reves de lo que sugieren los nombres, y por eso
        existe esta funcion: en un Windows de 64 bits, las de 64 estan en
        System32 y las de 32 en SysWOW64.

        Desde un PowerShell de 32 bits, "System32" se redirige en silencio a
        SysWOW64; para ver el de verdad hay que pedir Sysnative.

        Devuelve $null si esa arquitectura no existe en este Windows (x64 en
        un Windows de 32 bits).
    #>
    param([Parameter(Mandatory=$true)][ValidateSet('x86', 'x64')][string]$Arch)

    $win = $env:SystemRoot
    if (-not [Environment]::Is64BitOperatingSystem) {
        if ($Arch -eq 'x86') { return (Join-Path $win 'System32') }
        return $null
    }
    if ($Arch -eq 'x86') { return (Join-Path $win 'SysWOW64') }
    if ([Environment]::Is64BitProcess) { return (Join-Path $win 'System32') }
    return (Join-Path $win 'Sysnative')
}

function Resolve-VCRuntimeDlls {
    <#
    .SYNOPSIS
        Que DLL del runtime necesita un programa, contando las que piden ellas.
    .DESCRIPTION
        Un programa MFC importa mfc110.dll y nada mas del runtime, pero
        mfc110.dll importa a su vez msvcr110.dll. Copiar solo la primera da el
        mismo error de antes, con otro nombre. Asi que se sigue la cadena.

        -Importa es lo que importa el programa. -ImportsDe dice, para cada DLL
        del runtime, lo que importa ella; lo que no este ahi (kernel32.dll y
        demas) no es del runtime y no se sigue.

        Devuelve los nombres en minusculas, en el orden en que aparecen.
    #>
    param(
        [AllowEmptyCollection()][string[]]$Importa = @(),
        [Parameter(Mandatory=$true)][hashtable]$ImportsDe
    )

    $necesarias = New-Object 'System.Collections.Generic.List[string]'
    $pendientes = New-Object 'System.Collections.Generic.Queue[string]'
    foreach ($i in $Importa) { $pendientes.Enqueue($i.ToLowerInvariant()) }

    while ($pendientes.Count -gt 0) {
        $n = $pendientes.Dequeue()
        if (-not $ImportsDe.ContainsKey($n) -or $necesarias.Contains($n)) { continue }
        $necesarias.Add($n)
        foreach ($i in @($ImportsDe[$n])) { $pendientes.Enqueue($i.ToLowerInvariant()) }
    }

    return @($necesarias)
}

function Get-OtherVCRuntimeImports {
    <#
        De lo que importa un programa, lo que parece runtime de Visual C++ de
        OTRA version. Sirve para el caso en que el programa no pide nada de la
        version que se le ofrece: "importa msvcr100.dll" dice en una linea que
        lo que hace falta es 2010, no 2012.

        -Sufijo admite varios: los de todo el catalogo, para decir que pide una
        version que el kit no trae.
    #>
    param(
        [AllowEmptyCollection()][string[]]$Importa = @(),
        [Parameter(Mandatory=$true)][string[]]$Sufijo
    )

    return @($Importa | Where-Object {
        $s = Get-VCRuntimeImportSuffix -Dll $_
        $s -and ($Sufijo -notcontains $s)
    })
}

function Select-VCRuntimeDlls {
    <#
    .SYNOPSIS
        De lo que ha salido de cada MSI del redistribuible, lo de una arquitectura.
    .DESCRIPTION
        El redistribuible x64 de 2015-2022 no lleva solo las de x64: trae un
        tercer MSI para Windows en ARM, con 25 DLL de ARM64 y los MISMOS nombres.
        Sacarlos todos en una carpeta dejaba que esas pisaran a las buenas, y un
        programa de 64 bits habria fallado con 0xc000007b. Paso con la build
        14.44.35211.

        -Carpetas es una carpeta por MSI, ya extraida. Se usa una solo si TODAS
        sus DLL son de -Arch. No se escogen DLL sueltas: el MSI de ARM lleva
        tambien tres de x64, que son las de la emulacion en ARM y no las del
        runtime de x64.

        Copia lo de las carpetas usadas a -Destino y devuelve una fila por
        carpeta (Carpeta, Usada, Motivo). Devuelve $null si dos carpetas usadas
        traen el mismo nombre con distinto contenido: no hay forma buena de
        elegir, y mejor no dejar nada que dejar la equivocada.
    #>
    param(
        [Parameter(Mandatory=$true)][string[]]$Carpetas,
        [Parameter(Mandatory=$true)][ValidateSet('x86', 'x64')][string]$Arch,
        [Parameter(Mandatory=$true)][string]$Destino
    )

    $filas = @()
    $usadas = @()
    foreach ($c in $Carpetas) {
        $dlls = @(Get-ChildItem -LiteralPath $c -Filter *.dll -File -ErrorAction SilentlyContinue)
        $archs = @($dlls | ForEach-Object { $i = Get-PeInfo -FilePath $_.FullName; if ($i) { $i.Arquitectura } else { '?' } } | Select-Object -Unique)

        if ($dlls.Count -eq 0) {
            $filas += [PSCustomObject]@{ Carpeta = $c; Usada = $false; Motivo = 'no lleva DLL' }
        }
        elseif ($archs.Count -eq 1 -and $archs[0] -eq $Arch) {
            $filas += [PSCustomObject]@{ Carpeta = $c; Usada = $true; Motivo = "$($dlls.Count) DLL de $Arch" }
            $usadas += $c
        }
        else {
            $filas += [PSCustomObject]@{ Carpeta = $c; Usada = $false; Motivo = "es de $($archs -join ' y ')" }
        }
    }

    # Primero se comprueba todo y despues se copia, para no dejar media
    # carpeta si aparece un choque a mitad.
    $deDonde = @{}
    foreach ($c in $usadas) {
        foreach ($f in (Get-ChildItem -LiteralPath $c -File)) {
            $k = $f.Name.ToLowerInvariant()
            if ($deDonde.ContainsKey($k)) {
                if ((Get-FileSha256 -FilePath $deDonde[$k]) -ne (Get-FileSha256 -FilePath $f.FullName)) {
                    Write-Log "Dos paquetes del redistribuible traen $($f.Name) distinto." "ERROR"
                    return $null
                }
                continue
            }
            $deDonde[$k] = $f.FullName
        }
    }

    if (-not (Test-Path -LiteralPath $Destino)) { New-Item -ItemType Directory -Path $Destino -Force | Out-Null }
    foreach ($k in $deDonde.Keys) {
        Copy-Item -LiteralPath $deDonde[$k] -Destination (Join-Path $Destino (Split-Path -Leaf $deDonde[$k])) -Force
    }
    return $filas
}

# --------------------------------------------------------------------------
# Por que no arranca un programa
# --------------------------------------------------------------------------
#
# El error de Windows -"falta mfc110.dll"- solo nombra la PRIMERA DLL que no
# encuentra. Se copia esa, y sale otra; y si la copiada es de la arquitectura
# equivocada, sale un 0xc000007b que ya no nombra nada. Esto recorre todo lo
# que pide el programa de una vez, como lo buscaria Windows, y dice de cada
# cosa que falta de donde sale.

function Find-DllForApp {
    <#
        Donde encontraria Windows una DLL para un programa, en su orden de
        busqueda (con SafeDllSearchMode, que es lo normal): la carpeta del
        programa, la de sistema de SU arquitectura, la de Windows y el PATH.
        Devuelve Ruta y Origen (programa, sistema, Windows, PATH) o $null.

        -Path sustituye al PATH del proceso, para las pruebas.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Dll,
        [Parameter(Mandatory=$true)][string]$CarpetaApp,
        [Parameter(Mandatory=$true)][ValidateSet('x86', 'x64', 'arm64')][string]$Arch,
        [string[]]$Path = @($env:PATH -split ';')
    )

    $sistema = if ($Arch -eq 'arm64') { Join-Path $env:SystemRoot 'System32' } else { Get-SystemDllFolder -Arch $Arch }
    $sitios = @(
        @{ Dir = $CarpetaApp;      Origen = 'programa' }
        @{ Dir = $sistema;         Origen = 'sistema' }
        @{ Dir = $env:SystemRoot;  Origen = 'Windows' }
    )
    foreach ($p in $Path) {
        if (-not [string]::IsNullOrWhiteSpace($p)) { $sitios += @{ Dir = [Environment]::ExpandEnvironmentVariables($p.Trim()); Origen = 'PATH' } }
    }

    foreach ($s in $sitios) {
        if (-not $s.Dir) { continue }
        $f = Join-Path $s.Dir $Dll
        if (Test-Path -LiteralPath $f -PathType Leaf) { return [PSCustomObject]@{ Ruta = $f; Origen = $s.Origen } }
    }
    return $null
}

function Get-MissingDllAdvice {
    <# Que hacer con una DLL que falta, segun lo que dice su nombre. #>
    param(
        [Parameter(Mandatory=$true)][string]$Dll,
        [string]$Exe
    )

    $n = $Dll.ToLowerInvariant()
    if ($n -match '^api-ms-win-crt-') {
        return 'Es del CRT universal, que viene con Windows 10 y 11. En Windows 7 u 8.1 se instala aparte (KB2999226), con admin.'
    }
    # Las de depuracion (msvcr110d.dll, vcruntime140d.dll) no se redistribuyen.
    if ($n -match '^(msvc[rp]|mfc|vcruntime|ucrtbase)\d*u?d\.dll$' -or $n -eq 'ucrtbased.dll') {
        return 'Es de DEPURACION de Visual C++: el programa se compilo en Debug. Esas DLL no se pueden repartir; hay que recompilarlo en Release.'
    }
    $suf = Get-VCRuntimeImportSuffix -Dll $Dll
    if ($suf) {
        $vc = @(Get-VCRuntimeCatalog | Where-Object { $_.Sufijo -eq $suf })[0]
        if ($vc) {
            $app = if ($Exe) { $Exe } else { 'C:\ruta\al\programa.exe' }
            return "Es de $($vc.Nombre). Sin admin:  .\bin\kit\Install-VCRuntime.bat -App `"$app`""
        }
        return "Es del runtime de Visual C++ (version $suf), que el kit no trae. Hay que instalar su redistribuible."
    }
    return 'No es de Windows ni de Visual C++: deberia venir con el propio programa. Busca otra copia del programa que funcione y mira si la tiene junto al .exe.'
}

function Test-AppDependencies {
    <#
    .SYNOPSIS
        Todo lo que necesita un programa para arrancar, y lo que falta.
    .DESCRIPTION
        Sigue la cadena como el cargador: lo que importa el .exe, y lo que
        importan las DLL que no sean de Windows. Las que viven dentro de la
        carpeta de Windows no se recorren, se encuentren por donde se
        encuentren: con notepad.exe, cuya carpeta ES System32, recorrerlas era
        leer 936 DLL para no encontrar nada util.

        Las api-ms-win-* y ext-ms-* no son archivos sino nombres que Windows 10
        y 11 resuelven por dentro (API sets), asi que no se buscan. Buscandolas
        como archivos aparecia alguna copia de otro programa en el PATH, y se
        daba por mala una DLL que el programa nunca iba a cargar.

        Una diferida (delay-load) que falta no impide arrancar: falla al usar
        lo que la necesita, o nunca, si el programa le dice a Windows donde
        buscarla al arrancar (VS Code lo hace). Va marcada con Diferida.

        Devuelve una fila por DLL: Dll, Estado (ok, falta, otra arquitectura,
        windows), Origen, Ruta, PedidaPor, Diferida y Consejo. $null si -Exe no
        es un ejecutable.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Exe,
        [string[]]$Path = @($env:PATH -split ';')
    )

    $pe = Get-PeInfo -FilePath $Exe
    if (-not $pe) { return $null }
    $carpeta = Split-Path -Parent $Exe
    $nombreExe = Split-Path -Leaf $Exe

    $windows = [IO.Path]::GetFullPath($env:SystemRoot).TrimEnd('\') + '\'
    $hayApiSets = [Environment]::OSVersion.Version.Major -ge 10

    $filas = New-Object 'System.Collections.Generic.List[object]'
    $vistas = @{}
    $pendientes = New-Object 'System.Collections.Generic.Queue[object]'
    foreach ($i in $pe.Importa) { $pendientes.Enqueue(@($i, $nombreExe, ($pe.Diferidas -contains $i))) }

    while ($pendientes.Count -gt 0) {
        $dll, $quien, $diferida = $pendientes.Dequeue()
        $k = $dll.ToLowerInvariant()
        if ($vistas.ContainsKey($k)) {
            # La pide diferida uno y normal otro: manda la normal, que si
            # impide arrancar.
            if (-not $diferida) { $vistas[$k].Diferida = $false }
            continue
        }

        $fila = [PSCustomObject]@{ Dll = $dll; Estado = 'ok'; Origen = $null; Ruta = $null; PedidaPor = $quien; Diferida = $diferida; Consejo = $null }
        $vistas[$k] = $fila
        $filas.Add($fila)

        if ($k -match '^(api|ext)-ms-' -and ($hayApiSets -or $k -notmatch '^api-ms-win-crt-')) {
            $fila.Estado = 'windows'
            continue
        }

        $donde = Find-DllForApp -Dll $dll -CarpetaApp $carpeta -Arch $pe.Arquitectura -Path $Path
        if (-not $donde) {
            $fila.Estado = 'falta'
            $fila.Consejo = Get-MissingDllAdvice -Dll $dll -Exe $Exe
            continue
        }

        $fila.Origen = $donde.Origen
        $fila.Ruta = $donde.Ruta
        $info = Get-PeInfo -FilePath $donde.Ruta
        if ($info -and $info.Arquitectura -ne $pe.Arquitectura) {
            $fila.Estado = 'otra arquitectura'
            $fila.Consejo = "La que encuentra es de $($info.Arquitectura) y el programa es de $($pe.Arquitectura): no la puede cargar (0xc000007b)."
        }
        elseif ($info -and -not ([IO.Path]::GetFullPath($donde.Ruta)).StartsWith($windows, [StringComparison]::OrdinalIgnoreCase)) {
            foreach ($i in $info.Importa) { $pendientes.Enqueue(@($i, $dll, ($info.Diferidas -contains $i))) }
        }
    }
    # ToArray y no @(): en PowerShell 5.1, @() sobre esta lista lanzaba "los
    # tipos de argumentos no coinciden".
    return $filas.ToArray()
}

function Copy-VCRuntimeToApp {
    <#
    .SYNOPSIS
        Deja las DLL del runtime junto a un programa.
    .DESCRIPTION
        La carpeta del programa es el primer sitio donde Windows busca sus DLL,
        antes que System32, asi que dejarlas ahi basta y no toca el sistema.

        No pisa nada sin -Force. Lo que ya habia puede ser de otro programa de
        la misma carpeta, y quitarlo arreglaria uno y romperia el otro. Pero si
        lo que habia es de la OTRA arquitectura se dice con todas las letras,
        porque es el error de copiar a mano desde System32 y el programa no lo
        puede cargar de ninguna manera.

        Devuelve una fila por DLL con su Estado:

          copiada            no estaba y se ha puesto
          ya estaba          habia una identica: no se toca
          reemplazada        habia otra y -Force la ha sustituido
          otra arquitectura  habia una que este programa no puede cargar
          distinta           habia otra version de la misma arquitectura
          sin permiso        no se puede escribir en la carpeta
          error              cualquier otro fallo al copiar
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Origen,
        [Parameter(Mandatory=$true)][string]$Destino,
        [AllowEmptyCollection()][string[]]$Dlls = @(),
        [Parameter(Mandatory=$true)][ValidateSet('x86', 'x64')][string]$Arch,
        [switch]$Force
    )

    $filas = @()
    foreach ($dll in $Dlls) {
        $src = Join-Path $Origen $dll
        $dst = Join-Path $Destino $dll
        $habia = Test-Path -LiteralPath $dst
        $detalle = ''

        if ($habia) {
            if ((Get-FileSha256 -FilePath $src) -eq (Get-FileSha256 -FilePath $dst)) {
                $filas += [PSCustomObject]@{ Dll = $dll; Estado = 'ya estaba'; Detalle = '' }
                continue
            }

            $suya = Get-PeInfo -FilePath $dst
            if ($suya -and $suya.Arquitectura -ne $Arch) {
                $previo = 'otra arquitectura'
                $detalle = "la que hay es de $($suya.Arquitectura) y el programa es de $Arch"
            }
            else {
                $previo = 'distinta'
                $v = (Get-Item -LiteralPath $dst).VersionInfo.FileVersion
                $detalle = if ($v) { "la que hay es la version $v" } else { 'la que hay no es la del kit' }
            }

            if (-not $Force) {
                $filas += [PSCustomObject]@{ Dll = $dll; Estado = $previo; Detalle = $detalle }
                continue
            }
        }

        try {
            Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
            $estado = if ($habia) { 'reemplazada' } else { 'copiada' }
            $filas += [PSCustomObject]@{ Dll = $dll; Estado = $estado; Detalle = $detalle }
        }
        catch {
            $sinPermiso = $_.Exception -is [System.UnauthorizedAccessException] -or
                          $_.Exception.InnerException -is [System.UnauthorizedAccessException]
            $estado = if ($sinPermiso) { 'sin permiso' } else { 'error' }
            $filas += [PSCustomObject]@{ Dll = $dll; Estado = $estado; Detalle = $_.Exception.Message }
        }
    }

    return $filas
}
