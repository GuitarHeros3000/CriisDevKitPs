#Requires -Version 5.1
<#
    Pruebas de lib\VCRuntime.ps1: que DLL del runtime de Visual C++ necesita
    un programa, y como se dejan junto a el.

    Existe por un caso real. Un programa de 32 bits (UTILERIAPUENTEBR.EXE)
    pedia mfc110.dll en un equipo sin admin, y la receta que circulaba era
    copiarla "de C:\Windows\System32 de otro equipo". En un Windows de 64 bits
    ahi estan las de 64, que ese programa no puede cargar: cambiaba un error
    claro por un 0xc000007b. Por eso Copy-VCRuntimeToApp mira la arquitectura
    de lo que ya hay, y por eso esta la prueba que lo vigila.
#>

$KitRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $KitRoot "lib\Common.ps1")
. (Join-Path $PSScriptRoot "Helpers.ps1")

function New-CarpetaTemporal {
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ("vcruntime-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return $d
}

# Lo que importan de verdad las DLL del redistribuible de 2012, leido de las
# de Microsoft: mfc110 y msvcp110 piden msvcr110, y msvcr110 nada del runtime.
$Imports2012 = @{
    'msvcr110.dll' = @('KERNEL32.dll')
    'msvcp110.dll' = @('MSVCR110.dll', 'KERNEL32.dll')
    'mfc110.dll'   = @('MSVCR110.dll', 'KERNEL32.dll', 'USER32.dll')
    'mfc110u.dll'  = @('MSVCR110.dll', 'KERNEL32.dll', 'USER32.dll')
    'vcomp110.dll' = @('KERNEL32.dll')
}

Describe "Resolve-VCRuntimeDlls" {

    # El caso de UTILERIAPUENTEBR: el programa solo pide mfc110.dll, y copiar
    # solo esa da el mismo error con otro nombre.
    It "sigue la cadena: mfc110 trae msvcr110" {
        $r = Resolve-VCRuntimeDlls -Importa @('mfc110.dll', 'KERNEL32.dll') -ImportsDe $Imports2012
        ($r -join ',') | Should Be 'mfc110.dll,msvcr110.dll'
    }

    It "no anade lo que el programa no pide: msvcp110 solo si alguien la importa" {
        $r = Resolve-VCRuntimeDlls -Importa @('mfc110.dll') -ImportsDe $Imports2012
        $r -contains 'msvcp110.dll' | Should Be $false
    }

    It "no repite una DLL que piden varias" {
        $r = Resolve-VCRuntimeDlls -Importa @('mfc110.dll', 'msvcp110.dll', 'msvcr110.dll') -ImportsDe $Imports2012
        @($r).Count | Should Be 3
    }

    It "no distingue mayusculas, como Windows" {
        $r = Resolve-VCRuntimeDlls -Importa @('MFC110.DLL') -ImportsDe $Imports2012
        ($r -join ',') | Should Be 'mfc110.dll,msvcr110.dll'
    }

    It "no entra en bucle si dos DLL se piden entre si" {
        $ciclo = @{ 'a.dll' = @('b.dll'); 'b.dll' = @('a.dll') }
        ((Resolve-VCRuntimeDlls -Importa @('a.dll') -ImportsDe $ciclo) -join ',') | Should Be 'a.dll,b.dll'
    }

    It "un programa sin nada del runtime no necesita nada" {
        @(Resolve-VCRuntimeDlls -Importa @('KERNEL32.dll', 'USER32.dll') -ImportsDe $Imports2012).Count | Should Be 0
        @(Resolve-VCRuntimeDlls -Importa @() -ImportsDe $Imports2012).Count | Should Be 0
    }
}

Describe "Get-OtherVCRuntimeImports" {

    It "senala el runtime de otra version" {
        $r = Get-OtherVCRuntimeImports -Importa @('KERNEL32.dll', 'MSVCR100.dll', 'mfc140u.dll') -Sufijo '110'
        ($r -join ',') | Should Be 'MSVCR100.dll,mfc140u.dll'
    }

    It "no senala las de la propia version" {
        @(Get-OtherVCRuntimeImports -Importa @('msvcr110.dll', 'mfc110u.dll') -Sufijo '110').Count | Should Be 0
    }

    # msvcrt.dll es del sistema, no de ninguna version de Visual C++.
    It "no confunde msvcrt.dll con un runtime de Visual C++" {
        @(Get-OtherVCRuntimeImports -Importa @('msvcrt.dll') -Sufijo '110').Count | Should Be 0
    }

    It "con los sufijos de todo el catalogo, solo queda lo que el kit no trae" {
        $r = Get-OtherVCRuntimeImports -Importa @('MSVCR100.dll', 'mfc110.dll', 'VCRUNTIME140.dll') -Sufijo @('110', '120', '140')
        ($r -join ',') | Should Be 'MSVCR100.dll'
    }
}

Describe "Get-VCRuntimeImportSuffix" {

    $casos = @(
        @{ Dll = 'mfc110u.dll';              Sufijo = '110' }
        @{ Dll = 'MSVCR120.dll';             Sufijo = '120' }
        @{ Dll = 'VCRUNTIME140.dll';         Sufijo = '140' }
        # Las de 2015 en adelante llevan algo detras del numero, y un programa
        # de 64 bits importa vcruntime140_1.dll ademas de vcruntime140.dll.
        @{ Dll = 'vcruntime140_1.dll';       Sufijo = '140' }
        @{ Dll = 'msvcp140_atomic_wait.dll'; Sufijo = '140' }
        @{ Dll = 'msvcrt.dll';               Sufijo = $null }
        @{ Dll = 'KERNEL32.dll';             Sufijo = $null }
        @{ Dll = 'api-ms-win-crt-heap-l1-1-0.dll'; Sufijo = $null }
    )

    foreach ($c in $casos) {
        It "$($c.Dll) -> $(if ($c.Sufijo) { $c.Sufijo } else { 'ninguno' })" {
            Get-VCRuntimeImportSuffix -Dll $c.Dll | Should Be $c.Sufijo
        }
    }
}

Describe "Get-VCRuntimeEntry y Get-VCRuntimeVersionsFor" {

    It "2019 es 2015-2022: un solo runtime para las cuatro" {
        foreach ($a in @('2015', '2017', '2019', '2022')) { (Get-VCRuntimeEntry -Version $a).Version | Should Be '2015-2022' }
    }

    It "una version que no trae el kit no devuelve nada" {
        Get-VCRuntimeEntry -Version '2010' | Should BeNullOrEmpty
    }

    It "deduce la version de lo que importa el programa" {
        $r = @(Get-VCRuntimeVersionsFor -Importa @('KERNEL32.dll', 'mfc110.dll'))
        ($r.Version -join ',') | Should Be '2012'
    }

    It "un programa puede pedir dos versiones a la vez" {
        $r = @(Get-VCRuntimeVersionsFor -Importa @('VCRUNTIME140.dll', 'MSVCR120.dll'))
        ($r.Version -join ',') | Should Be '2013,2015-2022'
    }

    It "sin nada que el kit conozca, no deduce nada" {
        @(Get-VCRuntimeVersionsFor -Importa @('KERNEL32.dll', 'MSVCR100.dll')).Count | Should Be 0
    }
}

Describe "Select-VCRuntimeDlls" {

    # Paso de verdad con el redistribuible x64 de 2015-2022 (14.44.35211): trae
    # un tercer MSI para Windows en ARM con los mismos nombres de DLL, y al
    # sacarlos todos en una carpeta pisaba a las de x64.
    function New-Paquetes {
        $d = New-CarpetaTemporal
        $x64 = Join-Path $d 'msi-0'; $arm = Join-Path $d 'msi-1'
        New-Item -ItemType Directory -Path $x64, $arm -Force | Out-Null
        New-PeDePrueba -Ruta (Join-Path $x64 'vcruntime140.dll') -Arch x64 | Out-Null
        New-PeDePrueba -Ruta (Join-Path $x64 'msvcp140.dll') -Arch x64 -Importa @('VCRUNTIME140.dll') | Out-Null
        # El de ARM: mismos nombres en arm64, y alguna de x64 suelta.
        New-PeDePrueba -Ruta (Join-Path $arm 'vcruntime140.dll') -Arch arm64 | Out-Null
        New-PeDePrueba -Ruta (Join-Path $arm 'msvcp140.dll') -Arch arm64 | Out-Null
        New-PeDePrueba -Ruta (Join-Path $arm 'vcruntime140_1.dll') -Arch x64 -Importa @('OTRA.dll') | Out-Null
        return [PSCustomObject]@{ Raiz = $d; X64 = $x64; Arm = $arm; Destino = (Join-Path $d 'dlls') }
    }

    It "con el paquete de ARM en medio, solo quedan DLL de x64" {
        $p = New-Paquetes
        try {
            # El de ARM va el ULTIMO a proposito: si se copiara, pisaria.
            $r = Select-VCRuntimeDlls -Carpetas @($p.X64, $p.Arm) -Arch x64 -Destino $p.Destino
            $dlls = @(Get-ChildItem -LiteralPath $p.Destino -Filter *.dll)
            $dlls.Count | Should Be 2
            foreach ($f in $dlls) { (Get-PeInfo -FilePath $f.FullName).Arquitectura | Should Be 'x64' }
            ($r | Where-Object { $_.Carpeta -eq $p.Arm }).Usada | Should Be $false
        }
        finally { Remove-Item -LiteralPath $p.Raiz -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # La de x64 que trae el paquete de ARM no es del runtime de x64: no se
    # rescatan DLL sueltas de un paquete de otra arquitectura.
    It "no rescata la DLL de x64 que viene dentro del paquete de ARM" {
        $p = New-Paquetes
        try {
            Select-VCRuntimeDlls -Carpetas @($p.X64, $p.Arm) -Arch x64 -Destino $p.Destino | Out-Null
            Test-Path -LiteralPath (Join-Path $p.Destino 'vcruntime140_1.dll') | Should Be $false
        }
        finally { Remove-Item -LiteralPath $p.Raiz -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "pidiendo x86, ninguno de los dos sirve" {
        $p = New-Paquetes
        try {
            $r = Select-VCRuntimeDlls -Carpetas @($p.X64, $p.Arm) -Arch x86 -Destino $p.Destino
            @($r | Where-Object { $_.Usada }).Count | Should Be 0
            @(Get-ChildItem -LiteralPath $p.Destino -Filter *.dll -ErrorAction SilentlyContinue).Count | Should Be 0
        }
        finally { Remove-Item -LiteralPath $p.Raiz -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "dos paquetes de la misma arquitectura con la misma DLL distinta: no deja nada" {
        $p = New-Paquetes
        try {
            $otro = Join-Path $p.Raiz 'msi-2'
            New-Item -ItemType Directory -Path $otro -Force | Out-Null
            New-PeDePrueba -Ruta (Join-Path $otro 'msvcp140.dll') -Arch x64 -Importa @('DISTINTA.dll') | Out-Null

            Mock Write-Log { }
            Select-VCRuntimeDlls -Carpetas @($p.X64, $otro) -Arch x64 -Destino $p.Destino | Should Be $null
            @(Get-ChildItem -LiteralPath $p.Destino -ErrorAction SilentlyContinue).Count | Should Be 0
        }
        finally { Remove-Item -LiteralPath $p.Raiz -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "la misma DLL identica en dos paquetes no es un choque" {
        $p = New-Paquetes
        try {
            $otro = Join-Path $p.Raiz 'msi-2'
            New-Item -ItemType Directory -Path $otro -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $p.X64 'msvcp140.dll') -Destination $otro

            Select-VCRuntimeDlls -Carpetas @($p.X64, $otro) -Arch x64 -Destino $p.Destino | Should Not Be $null
            @(Get-ChildItem -LiteralPath $p.Destino -Filter *.dll).Count | Should Be 2
        }
        finally { Remove-Item -LiteralPath $p.Raiz -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe "Copy-VCRuntimeToApp" {

    function New-Escenario {
        <# El runtime del kit (x86) en una carpeta y la del programa vacia. #>
        $d = New-CarpetaTemporal
        $kit = Join-Path $d 'kit'; $app = Join-Path $d 'app'
        New-Item -ItemType Directory -Path $kit, $app -Force | Out-Null
        New-PeDePrueba -Ruta (Join-Path $kit 'mfc110.dll') -Arch x86 -Importa @('MSVCR110.dll') | Out-Null
        New-PeDePrueba -Ruta (Join-Path $kit 'msvcr110.dll') -Arch x86 -Importa @('KERNEL32.dll') | Out-Null
        return [PSCustomObject]@{ Raiz = $d; Kit = $kit; App = $app }
    }

    It "copia lo que falta" {
        $e = New-Escenario
        try {
            $r = @(Copy-VCRuntimeToApp -Origen $e.Kit -Destino $e.App -Dlls @('mfc110.dll', 'msvcr110.dll') -Arch x86)
            ($r.Estado -join ',') | Should Be 'copiada,copiada'
            Test-Path -LiteralPath (Join-Path $e.App 'mfc110.dll') | Should Be $true
            Test-Path -LiteralPath (Join-Path $e.App 'msvcr110.dll') | Should Be $true
        }
        finally { Remove-Item -LiteralPath $e.Raiz -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "deja como esta una identica" {
        $e = New-Escenario
        try {
            Copy-Item -LiteralPath (Join-Path $e.Kit 'msvcr110.dll') -Destination $e.App
            $antes = (Get-Item -LiteralPath (Join-Path $e.App 'msvcr110.dll')).LastWriteTimeUtc

            $r = @(Copy-VCRuntimeToApp -Origen $e.Kit -Destino $e.App -Dlls @('msvcr110.dll') -Arch x86)
            $r[0].Estado | Should Be 'ya estaba'
            (Get-Item -LiteralPath (Join-Path $e.App 'msvcr110.dll')).LastWriteTimeUtc | Should Be $antes
        }
        finally { Remove-Item -LiteralPath $e.Raiz -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # EL CASO QUE MOTIVA ESTE ARCHIVO: alguien copio a mano la de System32,
    # que en un Windows de 64 bits es la de 64, junto a un programa de 32.
    It "senala la DLL de la otra arquitectura y no la toca sin -Force" {
        $e = New-Escenario
        try {
            $suya = Join-Path $e.App 'msvcr110.dll'
            New-PeDePrueba -Ruta $suya -Arch x64 -Importa @('KERNEL32.dll') | Out-Null
            $hashAntes = Get-FileSha256 -FilePath $suya

            $r = @(Copy-VCRuntimeToApp -Origen $e.Kit -Destino $e.App -Dlls @('msvcr110.dll') -Arch x86)
            $r[0].Estado | Should Be 'otra arquitectura'
            $r[0].Detalle | Should Match 'x64'
            Get-FileSha256 -FilePath $suya | Should Be $hashAntes
        }
        finally { Remove-Item -LiteralPath $e.Raiz -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "con -Force sustituye la de la otra arquitectura" {
        $e = New-Escenario
        try {
            $suya = Join-Path $e.App 'msvcr110.dll'
            New-PeDePrueba -Ruta $suya -Arch x64 | Out-Null

            $r = @(Copy-VCRuntimeToApp -Origen $e.Kit -Destino $e.App -Dlls @('msvcr110.dll') -Arch x86 -Force)
            $r[0].Estado | Should Be 'reemplazada'
            (Get-PeInfo -FilePath $suya).Arquitectura | Should Be 'x86'
        }
        finally { Remove-Item -LiteralPath $e.Raiz -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # Otra version de la misma arquitectura puede ser de OTRO programa de la
    # misma carpeta. Quitarla arreglaria uno y romperia el otro.
    It "no toca otra version de la misma arquitectura sin -Force" {
        $e = New-Escenario
        try {
            $suya = Join-Path $e.App 'msvcr110.dll'
            New-PeDePrueba -Ruta $suya -Arch x86 -Importa @('OTRA.dll') | Out-Null
            $hashAntes = Get-FileSha256 -FilePath $suya

            $r = @(Copy-VCRuntimeToApp -Origen $e.Kit -Destino $e.App -Dlls @('msvcr110.dll') -Arch x86)
            $r[0].Estado | Should Be 'distinta'
            Get-FileSha256 -FilePath $suya | Should Be $hashAntes
        }
        finally { Remove-Item -LiteralPath $e.Raiz -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "sin nada que copiar, no devuelve nada" {
        $e = New-Escenario
        try {
            @(Copy-VCRuntimeToApp -Origen $e.Kit -Destino $e.App -Dlls @() -Arch x86).Count | Should Be 0
        }
        finally { Remove-Item -LiteralPath $e.Raiz -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe "Get-VCRuntimeCatalog" {

    $catalogo = @(Get-VCRuntimeCatalog)

    It "tiene alguna version" {
        $catalogo.Count | Should BeGreaterThan 0
    }

    # La URL y el hash van fijados a mano. Un hash con un caracter de menos o
    # una URL que no es de Microsoft no se notarian hasta la primera descarga.
    It "cada version trae x86 y x64, de Microsoft y con su SHA-256" {
        foreach ($v in $catalogo) {
            foreach ($a in @('x86', 'x64')) {
                $d = $v.Descargas[$a]
                if (-not $d) { throw "$($v.Nombre) no trae $a" }
                $d.Url    | Should Match '^https://download\.(visualstudio\.)?microsoft\.com/'
                $d.Sha256 | Should Match '^[0-9a-f]{64}$'
            }
        }
    }

    # Un enlace aka.ms cambia de archivo con cada build, y el hash fijado dejaria
    # de cuadrar el dia que Microsoft publique otra.
    It "ninguna URL es un enlace que cambia de destino" {
        foreach ($v in $catalogo) {
            foreach ($a in @('x86', 'x64')) { $v.Descargas[$a].Url | Should Not Match 'aka\.ms' }
        }
    }

    It "el sufijo es el que llevan sus DLL" {
        foreach ($v in $catalogo) {
            $v.Sufijo | Should Match '^\d{2,3}$'
            foreach ($b in $v.Basicas) { Get-VCRuntimeImportSuffix -Dll $b | Should Be $v.Sufijo }
        }
    }

    It "cada version se puede pedir por su propio nombre" {
        foreach ($v in $catalogo) { $v.Alias -contains $v.Version | Should Be $true }
    }

    It "ningun alias apunta a dos versiones" {
        $todos = @($catalogo | ForEach-Object { $_.Alias })
        $todos.Count | Should Not Be 0
        @($todos | Select-Object -Unique).Count | Should Be $todos.Count
    }

    # Install-VCRuntime y el menu ofrecen estas; una version en el catalogo que
    # el ValidateSet del script no admitiera no se podria pedir.
    It "el script admite todas las versiones y alias del catalogo" {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Resolve-KitScript -Nombre 'Install-VCRuntime.ps1'), [ref]$null, [ref]$null)
        $p = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Version' }
        $set = @(($p.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }).PositionalArguments | ForEach-Object { $_.Value })
        $set.Count | Should Not Be 0
        foreach ($a in @($catalogo | ForEach-Object { $_.Alias })) { $set -contains $a | Should Be $true }
    }

    It "deja cada arquitectura en su carpeta, al lado del kit" {
        $r = Get-VCRuntimeFolder -Version '2012' -Arch x86
        $r | Should Be (Join-Path $WorkspaceRoot 'VCRuntime\vc-2012\x86')
    }
}

Describe "Get-SystemDllFolder" {

    # Al reves de lo que dicen los nombres, y la razon de que exista la funcion.
    It "en un Windows de 64 bits, las de 32 estan en SysWOW64" {
        if (-not [Environment]::Is64BitOperatingSystem) { return }
        Get-SystemDllFolder -Arch x86 | Should Be (Join-Path $env:SystemRoot 'SysWOW64')
    }

    It "las de 64 no estan en SysWOW64" {
        if (-not [Environment]::Is64BitOperatingSystem) { return }
        Get-SystemDllFolder -Arch x64 | Should Not Match 'SysWOW64'
    }
}

Describe "Test-AppDependencies: por que no arranca un programa" {

    # -Path @(): que el PATH de quien ejecuta las pruebas no cuele DLL suyas.
    function New-App {
        $d = New-CarpetaTemporal
        return [PSCustomObject]@{ Raiz = $d; Exe = (Join-Path $d 'PUENTE.EXE') }
    }

    It "dice lo que falta y, si es de Visual C++, como ponerlo" {
        $a = New-App
        try {
            New-PeDePrueba -Ruta $a.Exe -Arch x86 -Importa @('mfc110.dll', 'KERNEL32.dll') | Out-Null
            $f = @(Test-AppDependencies -Exe $a.Exe -Path @())
            $mfc = @($f | Where-Object { $_.Dll -eq 'mfc110.dll' })[0]
            $mfc.Estado | Should Be 'falta'
            $mfc.Consejo | Should Match 'Visual C\+\+ 2012'
            $mfc.Consejo | Should Match 'Install-VCRuntime\.bat -App'
            (@($f | Where-Object { $_.Dll -eq 'KERNEL32.dll' })[0]).Estado | Should Be 'ok'
        }
        finally { Remove-Item -LiteralPath $a.Raiz -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # El 0xc000007b que no nombra nada: la DLL esta, pero no le sirve.
    It "una DLL de la otra arquitectura junto al programa sale como tal" {
        $a = New-App
        try {
            New-PeDePrueba -Ruta $a.Exe -Arch x86 -Importa @('PROPIA.dll') | Out-Null
            New-PeDePrueba -Ruta (Join-Path $a.Raiz 'PROPIA.dll') -Arch x64 | Out-Null
            $p = @(Test-AppDependencies -Exe $a.Exe -Path @())[0]
            $p.Estado | Should Be 'otra arquitectura'
            $p.Consejo | Should Match '0xc000007b'
        }
        finally { Remove-Item -LiteralPath $a.Raiz -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # Lo que el mensaje de Windows no dice: la que falta la pide OTRA DLL.
    It "sigue la cadena: lo que falta a una DLL del programa, y quien lo pide" {
        $a = New-App
        try {
            New-PeDePrueba -Ruta $a.Exe -Arch x64 -Importa @('MOTOR.dll') | Out-Null
            New-PeDePrueba -Ruta (Join-Path $a.Raiz 'MOTOR.dll') -Arch x64 -Importa @('LIBRERIA.dll') | Out-Null
            $l = @(Test-AppDependencies -Exe $a.Exe -Path @() | Where-Object { $_.Dll -eq 'LIBRERIA.dll' })[0]
            $l.Estado | Should Be 'falta'
            $l.PedidaPor | Should Be 'MOTOR.dll'
        }
        finally { Remove-Item -LiteralPath $a.Raiz -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "la busca en el PATH despues de la carpeta del programa" {
        $a = New-App
        try {
            $otra = Join-Path $a.Raiz 'otra'
            New-Item -ItemType Directory -Path $otra | Out-Null
            New-PeDePrueba -Ruta $a.Exe -Arch x64 -Importa @('ENPATH.dll') | Out-Null
            New-PeDePrueba -Ruta (Join-Path $otra 'ENPATH.dll') -Arch x64 | Out-Null
            $p = @(Test-AppDependencies -Exe $a.Exe -Path @($otra))[0]
            $p.Estado | Should Be 'ok'
            $p.Origen | Should Be 'PATH'
        }
        finally { Remove-Item -LiteralPath $a.Raiz -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # Una diferida no impide arrancar; si otra DLL la pide normal, ya si.
    It "marca las diferidas, salvo que alguien la pida normal" {
        $a = New-App
        try {
            New-PeDePrueba -Ruta $a.Exe -Arch x64 -Importa @('MOTOR.dll') -Diferidas @('OPCIONAL.dll', 'COMPARTIDA.dll') | Out-Null
            New-PeDePrueba -Ruta (Join-Path $a.Raiz 'MOTOR.dll') -Arch x64 -Importa @('COMPARTIDA.dll') | Out-Null
            $f = @(Test-AppDependencies -Exe $a.Exe -Path @())
            (@($f | Where-Object { $_.Dll -eq 'OPCIONAL.dll' })[0]).Diferida | Should Be $true
            (@($f | Where-Object { $_.Dll -eq 'COMPARTIDA.dll' })[0]).Diferida | Should Be $false
        }
        finally { Remove-Item -LiteralPath $a.Raiz -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "las api-ms-win-* son de Windows: no se buscan como archivos" {
        $a = New-App
        try {
            New-PeDePrueba -Ruta $a.Exe -Arch x64 -Importa @('api-ms-win-core-synch-l1-2-0.dll') | Out-Null
            (@(Test-AppDependencies -Exe $a.Exe -Path @())[0]).Estado | Should Be 'windows'
        }
        finally { Remove-Item -LiteralPath $a.Raiz -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "una DLL de depuracion de Visual C++ dice que hay que recompilar" {
        Get-MissingDllAdvice -Dll 'vcruntime140d.dll' | Should Match 'Debug'
        Get-MissingDllAdvice -Dll 'MSVCR110D.dll' | Should Match 'Debug'
    }

    It "una de otra version de Visual C++ dice que el kit no la trae" {
        Get-MissingDllAdvice -Dll 'MSVCR100.dll' | Should Match 'no trae'
    }

    # Con notepad.exe, cuya carpeta es System32, recorrer lo de Windows era leer
    # cientos de DLL y sacar como "faltan" las diferidas de las suyas.
    It "no recorre lo que vive en la carpeta de Windows" {
        $f = @(Test-AppDependencies -Exe (Join-Path $env:SystemRoot 'System32\notepad.exe') -Path @())
        $f.Count | Should BeLessThan 150
        @($f | Where-Object { $_.Estado -eq 'falta' -and -not $_.Diferida }).Count | Should Be 0
    }

    It "un archivo que no es un programa devuelve nulo" {
        $a = New-App
        try {
            Set-Content -LiteralPath $a.Exe -Value 'no soy un exe'
            Test-AppDependencies -Exe $a.Exe | Should BeNullOrEmpty
        }
        finally { Remove-Item -LiteralPath $a.Raiz -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
