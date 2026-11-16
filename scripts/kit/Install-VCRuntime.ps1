#Requires -Version 5.1
<#
.SYNOPSIS
    Install-VCRuntime.ps1 - El runtime de Visual C++ que pide un programa, sin admin.
.DESCRIPTION
    El redistribuible de Microsoft (vcredist) se instala en System32 y pide
    administrador. Pero desde Visual C++ 2010 el runtime no necesita
    instalarse: Microsoft admite dejar sus DLL junto al programa que las usa,
    que es el primer sitio donde Windows las busca.

    Esto hace eso, en dos pasos:

      1. Saca las DLL del redistribuible oficial SIN ejecutarlo: lo abre como
         bundle WiX Burn, comprueba cada pieza contra el hash que declara, y
         lee los MSI de dentro como bases de datos. Ni instalador, ni msiexec,
         ni nada que una directiva de empresa pueda bloquear. Quedan en
         ..\VCRuntime\vc-<version>\<arquitectura>.

      2. Con -App, lee el .exe del programa para saber de cuantos bits es, que
         version de Visual C++ pide y que DLL (y las que piden ellas), y copia
         exactamente esas a su carpeta. La arquitectura sale del programa y no
         del equipo: un .exe de 32 bits en un Windows de 64 necesita las de 32.
.PARAMETER Version
    2012, 2013 o 2015-2022 (2015, 2017, 2019 y 2022 son el mismo). Con -App
    sobra: se deduce de lo que importa el programa. Sin -App, es obligatoria.
.PARAMETER App
    El .exe que necesita el runtime. Sin el, solo se extraen las DLL.
.PARAMETER Arch
    x86 o x64. Con -App sobra: manda la del programa. Sin -App, por defecto
    se extraen las dos.
.PARAMETER Force
    Vuelve a extraer aunque ya este, y sustituye en la carpeta del programa
    las DLL que no coincidan con las del kit.
.EXAMPLE
    .\Install-VCRuntime.ps1 -App "C:\SYS\BR\UTILERIAPUENTEBR.EXE"
.EXAMPLE
    .\Install-VCRuntime.ps1 -Version 2015-2022 -Arch x64
#>

param(
    [ValidateSet('2012', '2013', '2015', '2017', '2019', '2022', '2015-2022')]
    [string]$Version,

    [string]$App,

    [ValidateSet('x86', 'x64')]
    [string]$Arch,

    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Common.ps1")

$Versiones = (@(Get-VCRuntimeCatalog) | ForEach-Object { $_.Version }) -join ', '

Write-Log "========================================" "INFO"
Write-Log "  Runtime de Visual C++, sin admin" "INFO"
Write-Log "========================================" "INFO"
Write-Log ""

function Install-VCRuntimeFiles {
    <#
        Deja las DLL de una version y arquitectura en su carpeta del kit, o
        reutiliza las que ya haya. Devuelve la carpeta, o $null si algo falla.

        Se extrae a una carpeta temporal y solo al final se pone en su sitio,
        para que un fallo a mitad no deje una carpeta con medio runtime que la
        siguiente ejecucion daria por buena.
    #>
    param([PSCustomObject]$VC, [string]$Arquitectura)

    $carpeta = Get-VCRuntimeFolder -Version $VC.Version -Arch $Arquitectura
    $marca = Join-Path $carpeta $VC.Basicas[0]

    if ((Test-Path -LiteralPath $marca) -and -not $Force) {
        Write-Log "$($VC.Nombre) $Arquitectura ya extraido en $carpeta" "SUCCESS"
        return $carpeta
    }

    $descarga = $VC.Descargas[$Arquitectura]
    $trabajo = Join-Path ([System.IO.Path]::GetTempPath()) ("criisdevkit-vc-" + [Guid]::NewGuid().ToString('N'))

    try {
        $exe = Join-Path $trabajo (Split-Path -Leaf $descarga.Url)
        Write-Log "Descargando el redistribuible oficial de $($VC.Nombre) ($Arquitectura, $($VC.Build))..."
        if (-not (Invoke-Download -Uri $descarga.Url -OutFile $exe -Sha256 $descarga.Sha256 `
                                  -FirmanteEsperado 'Microsoft Corporation' `
                                  -Description "vcredist $($VC.Version) $Arquitectura")) {
            return $null
        }

        Write-Log "Abriendo el redistribuible sin ejecutarlo..."
        $layout = Join-Path $trabajo 'layout'
        $bundle = Expand-BurnBundle -Path $exe -DestDir $layout
        if (-not $bundle) { return $null }

        $msis = @(Get-ChildItem -LiteralPath $layout -Filter *.msi -File -Recurse)
        if ($msis.Count -eq 0) {
            Write-Log "El redistribuible no lleva ningun MSI dentro." "ERROR"
            return $null
        }

        # Cada MSI en su carpeta: el de x64 de 2015-2022 trae otro para ARM con
        # los mismos nombres, y juntos se pisaban (ver Select-VCRuntimeDlls).
        $porMsi = @()
        for ($i = 0; $i -lt $msis.Count; $i++) {
            $d = Join-Path $trabajo "msi-$i"
            $n = Expand-MsiFiles -MsiPath $msis[$i].FullName -DestDir $d
            if ($null -eq $n) { return $null }
            $porMsi += $d
        }

        $nuevas = Join-Path $trabajo 'dlls'
        $filas = Select-VCRuntimeDlls -Carpetas $porMsi -Arch $Arquitectura -Destino $nuevas
        if ($null -eq $filas) { return $null }
        for ($i = 0; $i -lt $msis.Count; $i++) {
            $f = $filas | Where-Object { $_.Carpeta -eq $porMsi[$i] }
            if ($f.Usada) { Write-Log "  $($msis[$i].Name): $($f.Motivo)" }
            else { Write-Log "  $($msis[$i].Name): $($f.Motivo), no se usa" }
        }

        # Todas vienen firmadas por Microsoft. Si alguna no, algo ha ido mal
        # al sacarla, y no se deja junto a ningun programa.
        $dlls = @(Get-ChildItem -LiteralPath $nuevas -Filter *.dll -File)
        $malas = @($dlls | Where-Object {
            $f = Get-FileSignerInfo -FilePath $_.FullName
            $f.Estado -ne 'Valid' -or $f.Firmante -notlike '*Microsoft*'
        })
        if ($malas.Count -gt 0) {
            Write-Log "$($malas.Count) DLL no llevan una firma valida de Microsoft:" "ERROR"
            foreach ($b in $malas) { Write-Log "  $($b.Name)" "ERROR" }
            return $null
        }
        if (-not (Test-Path -LiteralPath (Join-Path $nuevas $VC.Basicas[0]))) {
            Write-Log "El redistribuible no traia $($VC.Basicas[0]) de $Arquitectura." "ERROR"
            return $null
        }
        Write-Log "  $($dlls.Count) DLL, todas firmadas por Microsoft" "SUCCESS"

        if (Test-Path -LiteralPath $carpeta) {
            Remove-Item -LiteralPath $carpeta -Recurse -Force
        }
        $padre = Split-Path -Parent $carpeta
        if (-not (Test-Path -LiteralPath $padre)) { New-Item -ItemType Directory -Path $padre -Force | Out-Null }
        Move-Item -LiteralPath $nuevas -Destination $carpeta

        Write-Log "$($VC.Nombre) $Arquitectura extraido en $carpeta" "SUCCESS"
        return $carpeta
    }
    finally {
        Remove-Item -LiteralPath $trabajo -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Install-ForApp {
    <#
        Lo que pide el programa de UNA version, en su carpeta. Devuelve 0 si el
        programa queda servido y 1 si no.
    #>
    param([PSCustomObject]$VC, [PSCustomObject]$Pe)

    Write-Log "--- $($VC.Nombre) ---"
    $origen = Install-VCRuntimeFiles -VC $VC -Arquitectura $Arch
    if (-not $origen) { return 1 }
    Write-Log ""

    # Lo que importa cada DLL del runtime, para seguir la cadena: el programa
    # puede pedir solo mfc110.dll, pero mfc110.dll pide msvcr110.dll.
    $importsDe = @{}
    foreach ($d in (Get-ChildItem -LiteralPath $origen -Filter *.dll -File)) {
        $info = Get-PeInfo -FilePath $d.FullName
        $importsDe[$d.Name.ToLowerInvariant()] = if ($info) { @($info.Importa) } else { @() }
    }

    $necesarias = @(Resolve-VCRuntimeDlls -Importa $Pe.Importa -ImportsDe $importsDe)

    if ($necesarias.Count -eq 0) {
        Write-Log "El programa no importa ninguna DLL de $($VC.Nombre)." "WARN"
        $otras = @(Get-OtherVCRuntimeImports -Importa $Pe.Importa -Sufijo $VC.Sufijo)
        if ($otras.Count -gt 0) {
            Write-Log "  Pide las de OTRA version de Visual C++: $($otras -join ', ')" "WARN"
            Write-Log "  Quita -Version y el kit elige la que pide." "WARN"
        }
        else {
            Write-Log "  Puede que las cargue en marcha (LoadLibrary), y eso no se ve en el .exe." "WARN"
            Write-Log "  Si Windows te dijo que DLL falta, copia esa de: $origen" "WARN"
        }
        return 1
    }

    Write-Log "Necesita $($necesarias.Count): $($necesarias -join ', ')"

    # Si Windows ya las encuentra en el sistema, el programa no deberia fallar por
    # esto, y copiarlas no arregla nada: se dice y no se toca la carpeta.
    $sistema = Get-SystemDllFolder -Arch $Arch
    $enSistema = @($necesarias | Where-Object { $sistema -and (Test-Path -LiteralPath (Join-Path $sistema $_)) })
    if ($enSistema.Count -eq $necesarias.Count -and -not $Force) {
        Write-Log "Este equipo ya las tiene todas en $sistema." "SUCCESS"
        Write-Log "  Si el programa falla, no es por el runtime. Para copiarlas igualmente: -Force" "INFO"
        return 0
    }

    $filas = @(Copy-VCRuntimeToApp -Origen $origen -Destino $carpetaApp -Dlls $necesarias -Arch $Arch -Force:$Force)

    Write-Host ""
    foreach ($f in $filas) {
        $color = switch ($f.Estado) {
            'copiada'     { 'Green' }
            'reemplazada' { 'Green' }
            'ya estaba'   { 'Gray' }
            default       { 'Red' }
        }
        Write-Host ("  {0,-18} {1}" -f $f.Estado, $f.Dll) -ForegroundColor $color
        if ($f.Detalle) { Write-Host ("  {0,-18} {1}" -f '', $f.Detalle) -ForegroundColor DarkGray }
    }
    Write-Host ""

    $pendientes = @($filas | Where-Object { $_.Estado -notin @('copiada', 'reemplazada', 'ya estaba') })
    if ($pendientes.Count -eq 0) {
        Write-Log "Listo: el programa ya encuentra $($VC.Nombre) en su carpeta, sin instalar nada." "SUCCESS"
        return 0
    }

    if (@($pendientes | Where-Object { $_.Estado -eq 'otra arquitectura' }).Count -gt 0) {
        Write-Log "Hay DLL de la arquitectura equivocada junto al programa." "WARN"
        Write-Log "  Suele pasar al copiarlas a mano de System32: en un Windows de 64 bits, ahi" "WARN"
        Write-Log "  estan las de 64, y las de 32 en SysWOW64. Este programa no puede cargarlas." "WARN"
    }
    if (@($pendientes | Where-Object { $_.Estado -eq 'distinta' }).Count -gt 0) {
        Write-Log "Hay otra version de alguna DLL junto al programa, y no se ha tocado:" "WARN"
        Write-Log "  puede ser de otro programa de la misma carpeta." "WARN"
    }
    if (@($pendientes | Where-Object { $_.Estado -in @('otra arquitectura', 'distinta') }).Count -gt 0) {
        Write-Log "  Para sustituirlas por las del kit:  .\bin\kit\Install-VCRuntime.bat -App `"$App`" -Force" "WARN"
    }
    if (@($pendientes | Where-Object { $_.Estado -eq 'sin permiso' }).Count -gt 0) {
        Write-Log "No puedes escribir en $carpetaApp." "ERROR"
        Write-Log "  Esa carpeta pide admin, asi que tampoco sirve dejar ahi las DLL." "WARN"
        Write-Log "  Salida sin admin: copia el programa a una carpeta tuya y repite con esa ruta." "WARN"
    }
    return 1
}

# --------------------------------------------------------------------------
# Sin -App: solo extraer
# --------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($App)) {
    if (-not $Version) {
        Write-Log "Falta decir para que programa, o que version descargar." "ERROR"
        Write-Log "  Lo normal es darle el programa y que el kit vea cual pide:" "WARN"
        Write-Log "    .\bin\kit\Install-VCRuntime.bat -App `"C:\ruta\al\programa.exe`"" "WARN"
        Write-Log "  Para solo descargar una:  -Version <$($Versiones -replace ', ', '|')>" "WARN"
        exit 1
    }

    $VC = Get-VCRuntimeEntry -Version $Version
    $archs = if ($Arch) { @($Arch) } else { @('x86', 'x64') }
    foreach ($a in $archs) {
        if (-not (Install-VCRuntimeFiles -VC $VC -Arquitectura $a)) { exit 1 }
        Write-Log ""
    }

    # Paso: al dejar vacia la ruta en el menu, se descargaba todo, salia en
    # verde y parecia que el programa ya tenia sus DLL. No las tenia.
    Write-Log "NO se ha copiado nada junto a ningun programa: solo se han descargado las DLL." "WARN"
    Write-Host ""
    Write-Host "En esa carpeta no hacen nada: hay que dejarlas junto al programa que las" -ForegroundColor Gray
    Write-Host "pide. Para que el kit elija cuales y las copie:" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  .\bin\kit\Install-VCRuntime.bat -App `"C:\ruta\al\programa.exe`"" -ForegroundColor White
    Write-Host ""
    exit 0
}

# --------------------------------------------------------------------------
# Con -App: lo que pide ese programa, en su carpeta
# --------------------------------------------------------------------------

# "Copiar como ruta" del Explorador la pone entre comillas.
$App = $App.Trim().Trim('"')

if (-not (Test-Path -LiteralPath $App -PathType Leaf)) {
    Write-Log "No existe el programa: $App" "ERROR"
    exit 1
}
$App = (Resolve-Path -LiteralPath $App).Path
$carpetaApp = Split-Path -Parent $App

$pe = Get-PeInfo -FilePath $App
if (-not $pe) {
    Write-Log "$App no es un ejecutable de Windows." "ERROR"
    exit 1
}

Write-Log "Programa: $App"
Write-Log "  Es de $($pe.Arquitectura -replace 'x86', '32 bits (x86)' -replace 'x64', '64 bits (x64)')"

if ($pe.Arquitectura -notin @('x86', 'x64')) {
    Write-Log "  El runtime de Visual C++ que trae el kit solo es para x86 y x64." "ERROR"
    exit 1
}
if ($Arch -and $Arch -ne $pe.Arquitectura) {
    Write-Log "Pides -Arch $Arch, pero el programa es de $($pe.Arquitectura)." "ERROR"
    Write-Log "  No puede cargar DLL de otra arquitectura. Quita -Arch: manda la del programa." "WARN"
    exit 1
}
$Arch = $pe.Arquitectura

$aServir = if ($Version) { @(Get-VCRuntimeEntry -Version $Version) } else { @(Get-VCRuntimeVersionsFor -Importa $pe.Importa) }

if ($aServir.Count -eq 0) {
    Write-Log "El programa no importa ninguna DLL de Visual C++ que el kit conozca ($Versiones)." "WARN"
    $otras = @(Get-OtherVCRuntimeImports -Importa $pe.Importa -Sufijo @(Get-VCRuntimeCatalog | ForEach-Object { $_.Sufijo }))
    if ($otras.Count -gt 0) {
        Write-Log "  Pide $($otras -join ', '), de una version que el kit no trae." "WARN"
    }
    else {
        Write-Log "  Puede que las cargue en marcha (LoadLibrary), y eso no se ve en el .exe." "WARN"
        Write-Log "  Si sabes cual es, indicala:  -Version <$($Versiones -replace ', ', '|')>" "WARN"
    }
    exit 1
}

Write-Log "  Pide: $(($aServir | ForEach-Object { $_.Nombre }) -join ', ')"
Write-Log ""

$codigo = 0
foreach ($VC in $aServir) {
    if ((Install-ForApp -VC $VC -Pe $pe) -ne 0) { $codigo = 1 }
    Write-Log ""
}
exit $codigo
