#Requires -Version 5.1
<#
    Pruebas de lib\Proxy.ps1.

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
        $r = Format-ProxyForDisplay 'https://dominio\usuario:P@ssw0rd@proxy.empresa:8080'
        $r | Should Be 'https://dominio\usuario:***@proxy.empresa:8080'
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

Describe "Protect-ProxySecrets" {

    # Enmascarar solo lo que imprime el kit no bastaba: los mensajes de excepcion
    # de .NET incrustan la URL del proxy tal cual, y ese texto se imprimia y
    # quedaba en el registro. Esta funcion enmascara en cualquier posicion.
    It "tapa la clave en medio de un mensaje de error" {
        $msg = 'No se puede convertir el valor "http://usuario:MiClave@proxy.empresa:8080" al tipo "System.Uri".'
        $r = Protect-ProxySecrets -Text $msg
        $r | Should Not Match 'MiClave'
        $r | Should Match ':\*\*\*@proxy\.empresa:8080'
    }

    It "tapa varias apariciones en el mismo texto" {
        $msg = 'fallo con http://u:c1@p1:8080 y con http://u:c2@p2:8080'
        $r = Protect-ProxySecrets -Text $msg
        $r | Should Not Match 'c1'
        $r | Should Not Match 'c2'
    }

    It "no toca una URL normal" {
        $msg = 'No se pudo descargar https://nodejs.org/dist/index.json'
        Protect-ProxySecrets -Text $msg | Should Be $msg
    }

    It "tolera vacio y nulo" {
        Protect-ProxySecrets -Text '' | Should Be ''
        Protect-ProxySecrets -Text $null | Should BeNullOrEmpty
    }

    It "sobre un texto ya enmascarado no hace nada" {
        $ya = 'Proxy detectado: http://usuario:***@proxy:8080'
        Protect-ProxySecrets -Text $ya | Should Be $ya
    }
}

Describe "Fuentes configurables (espejo interno)" {

    # Sirven para una red donde IT bloquea nodejs.org o pypi.org pero mantiene un
    # espejo interno. Sin esto el kit no puede hacer nada en esa red.

    Context "Resolve-SourceUrl" {

        $reglas = @(
            [PSCustomObject]@{ De = 'https://nodejs.org/dist/'; A = 'https://nexus.empresa.com/nodejs/' }
            [PSCustomObject]@{ De = 'https://www.python.org/ftp/python/'; A = 'https://nexus.empresa.com/python/' }
        )

        It "reescribe el principio y conserva el resto de la ruta" {
            Resolve-SourceUrl -Uri 'https://nodejs.org/dist/v22.23.2/node-v22.23.2-win-x64.zip' -Rules $reglas |
                Should Be 'https://nexus.empresa.com/nodejs/v22.23.2/node-v22.23.2-win-x64.zip'
        }

        It "no toca una URL que ninguna regla cubre" {
            Resolve-SourceUrl -Uri 'https://api.adoptium.net/v3/info' -Rules $reglas |
                Should Be 'https://api.adoptium.net/v3/info'
        }

        It "sin reglas devuelve la URL tal cual" {
            Resolve-SourceUrl -Uri 'https://nodejs.org/dist/x.zip' -Rules @() |
                Should Be 'https://nodejs.org/dist/x.zip'
            Resolve-SourceUrl -Uri 'https://nodejs.org/dist/x.zip' -Rules $null |
                Should Be 'https://nodejs.org/dist/x.zip'
        }

        # Poder tener una regla general y excepciones debajo depende de esto.
        It "gana la regla mas especifica, no la primera" {
            $conExcepcion = @(
                [PSCustomObject]@{ De = 'https://github.com/'; A = 'https://espejo/general/' }
                [PSCustomObject]@{ De = 'https://github.com/adoptium/'; A = 'https://espejo/jdk/' }
            )
            Resolve-SourceUrl -Uri 'https://github.com/adoptium/temurin21/x.zip' -Rules $conExcepcion |
                Should Be 'https://espejo/jdk/temurin21/x.zip'
            Resolve-SourceUrl -Uri 'https://github.com/otro/y.zip' -Rules $conExcepcion |
                Should Be 'https://espejo/general/otro/y.zip'
        }

        It "compara sin distinguir mayusculas en el dominio" {
            Resolve-SourceUrl -Uri 'https://NodeJS.org/dist/x.zip' -Rules $reglas |
                Should Be 'https://nexus.empresa.com/nodejs/x.zip'
        }

        It "una regla a medias se salta sin romper las demas" {
            $rotas = @(
                [PSCustomObject]@{ De = 'https://nodejs.org/dist/'; A = '' }
                [PSCustomObject]@{ De = 'https://www.python.org/ftp/python/'; A = 'https://espejo/py/' }
            )
            Resolve-SourceUrl -Uri 'https://nodejs.org/dist/x.zip' -Rules $rotas |
                Should Be 'https://nodejs.org/dist/x.zip'
            Resolve-SourceUrl -Uri 'https://www.python.org/ftp/python/3.12.10/x.zip' -Rules $rotas |
                Should Be 'https://espejo/py/3.12.10/x.zip'
        }
    }

    Context "Read-SourceRules" {

        # Un espejo mal escrito no debe tumbar el kit: lo peor que puede pasar es
        # que se salga por la fuente oficial.
        It "acepta una configuracion correcta" {
            $cfg = ConvertFrom-Json '{ "reglas": [ { "de": "https://a/", "a": "https://b/" } ] }'
            $r = @(Read-SourceRules -Config $cfg)
            $r.Count | Should Be 1
            $r[0].De | Should Be 'https://a/'
            $r[0].A  | Should Be 'https://b/'
        }

        It "descarta las reglas sin de o sin a" {
            $cfg = ConvertFrom-Json '{ "reglas": [ { "de": "https://a/" }, { "a": "https://b/" }, { "de": "https://c/", "a": "https://d/" } ] }'
            @(Read-SourceRules -Config $cfg 3>$null 6>$null).Count | Should Be 1
        }

        It "descarta las que no son http ni https" {
            $cfg = ConvertFrom-Json '{ "reglas": [ { "de": "ftp://a/", "a": "https://b/" }, { "de": "https://c/", "a": "carpeta\\local" } ] }'
            @(Read-SourceRules -Config $cfg 3>$null 6>$null).Count | Should Be 0
        }

        It "sin reglas y con configuracion nula devuelve vacio" {
            @(Read-SourceRules -Config $null).Count | Should Be 0
            @(Read-SourceRules -Config (ConvertFrom-Json '{}')).Count | Should Be 0
        }
    }
}

Describe "Split-ProxyCredential" {

    # Existe por un fallo comprobado contra un proxy Basic de verdad: el kit
    # ponia "http://usuario:clave@proxy:8080" entero en -Proxy, Invoke-WebRequest
    # descartaba usuario y clave, y el proxy devolvia 407 exactamente igual que
    # con la clave equivocada. Lo peor era el consejo que daba entonces: poner
    # las credenciales en HTTPS_PROXY, que es lo que el usuario ya habia hecho.

    It "separa usuario y clave de la direccion" {
        $r = Split-ProxyCredential -Proxy "http://kituser:cl4ve@proxy.empresa:8080"
        $r.Direccion | Should Be "http://proxy.empresa:8080"
        $r.Credencial.UserName | Should Be "kituser"
        $r.Credencial.GetNetworkCredential().Password | Should Be "cl4ve"
    }

    It "devuelve la direccion tal cual cuando no hay credenciales" {
        $r = Split-ProxyCredential -Proxy "http://proxy.empresa:8080"
        $r.Direccion  | Should Be "http://proxy.empresa:8080"
        $r.Credencial | Should BeNullOrEmpty
    }

    # Una cuenta de dominio se escribe con %5C porque la barra invertida cruda
    # invalida la URI entera; al proxy hay que enviarle la barra de verdad.
    It "desescapa una cuenta de dominio escrita con %5C" {
        $r = Split-ProxyCredential -Proxy "http://dominio%5Cusuario:cl4ve@proxy:8080"
        $r.Credencial.UserName | Should Be "dominio\usuario"
    }

    It "desescapa los caracteres especiales de la clave" {
        # Una clave con arroba obliga a escribirla como %40; si no se desescapa,
        # al proxy le llega la clave equivocada y responde 407 sin mas.
        $r = Split-ProxyCredential -Proxy "http://u:P%40ssw0rd%3A1@proxy:8080"
        $r.Credencial.GetNetworkCredential().Password | Should Be 'P@ssw0rd:1'
    }

    It "admite clave vacia sin reventar" {
        $r = Split-ProxyCredential -Proxy "http://soloUsuario:@proxy:8080"
        $r.Credencial.UserName | Should Be "soloUsuario"
        $r.Credencial.GetNetworkCredential().Password | Should Be ""
    }

    It "admite usuario sin dos puntos" {
        $r = Split-ProxyCredential -Proxy "http://soloUsuario@proxy:8080"
        $r.Credencial.UserName | Should Be "soloUsuario"
    }

    It "una URL invalida no revienta: se devuelve sin credenciales" {
        $r = Split-ProxyCredential -Proxy "proxy.empresa:8080"
        $r.Credencial | Should BeNullOrEmpty
    }

    It "conserva la ruta si el proxy la lleva" {
        $r = Split-ProxyCredential -Proxy "http://u:c@proxy:8080/salida"
        $r.Direccion | Should Be "http://proxy:8080/salida"
    }

    It "la direccion limpia ya no contiene la clave" {
        $r = Split-ProxyCredential -Proxy "http://kituser:cl4veSecreta@proxy:8080"
        $r.Direccion | Should Not Match 'cl4veSecreta'
    }
}

Describe "Add-ProxyToRequest" {

    # Lo que importa aqui es la combinacion de parametros: ProxyCredential y
    # ProxyUseDefaultCredentials son mutuamente excluyentes, PowerShell rechaza
    # la llamada si van los dos.

    $guardado = @{ H = $env:HTTPS_PROXY; A = $env:ALL_PROXY }

    It "con credenciales en la URL usa ProxyCredential y NO el modo integrado" {
        $env:HTTPS_PROXY = "http://kituser:cl4ve@127.0.0.1:8899"
        try {
            $p = @{}
            Add-ProxyToRequest -Params $p -Uri ([Uri]"https://nodejs.org/x")
            $p.Proxy | Should Be "http://127.0.0.1:8899"
            $p.ProxyCredential.UserName | Should Be "kituser"
            $p.ContainsKey('ProxyUseDefaultCredentials') | Should Be $false
        }
        finally { $env:HTTPS_PROXY = $guardado.H }
    }

    It "sin credenciales recurre a la identidad de Windows" {
        $env:HTTPS_PROXY = "http://127.0.0.1:8899"
        try {
            $p = @{}
            Add-ProxyToRequest -Params $p -Uri ([Uri]"https://nodejs.org/x")
            $p.ProxyUseDefaultCredentials | Should Be $true
            $p.ContainsKey('ProxyCredential') | Should Be $false
        }
        finally { $env:HTTPS_PROXY = $guardado.H }
    }

    It "con un proxy invalido no toca los parametros" {
        $env:HTTPS_PROXY = "proxy-sin-esquema:8080"
        try {
            $p = @{}
            Add-ProxyToRequest -Params $p -Uri ([Uri]"https://nodejs.org/x") 3>$null 6>$null
            $p.ContainsKey('Proxy') | Should Be $false
        }
        finally { $env:HTTPS_PROXY = $guardado.H }
    }
}

Describe "Test-ProxyUsable" {

    BeforeEach { Mock Write-Log { } }

    It "acepta una URL de proxy valida" -TestCases @(
        @{ Proxy = 'http://proxy.empresa:8080' }
        @{ Proxy = 'http://usuario:clave@proxy.empresa:8080' }
        @{ Proxy = 'http://dominio%5Cusuario:clave@proxy.empresa:8080' }
    ) {
        param($Proxy)
        Test-ProxyUsable -Proxy $Proxy | Should Be $true
    }

    # Con la barra invertida sin codificar la URI es invalida y el proxy NO
    # funciona: Invoke-WebRequest ni consigue enlazar el parametro. Ademas, ese
    # fallo hacia que PowerShell escribiera la clave en claro en el transcript.
    It "rechaza una cuenta de dominio sin codificar" {
        Test-ProxyUsable -Proxy 'http://dominio\usuario:clave@proxy.empresa:8080' | Should Be $false
    }

    It "rechaza un proxy sin esquema" -TestCases @(
        @{ Proxy = 'proxy.empresa:8080' }
        @{ Proxy = '10.20.30.40:8080' }
    ) {
        param($Proxy)
        # .NET no admite un proxy sin http:// delante. Nunca funciono, pero antes
        # fallaba con un error incomprensible mucho mas adelante.
        Test-ProxyUsable -Proxy $Proxy | Should Be $false
    }

    # La pista tiene que apuntar a la causa real: una version anterior soltaba
    # siempre el consejo del %5C, incluso cuando lo que faltaba era el esquema.
    It "la pista corresponde a la causa" -TestCases @(
        @{ Proxy = 'proxy.empresa:8080';                          Espera = 'esquema'; NoEspera = '%5C' }
        @{ Proxy = 'http://dominio\usuario:c@proxy.empresa:8080'; Espera = '%5C';     NoEspera = 'esquema' }
    ) {
        param($Proxy, $Espera, $NoEspera)
        $dichos = New-Object System.Collections.ArrayList
        Mock Write-Log { $dichos.Add($Message) | Out-Null }

        Test-ProxyUsable -Proxy $Proxy | Out-Null

        $todo = ($dichos -join ' ')
        $todo | Should Match $Espera
        $todo | Should Not Match $NoEspera
    }

    It "explica como arreglarlo sin mostrar la clave" {
        # ArrayList y .Add() en vez de "$x += ...": el scriptblock del mock corre
        # en su propio ambito, asi que el += crearia una copia local y la de fuera
        # quedaria vacia. Una coleccion se muta por referencia y si funciona.
        $dichos = New-Object System.Collections.ArrayList
        Mock Write-Log { $dichos.Add($Message) | Out-Null }

        Test-ProxyUsable -Proxy 'http://dominio\usuario:MiClaveSecreta@proxy:8080' | Out-Null

        $todo = ($dichos -join ' ')
        $todo | Should Match '%5C'
        $todo | Should Not Match 'MiClaveSecreta'
    }
}
