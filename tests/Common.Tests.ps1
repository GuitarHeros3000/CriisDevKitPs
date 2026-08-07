#Requires -Version 5.1
<#
    Pruebas de las funciones puras de lib\Common.ps1: las que solo transforman
    un valor de entrada en uno de salida, sin tocar red, disco ni registro.

    Casi todas cubren un fallo que existio de verdad. Se anotan con el sintoma
    que producian, porque un test sin contexto se acaba borrando cuando estorba.
#>

. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

Describe "Format-ProxyForDisplay" {

    It "oculta la clave y conserva el usuario" {
        Format-ProxyForDisplay 'http://usuario:clave@proxy.empresa:8080' |
            Should Be 'http://usuario:***@proxy.empresa:8080'
    }

    # El fallo original: con [^/@]* la captura paraba en el PRIMER arroba, asi
    # que de "P@ssw0rd" se publicaba "***@ssw0rd". Y una clave con arroba mas una
    # cuenta de dominio es justo el caso corporativo tipico.
    It "tapa la clave entera aunque contenga un arroba" {
        $r = Format-ProxyForDisplay 'https://dominio\crisr:P@ssw0rd@proxy.empresa:8080'
        $r | Should Be 'https://dominio\crisr:***@proxy.empresa:8080'
        $r | Should Not Match 'ssw0rd'
    }

    It "admite usuarios con formato de correo" {
        Format-ProxyForDisplay 'http://user@corp.com:clave@proxy:8080' |
            Should Be 'http://user@corp.com:***@proxy:8080'
    }

    It "no toca una URL sin credenciales" -TestCases @(
        @{ Entrada = 'http://proxy.empresa:8080' }
        @{ Entrada = 'proxy.empresa:8080' }
        @{ Entrada = 'http://usuario@proxy.empresa:8080' }
        @{ Entrada = 'http://proxy.empresa/pac.dat' }
    ) {
        param($Entrada)
        Format-ProxyForDisplay $Entrada | Should Be $Entrada
    }

    # [^/] impide que la coincidencia cruce la barra: un arroba en la RUTA de un
    # PAC no es una credencial.
    It "no confunde un arroba de la ruta con una credencial" {
        Format-ProxyForDisplay 'http://proxy.empresa:8080/pac@raro' |
            Should Be 'http://proxy.empresa:8080/pac@raro'
    }

    It "tolera vacio y nulo" {
        Format-ProxyForDisplay '' | Should Be ''
        Format-ProxyForDisplay $null | Should BeNullOrEmpty
    }
}

Describe "Escapado de codigo generado" {

    Context "ConvertTo-PsLiteral (comillas simples de PowerShell)" {

        # Sintoma: un usuario llamado O'Brien producia un activate.ps1 roto, y
        # como lo carga el perfil, TODAS las terminales nuevas fallaban al abrir.
        It "duplica la comilla simple" {
            ConvertTo-PsLiteral "C:\Users\O'Brien" | Should Be "C:\Users\O''Brien"
        }

        It "deja intacto lo que no lleva comilla" {
            ConvertTo-PsLiteral 'C:\Users\crisr' | Should Be 'C:\Users\crisr'
        }

        # Lo escapado tiene que volver a valer EXACTAMENTE lo de partida al
        # evaluarlo como literal de PowerShell.
        It "el literal resultante vale lo mismo que la entrada" -TestCases @(
            @{ Ruta = "C:\Users\O'Brien\activate.ps1" }
            @{ Ruta = 'C:\Users\dev$user\activate.ps1' }
            @{ Ruta = 'C:\Users\a`b\activate.ps1' }
        ) {
            param($Ruta)
            $codigo = "'{0}'" -f (ConvertTo-PsLiteral $Ruta)
            (& ([scriptblock]::Create($codigo))) | Should Be $Ruta
        }
    }

    Context "ConvertTo-CmdLiteral (dentro de set `"VAR=...`")" {

        It "duplica el porcentaje" {
            ConvertTo-CmdLiteral 'C:\datos 100%' | Should Be 'C:\datos 100%%'
        }

        # Las comillas del set ya cubren estos, asi que NO deben tocarse: si se
        # escaparan, el valor final llevaria circunflejos de mas.
        It "no toca & ^ ni los espacios, que ya cubren las comillas" {
            ConvertTo-CmdLiteral 'C:\Marks & Spencer ^dev' | Should Be 'C:\Marks & Spencer ^dev'
        }
    }

    Context "ConvertFrom-CmdLiteral (al releer un shell generado)" {

        # Sin esto, una ruta con porcentaje se reescapaba en cada pasada de
        # Use-Env: %% -> %%%% -> %%%%%%%%
        It "deshace exactamente lo que hizo ConvertTo-CmdLiteral" -TestCases @(
            @{ Ruta = 'C:\datos 100%' }
            @{ Ruta = 'C:\Marks & Spencer 100% ^dev' }
            @{ Ruta = 'C:\normal\sin\nada' }
        ) {
            param($Ruta)
            ConvertFrom-CmdLiteral (ConvertTo-CmdLiteral $Ruta) | Should Be $Ruta
        }
    }

    Context "ConvertTo-CmdEchoText (linea echo, sin comillas posibles)" {

        It "escapa los especiales de cmd" {
            ConvertTo-CmdEchoText 'Marks & Spencer' | Should Be 'Marks ^& Spencer'
            ConvertTo-CmdEchoText 'a|b' | Should Be 'a^|b'
            ConvertTo-CmdEchoText 'a<b>c' | Should Be 'a^<b^>c'
            ConvertTo-CmdEchoText '100%' | Should Be '100%%'
        }

        # El circunflejo va PRIMERO por ser el propio caracter de escape. Si se
        # hiciera al final, escaparia los que se acaban de anadir y saldria
        # "Marks ^^& Spencer", que imprime un circunflejo de mas.
        It "escapa el circunflejo antes que el resto" {
            ConvertTo-CmdEchoText '^' | Should Be '^^'
            ConvertTo-CmdEchoText '^&' | Should Be '^^^&'
        }
    }
}

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

    # LIMITACION CONOCIDA, no un acierto. El README la documenta: no se soportan
    # comodines ni rangos con guion. Se fija aqui para que quede constancia de que
    # el comportamiento es "devuelve false en silencio", y para que este test
    # falle -avisando- el dia que alguien anada soporte de verdad.
    It "NO soporta comodines: 1.x se interpreta como 1.0.0 exacto" {
        Test-SemverRange -Version '1.5.0' -Range '1.x' | Should Be $false
        Test-SemverRange -Version '1.0.0' -Range '1.x' | Should Be $true
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

Describe "Split-UserPath" {

    It "descarta entradas vacias y solo-espacios" {
        (Split-UserPath -Value 'C:\a;;C:\b;   ;C:\c').Count | Should Be 3
    }

    It "devuelve coleccion vacia para un PATH vacio" {
        (Split-UserPath -Value '').Count | Should Be 0
    }
}

Describe "Constructores de URL de descarga" {

    It "Get-NodeArchiveInfo compone la URL y el nombre de carpeta" {
        $i = Get-NodeArchiveInfo -Version '22.23.2'
        $i.FolderName | Should Be 'node-v22.23.2-win-x64'
        $i.Url        | Should Be 'https://nodejs.org/dist/v22.23.2/node-v22.23.2-win-x64.zip'
        $i.ShasumsUrl | Should Be 'https://nodejs.org/dist/v22.23.2/SHASUMS256.txt'
    }

    It "Get-NodeArchiveInfo tolera la v inicial" {
        (Get-NodeArchiveInfo -Version 'v22.23.2').FolderName | Should Be 'node-v22.23.2-win-x64'
    }

    It "Get-PythonArchiveInfo apunta al zip embeddable" {
        (Get-PythonArchiveInfo -FullVersion '3.12.10').Url |
            Should Be 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip'
    }
}
