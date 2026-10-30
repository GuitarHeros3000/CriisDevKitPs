#Requires -Version 5.1
<#
    Ayudas compartidas por las pruebas. No es un *.Tests.ps1 a proposito:
    Run-Tests solo recoge esos, asi que este archivo se carga pero no se ejecuta
    como si tuviera pruebas dentro.
#>

function Get-TextoDeFunciones {
    <#
        El codigo fuente de unas funciones de un script del kit, tal cual.

        Existe porque varios comandos (Doctor, Menu, Update-Env) no se pueden
        cargar enteros: al final ejecutan lo suyo y salen con exit, que en medio
        de Pester se lleva por delante la sesion. Con esto se saca solo la
        funcion que interesa y se prueba la de verdad, no una copia pegada aqui
        que se quedaria vieja sin que nadie se entere.

        Quien llama hace el dot-source en SU ambito:

            . ([scriptblock]::Create((Get-TextoDeFunciones -Script X.ps1 -Nombres @('Y'))))
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Script,
        [Parameter(Mandatory=$true)][string[]]$Nombres
    )

    $ruta = Resolve-KitScript -Nombre $Script
    if (-not $ruta) { throw "No se encuentra $Script" }

    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ruta, [ref]$null, [ref]$null)
    $partes = @()

    foreach ($n in $Nombres) {
        $fn = $ast.Find({
            param($nodo)
            $nodo -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $nodo.Name -eq $n
        }.GetNewClosure(), $true)

        if (-not $fn) { throw "$Script ya no define $n" }
        $partes += $fn.Extent.Text
    }

    return ($partes -join "`n")
}

function New-PeDePrueba {
    <#
        Escribe un ejecutable PE minimo: las cabeceras, una seccion con las
        importaciones que se le pidan y, si se pide, una seccion .wixburn. No
        arranca -no lleva codigo- pero tiene exactamente la forma que lee
        Get-PeInfo.

        Existe para no depender de los binarios de la maquina: en un Windows
        ARM, System32 no tiene nada de x64, y en el runner del CI no hay ningun
        programa MFC.

        -BurnContenedores son los tamanos de los contenedores que quien llama
        pegara detras. -BurnFirma simula la firma original del motor, que en un
        bundle firmado queda entre el primer contenedor y el segundo.

        Devuelve el tamano del archivo, que en un bundle es donde empieza el
        primer contenedor.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Ruta,
        [ValidateSet('x86', 'x64', 'arm64')][string]$Arch = 'x86',
        [string[]]$Importa = @(),
        [string[]]$Diferidas = @(),
        [int[]]$BurnContenedores = @(),
        [int]$BurnFirma = 0
    )

    $pe32plus    = $Arch -ne 'x86'
    $machine     = @{ x86 = 0x14C; x64 = 0x8664; arm64 = 0xAA64 }[$Arch]
    $tamOpcional = if ($pe32plus) { 240 } else { 224 }
    $conBurn     = $BurnContenedores.Count -gt 0
    $alinear     = { param($n, $a) [int]([Math]::Ceiling([Math]::Max($n, 1) / $a) * $a) }

    # La seccion de importaciones, en la RVA 0x1000: los descriptores normales
    # (20 bytes, acaban en uno vacio), los diferidos (32) y los nombres.
    $offDiferidas = ($Importa.Count + 1) * 20
    $offNombres   = $offDiferidas + ($Diferidas.Count + 1) * 32
    $nombres = New-Object 'System.Collections.Generic.List[byte]'
    $posNombre = @{}
    foreach ($n in (@($Importa) + @($Diferidas))) {
        $posNombre[$n] = $offNombres + $nombres.Count
        $nombres.AddRange([System.Text.Encoding]::ASCII.GetBytes($n))
        $nombres.Add(0)
    }
    $idata = New-Object byte[] ($offNombres + $nombres.Count)
    for ($i = 0; $i -lt $Importa.Count; $i++) {
        [Array]::Copy([BitConverter]::GetBytes([uint32](0x1000 + $posNombre[$Importa[$i]])), 0, $idata, $i * 20 + 12, 4)
    }
    for ($i = 0; $i -lt $Diferidas.Count; $i++) {
        $o = $offDiferidas + $i * 32
        [Array]::Copy([BitConverter]::GetBytes([uint32]1), 0, $idata, $o, 4)
        [Array]::Copy([BitConverter]::GetBytes([uint32](0x1000 + $posNombre[$Diferidas[$i]])), 0, $idata, $o + 4, 4)
    }
    $nombres.CopyTo($idata, $offNombres)

    $rawI  = & $alinear $idata.Length 0x200
    $burnL = 52 + 4 * $BurnContenedores.Count
    $rawB  = if ($conBurn) { & $alinear $burnL 0x200 } else { 0 }
    $total = 0x400 + $rawI + $rawB

    $b = New-Object byte[] $total
    $put = {
        param([int]$Pos, $Valor)
        $bytes = [BitConverter]::GetBytes($Valor)
        [Array]::Copy($bytes, 0, $b, $Pos, $bytes.Length)
    }

    $b[0] = 0x4D; $b[1] = 0x5A                                     # "MZ"
    & $put 0x3C ([int32]0x40)
    & $put 0x40 ([uint32]0x00004550)                               # "PE\0\0"
    & $put 0x44 ([uint16]$machine)
    & $put 0x46 ([uint16]$(if ($conBurn) { 2 } else { 1 }))
    & $put 0x54 ([uint16]$tamOpcional)
    & $put 0x56 ([uint16]0x0102)

    $opc = 0x58
    if ($pe32plus) {
        & $put $opc ([uint16]0x20B)
        & $put ($opc + 24) ([uint64]0x140000000)
        & $put ($opc + 108) ([uint32]16)
        $dirs = $opc + 112
    }
    else {
        & $put $opc ([uint16]0x10B)
        & $put ($opc + 28) ([uint32]0x400000)
        & $put ($opc + 92) ([uint32]16)
        $dirs = $opc + 96
    }
    if ($Importa.Count -gt 0) {
        & $put ($dirs + 8) ([uint32]0x1000)
        & $put ($dirs + 12) ([uint32](($Importa.Count + 1) * 20))
    }
    if ($Diferidas.Count -gt 0) {
        & $put ($dirs + 8 * 13) ([uint32](0x1000 + $offDiferidas))
        & $put ($dirs + 8 * 13 + 4) ([uint32](($Diferidas.Count + 1) * 32))
    }

    # Tabla de secciones: .idata y, si hace falta, .wixburn detras.
    $sec = $opc + $tamOpcional
    [Array]::Copy([System.Text.Encoding]::ASCII.GetBytes('.idata'), 0, $b, $sec, 6)
    & $put ($sec + 8)  ([uint32]$idata.Length)
    & $put ($sec + 12) ([uint32]0x1000)
    & $put ($sec + 16) ([uint32]$rawI)
    & $put ($sec + 20) ([uint32]0x400)
    [Array]::Copy($idata, 0, $b, 0x400, $idata.Length)

    if ($conBurn) {
        $sec += 40
        $posB = 0x400 + $rawI
        [Array]::Copy([System.Text.Encoding]::ASCII.GetBytes('.wixburn'), 0, $b, $sec, 8)
        & $put ($sec + 8)  ([uint32]$burnL)
        & $put ($sec + 12) ([uint32](0x1000 + (& $alinear $idata.Length 0x1000)))
        & $put ($sec + 16) ([uint32]$rawB)
        & $put ($sec + 20) ([uint32]$posB)

        # magic, version, GUID, stub, checksum, firma original (posicion y
        # tamano), formato CAB, numero de contenedores y sus tamanos.
        $firmaPos = if ($BurnFirma -gt 0) { $total + $BurnContenedores[0] } else { 0 }
        & $put $posB        ([uint32]0x00F14300)
        & $put ($posB + 4)  ([uint32]2)
        & $put ($posB + 24) ([uint32]$total)
        & $put ($posB + 32) ([uint32]$firmaPos)
        & $put ($posB + 36) ([uint32]$BurnFirma)
        & $put ($posB + 40) ([uint32]1)
        & $put ($posB + 44) ([uint32]$BurnContenedores.Count)
        for ($i = 0; $i -lt $BurnContenedores.Count; $i++) {
            & $put ($posB + 48 + 4 * $i) ([uint32]$BurnContenedores[$i])
        }
    }

    [System.IO.File]::WriteAllBytes($Ruta, $b)
    return $total
}

function New-CabDePrueba {
    <#
        Un .cab de verdad, con makecab.exe (viene con Windows), que lleva un
        solo archivo con el nombre y el contenido que se pidan. Devuelve la
        ruta del .cab.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Carpeta,
        [Parameter(Mandatory=$true)][string]$Nombre,
        [Parameter(Mandatory=$true)][string]$Contenido
    )

    $fuente = Join-Path $Carpeta ("fuente-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $fuente -Force | Out-Null
    $archivo = Join-Path $fuente $Nombre
    [System.IO.File]::WriteAllText($archivo, $Contenido)

    $cab = Join-Path $Carpeta ("cab-" + [Guid]::NewGuid().ToString('N') + ".cab")
    $makecab = Join-Path $env:SystemRoot 'System32\makecab.exe'
    $r = Invoke-NativeCommand -FilePath $makecab -Arguments @($archivo, $cab) -Quiet
    if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $cab)) { throw "makecab no pudo crear el cab: $($r.Output)" }

    Remove-Item -LiteralPath $fuente -Recurse -Force
    return $cab
}
