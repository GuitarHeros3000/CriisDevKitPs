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
                $d.Url    | Should Match '^https://download\.microsoft\.com/'
                $d.Sha256 | Should Match '^[0-9a-f]{64}$'
            }
        }
    }

    It "el sufijo es el que llevan sus DLL" {
        foreach ($v in $catalogo) { $v.Sufijo | Should Match '^\d{2,3}$' }
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
