#Requires -Version 5.1
<#
    Los runtimes de Visual C++ que necesitan programas ajenos

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
        hace falta. La Update 4 de 2012 es la ultima que habra: esa version
        salio de soporte en enero de 2023, asi que fijarla no caduca.

        Sufijo es como lleva la version en el nombre de sus DLL (msvcr110.dll).
    #>
    return @(
        [PSCustomObject]@{
            Version = '2012'; Nombre = 'Visual C++ 2012'; Sufijo = '110'; Build = '11.0.61030'
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
    )
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
    #>
    param(
        [AllowEmptyCollection()][string[]]$Importa = @(),
        [Parameter(Mandatory=$true)][string]$Sufijo
    )

    return @($Importa | Where-Object {
        $_ -match '^(msvc[rp]|mfc|mfcm|vcomp|vcamp|vccorlib|atl|concrt|vcruntime)(\d{2,3})u?d?\.dll$' -and
        $Matches[2] -ne $Sufijo
    })
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
