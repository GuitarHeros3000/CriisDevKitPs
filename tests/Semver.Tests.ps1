#Requires -Version 5.1
<#
    Pruebas de lib\Semver.ps1.

    Casi todas cubren un fallo que existio de verdad. Se anotan con el sintoma
    que producian, porque un test sin contexto se acaba borrando cuando estorba.
#>

. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

Describe "Test-SemverRange" {

    # La tabla real de engines.node del Angular CLI, verificada contra
    # registry.npmjs.org. Es lo que decide que Node se descarga.
    It "acierta con los engines reales del CLI" -TestCases @(
        @{ Rango = '^14.15.0 || >=16.10.0';                Version = '16.20.2'; Esperado = $true }
        @{ Rango = '^18.13.0 || >=20.9.0';                 Version = '18.20.8'; Esperado = $true }
        @{ Rango = '^18.19.1 || ^20.11.1 || >=22.0.0';     Version = '20.20.2'; Esperado = $true }
        @{ Rango = '^20.19.0 || ^22.12.0 || >=24.0.0';     Version = '22.23.2'; Esperado = $true }
        @{ Rango = '^22.22.3 || ^24.15.0 || >=26.0.0';     Version = '24.19.0'; Esperado = $true }
        @{ Rango = '^22.22.3 || ^24.15.0 || >=26.0.0';     Version = '20.20.2'; Esperado = $false }
        @{ Rango = '^20.19.0 || ^22.12.0 || >=24.0.0';     Version = '18.20.8'; Esperado = $false }
    ) {
        param($Rango, $Version, $Esperado)
        Test-SemverRange -Version $Version -Range $Rango | Should Be $Esperado
    }

    It "respeta el tope de mayor que impone el circunflejo" {
        Test-SemverRange -Version '20.0.0' -Range '^20.19.0' | Should Be $false
        Test-SemverRange -Version '21.0.0' -Range '^20.19.0' | Should Be $false
        Test-SemverRange -Version '20.19.0' -Range '^20.19.0' | Should Be $true
    }

    It "respeta el tope de menor que impone la virgulilla" {
        Test-SemverRange -Version '20.19.5' -Range '~20.19.0' | Should Be $true
        Test-SemverRange -Version '20.20.0' -Range '~20.19.0' | Should Be $false
    }

    It "trata los comparadores separados por espacio como conjuncion" {
        Test-SemverRange -Version '20.0.0' -Range '>=18.0.0 <21.0.0' | Should Be $true
        Test-SemverRange -Version '21.0.0' -Range '>=18.0.0 <21.0.0' | Should Be $false
    }

    It "ignora la v inicial y los sufijos de prerelease" {
        Test-SemverRange -Version 'v20.19.0'      -Range '^20.19.0' | Should Be $true
        Test-SemverRange -Version '20.19.0-rc.1'  -Range '^20.19.0' | Should Be $true
    }

    # "14.x" es de lo mas comun en un campo engines. Antes se trataba como version
    # EXACTA (la x se descartaba al normalizar), asi que "14.x" significaba
    # "exactamente 14.0.0" y cualquier 14.21 quedaba fuera, en silencio.
    It "entiende los comodines" -TestCases @(
        @{ Rango = '14.x';    Version = '14.21.3'; Esperado = $true }
        @{ Rango = '14.x';    Version = '14.0.0';  Esperado = $true }
        @{ Rango = '14.x';    Version = '15.0.0';  Esperado = $false }
        @{ Rango = '14.*';    Version = '14.21.3'; Esperado = $true }
        @{ Rango = '20.19.x'; Version = '20.19.9'; Esperado = $true }
        @{ Rango = '20.19.x'; Version = '20.20.0'; Esperado = $false }
    ) {
        param($Rango, $Version, $Esperado)
        Test-SemverRange -Version $Version -Range $Rango | Should Be $Esperado
    }

    # Una version parcial es un RANGO en semver, no una version exacta:
    # "20" equivale a 20.x.x y "20.19" a 20.19.x.
    It "trata las versiones parciales como rango" -TestCases @(
        @{ Rango = '20';    Version = '20.19.2'; Esperado = $true }
        @{ Rango = '20';    Version = '21.0.0';  Esperado = $false }
        @{ Rango = '20.19'; Version = '20.19.9'; Esperado = $true }
        @{ Rango = '20.19'; Version = '20.20.0'; Esperado = $false }
    ) {
        param($Rango, $Version, $Esperado)
        Test-SemverRange -Version $Version -Range $Rango | Should Be $Esperado
    }

    It "una version completa sigue siendo exacta" {
        Test-SemverRange -Version '20.19.2' -Range '20.19.2' | Should Be $true
        Test-SemverRange -Version '20.19.3' -Range '20.19.2' | Should Be $false
    }
}

Describe "Get-UnsupportedSemverComparators" {

    # Existe para poder avisar UNA vez antes de usar el rango, en vez de que
    # Test-SemverRange devuelva $false en silencio por cada candidata.
    It "no senala nada en los rangos que si se entienden" -TestCases @(
        @{ Rango = '^18.19.1 || ^20.11.1 || >=22.0.0' }
        @{ Rango = '14.x' }
        @{ Rango = '>=18.0.0 <21.0.0' }
        @{ Rango = '*' }
    ) {
        param($Rango)
        (Get-UnsupportedSemverComparators -Range $Rango).Count | Should Be 0
    }

    # Los rangos con guion siguen sin soportarse; la diferencia es que ahora se
    # avisa en vez de descartar en silencio.
    It "senala el guion de un rango con guion" {
        $r = Get-UnsupportedSemverComparators -Range '1.2 - 1.5'
        $r -contains '-' | Should Be $true
    }

    It "senala la basura que no reconoce" {
        (Get-UnsupportedSemverComparators -Range 'lo-que-sea').Count | Should Be 1
    }
}

Describe "ConvertTo-SemverObject" {

    It "normaliza a tres componentes" {
        (ConvertTo-SemverObject '20').ToString()      | Should Be '20.0.0'
        (ConvertTo-SemverObject '20.19').ToString()   | Should Be '20.19.0'
        (ConvertTo-SemverObject 'v20.19.2').ToString()| Should Be '20.19.2'
    }

    It "descarta prerelease y metadatos de build" {
        (ConvertTo-SemverObject '20.19.2-rc.1').ToString()  | Should Be '20.19.2'
        (ConvertTo-SemverObject '20.19.2+build5').ToString()| Should Be '20.19.2'
    }
}
