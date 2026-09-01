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

Describe "Get-DownloadErrorHint con un 407" {

    # El consejo tiene que depender de si ya habia credenciales puestas. Antes
    # era siempre el mismo y, a quien ya las tenia puestas, le pedia hacer lo
    # que acababa de hacer.
    # Un ErrorRecord de verdad: el parametro esta tipado y no acepta un
    # PSCustomObject cualquiera. La propiedad Response se cuelga de la excepcion
    # con Add-Member, que es exactamente como la busca Get-WebErrorStatus.
    function Error407 {
        param([string]$Mensaje = "proxy auth")
        $exc = New-Object System.Exception($Mensaje)
        $exc | Add-Member -NotePropertyName Response `
                          -NotePropertyValue (New-Object PSObject -Property @{ StatusCode = 407 }) -Force
        return (New-Object System.Management.Automation.ErrorRecord(
            $exc, 'prueba407', [System.Management.Automation.ErrorCategory]::NotSpecified, $null))
    }

    $guardado = @{ H = $env:HTTPS_PROXY; P = $env:HTTP_PROXY; A = $env:ALL_PROXY }
    function LimpiarProxy { $env:HTTPS_PROXY = $null; $env:HTTP_PROXY = $null; $env:ALL_PROXY = $null }

    It "sin credenciales puestas, dice como ponerlas" {
        LimpiarProxy
        try {
            $h = Get-DownloadErrorHint -ErrorRecord (Error407)
            $h | Should Match 'Define el proxy con tus credenciales'
        }
        finally { $env:HTTPS_PROXY = $guardado.H; $env:HTTP_PROXY = $guardado.P; $env:ALL_PROXY = $guardado.A }
    }

    It "con credenciales puestas, dice que las rechazo" {
        LimpiarProxy
        $env:HTTPS_PROXY = "http://kituser:cl4ve@proxy.empresa:8080"
        try {
            $h = Get-DownloadErrorHint -ErrorRecord (Error407)
            $h | Should Match 'rechazo tus credenciales'
            $h | Should Not Match 'Define el proxy con tus credenciales'
        }
        finally { $env:HTTPS_PROXY = $guardado.H; $env:HTTP_PROXY = $guardado.P; $env:ALL_PROXY = $guardado.A }
    }

    It "un proxy sin credenciales no cuenta como credenciales puestas" {
        LimpiarProxy
        $env:HTTPS_PROXY = "http://proxy.empresa:8080"
        try {
            (Get-DownloadErrorHint -ErrorRecord (Error407)) | Should Match 'Define el proxy con tus credenciales'
        }
        finally { $env:HTTPS_PROXY = $guardado.H; $env:HTTP_PROXY = $guardado.P; $env:ALL_PROXY = $guardado.A }
    }

    # Comprobado contra un proxy que exige NTLM: en un equipo que no esta unido
    # al dominio, DefaultNetworkCredentials viene vacio y SSPI corta el dialogo
    # tras el primer mensaje. El texto de .NET habla de "paquetes de seguridad",
    # que no le dice nada a nadie.
    It "distingue la autenticacion integrada sin identidad que ofrecer" {
        LimpiarProxy
        $env:HTTPS_PROXY = "http://proxy.empresa:8080"
        try {
            $h = Get-DownloadErrorHint -ErrorRecord (Error407 'Error en el servidor remoto: (407). No hay credenciales disponibles en el paquete de seguridad')
            $h | Should Match 'autenticacion integrada'
            $h | Should Match 'no estan unidos al dominio'
        }
        finally { $env:HTTPS_PROXY = $guardado.H; $env:HTTP_PROXY = $guardado.P; $env:ALL_PROXY = $guardado.A }
    }

    # Comprobado montando un HTTPS con una CA que el equipo no conoce, que es
    # lo que ve el kit tras un proxy que inspecciona HTTPS.
    It "un fallo de certificado apunta al almacen del usuario y avisa de la confirmacion" {
        $exc = New-Object System.Exception('Se ha terminado la conexion: No se puede establecer una relacion de confianza para el canal seguro SSL/TLS.')
        $er = New-Object System.Management.Automation.ErrorRecord(
            $exc, 'tls', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
        $h = Get-DownloadErrorHint -ErrorRecord $er
        $h | Should Match 'Usuario actual'
        $h | Should Match 'No necesita admin'
        # Sin esto, la confirmacion de Windows se confunde con el aviso de
        # administrador y se responde que no.
        $h | Should Match 'NO es el aviso de administrador'
    }

    It "el mismo caso en ingles tambien se reconoce" {
        LimpiarProxy
        try {
            $h = Get-DownloadErrorHint -ErrorRecord (Error407 'The remote server returned an error: (407). No credentials are available in the security package')
            $h | Should Match 'autenticacion integrada'
        }
        finally { $env:HTTPS_PROXY = $guardado.H; $env:HTTP_PROXY = $guardado.P; $env:ALL_PROXY = $guardado.A }
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

Describe "Git portable" {

    Context "Get-Sha256FromReleaseBody" {

        # Git for Windows publica los checksums en el CUERPO de la release, en
        # una tabla de texto libre. No es un campo de la API, asi que hay que
        # buscar la linea del archivo exacto.
        $cuerpo = @"
Please note that this is a maintenance release.

Filename | SHA-256
-------- | -------
Git-2.55.0.5-64-bit.exe | d065a4e23c3d9a6b5073d609b5be0830227ec3ca053c083ba385061ddfaf94c6
PortableGit-2.55.0.5-64-bit.7z.exe | 5aa8a20f6e9abb2c755f0e73c91c687701a46b309ad84a0ca6509380fa4ae290
MinGit-2.55.0.5-64-bit.zip | 56d7b226b7693196cfc71fef26568f536c4a021ab6c37ff2db4287bed908e96e
"@

        It "encuentra el hash del archivo pedido" {
            Get-Sha256FromReleaseBody -Body $cuerpo -FileName 'PortableGit-2.55.0.5-64-bit.7z.exe' |
                Should Be '5aa8a20f6e9abb2c755f0e73c91c687701a46b309ad84a0ca6509380fa4ae290'
        }

        # Los nombres se parecen mucho entre si; coger el de al lado seria dar
        # por bueno un archivo que no es.
        It "no confunde un archivo con otro de nombre parecido" {
            Get-Sha256FromReleaseBody -Body $cuerpo -FileName 'MinGit-2.55.0.5-64-bit.zip' |
                Should Be '56d7b226b7693196cfc71fef26568f536c4a021ab6c37ff2db4287bed908e96e'
        }

        It "devuelve nulo si ese archivo no esta en la tabla" {
            Get-Sha256FromReleaseBody -Body $cuerpo -FileName 'PortableGit-9.9.9-arm64.7z.exe' |
                Should BeNullOrEmpty
        }

        It "ignora la fila de cabecera y la de guiones" {
            Get-Sha256FromReleaseBody -Body $cuerpo -FileName 'Filename' | Should BeNullOrEmpty
            Get-Sha256FromReleaseBody -Body $cuerpo -FileName '--------' | Should BeNullOrEmpty
        }

        It "descarta lo que no tenga forma de SHA-256" {
            $malo = "PortableGit-1.0-64-bit.7z.exe | pendiente de publicar"
            Get-Sha256FromReleaseBody -Body $malo -FileName 'PortableGit-1.0-64-bit.7z.exe' |
                Should BeNullOrEmpty
        }

        It "tolera un cuerpo vacio o nulo" {
            Get-Sha256FromReleaseBody -Body ''   -FileName 'x' | Should BeNullOrEmpty
            Get-Sha256FromReleaseBody -Body $null -FileName 'x' | Should BeNullOrEmpty
        }
    }

    Context "Get-GitPortableAsset" {

        function ReleaseFalsa {
            param([string[]]$Nombres)
            return [PSCustomObject]@{
                tag_name = 'v2.55.0.windows.5'
                body     = "Filename | SHA-256`nPortableGit-2.55.0.5-64-bit.7z.exe | 5aa8a20f6e9abb2c755f0e73c91c687701a46b309ad84a0ca6509380fa4ae290"
                assets   = @($Nombres | ForEach-Object {
                    [PSCustomObject]@{ name = $_; browser_download_url = "https://ejemplo/$_" }
                })
            }
        }

        It "escoge el autoextraible de 64 bits y saca su version" {
            $r = Get-GitPortableAsset -Release (ReleaseFalsa @(
                'Git-2.55.0.5-64-bit.exe'
                'PortableGit-2.55.0.5-64-bit.7z.exe'
                'MinGit-2.55.0.5-64-bit.zip'))
            $r.Version  | Should Be '2.55.0.5'
            $r.FileName | Should Be 'PortableGit-2.55.0.5-64-bit.7z.exe'
            $r.Sha256   | Should Be '5aa8a20f6e9abb2c755f0e73c91c687701a46b309ad84a0ca6509380fa4ae290'
        }

        # Las releases traen tambien el de arm64, que en este equipo no sirve.
        It "no coge el de arm64" {
            $r = Get-GitPortableAsset -Release (ReleaseFalsa @('PortableGit-2.55.0.5-arm64.7z.exe'))
            $r | Should BeNullOrEmpty
        }

        It "devuelve nulo si la release no publica PortableGit" {
            $r = Get-GitPortableAsset -Release (ReleaseFalsa @('Git-2.55.0.5-64-bit.exe'))
            $r | Should BeNullOrEmpty
        }

        # Que falte el checksum no debe impedir instalar: se avisa y se sigue.
        It "sin checksum en el cuerpo, devuelve el resto igualmente" {
            $rel = ReleaseFalsa @('PortableGit-2.55.0.5-64-bit.7z.exe')
            $rel.body = 'sin tabla de checksums'
            $r = Get-GitPortableAsset -Release $rel
            $r.Version | Should Be '2.55.0.5'
            $r.Sha256  | Should BeNullOrEmpty
        }
    }

    Context "ConvertFrom-GitVersionOutput" {

        # Habia tres sitios parseando "git --version" cada uno a su manera, y
        # uno lo hacia mal: con [\d.]+ el cuantificador voraz se comia tambien
        # el punto de ".windows", asi que quedaba "2.55.0." y el sufijo ya no
        # encajaba. Se veia como "Git 2.55.0." al listar lo instalado.
        It "convierte la salida de Git for Windows al nombre del archivo publicado" {
            ConvertFrom-GitVersionOutput -Output 'git version 2.55.0.windows.5' | Should Be '2.55.0.5'
        }

        It "no deja el punto colgando" {
            (ConvertFrom-GitVersionOutput -Output 'git version 2.55.0.windows.5') |
                Should Not Match '\.$'
        }

        It "admite un numero de windows de dos cifras" {
            ConvertFrom-GitVersionOutput -Output 'git version 2.49.0.windows.12' | Should Be '2.49.0.12'
        }

        It "un Git que no sea el de Windows no lleva sufijo" {
            ConvertFrom-GitVersionOutput -Output 'git version 2.44.1' | Should Be '2.44.1'
        }

        It "tolera espacios y saltos alrededor" {
            ConvertFrom-GitVersionOutput -Output "`r`n  git version 2.55.0.windows.5  `r`n" | Should Be '2.55.0.5'
        }

        It "devuelve nulo con vacio o con algo que no es una version" {
            ConvertFrom-GitVersionOutput -Output ''      | Should BeNullOrEmpty
            ConvertFrom-GitVersionOutput -Output $null   | Should BeNullOrEmpty
            ConvertFrom-GitVersionOutput -Output 'error' | Should BeNullOrEmpty
        }

        It "lo que devuelve sirve para nombrar la carpeta" {
            $v = ConvertFrom-GitVersionOutput -Output 'git version 2.55.0.windows.5'
            Get-GitLine -Version $v | Should Be '2.55'
        }
    }

    Context "Get-GitLine" {

        # La carpeta se llama por la linea (git-2.55), no por la version
        # completa: si no, cada parche crearia una carpeta nueva y -Force
        # instalaria al lado en vez de reemplazar. Misma leccion que con Node.
        It "reduce la version a su linea" {
            Get-GitLine -Version '2.55.0.5' | Should Be '2.55'
            Get-GitLine -Version '2.56.1.1' | Should Be '2.56'
        }

        It "tolera la v inicial" {
            Get-GitLine -Version 'v2.55.0.5' | Should Be '2.55'
        }

        It "dos parches de la misma linea dan la misma carpeta" {
            (Get-GitLine -Version '2.55.0.1') | Should Be (Get-GitLine -Version '2.55.0.5')
        }
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
