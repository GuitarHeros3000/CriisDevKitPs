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

    Context "Get-HashFromChecksumText" {

        # No hay un formato unico para los archivos de checksum sueltos. Apache
        # publica el hash a secas, sha256sum pone "hash  archivo", y algun mirror
        # invierte el orden.
        It "acepta el hash a secas, como lo publica Apache" {
            $h = 'a' * 128
            Get-HashFromChecksumText -Text $h -Algorithm SHA512 | Should Be $h
        }

        It "acepta el formato de sha256sum" {
            $h = 'b' * 64
            Get-HashFromChecksumText -Text "$h  gradle-9.7.1-bin.zip" | Should Be $h
        }

        It "acepta el formato con el nombre delante" {
            $h = 'c' * 64
            Get-HashFromChecksumText -Text "gradle-9.7.1-bin.zip: $h" | Should Be $h
        }

        It "normaliza a minusculas" {
            Get-HashFromChecksumText -Text ('AB' * 32) | Should Be ('ab' * 32)
        }

        # Si el servidor devuelve una pagina de error en vez del checksum, dar
        # por bueno cualquier trozo hexadecimal seria peor que no verificar.
        It "no da por bueno un hash de longitud equivocada" {
            Get-HashFromChecksumText -Text ('a' * 64) -Algorithm SHA512 | Should BeNullOrEmpty
            Get-HashFromChecksumText -Text ('a' * 128) -Algorithm SHA256 | Should BeNullOrEmpty
        }

        It "no encuentra nada en una pagina de error" {
            Get-HashFromChecksumText -Text '<html><body>404 Not Found</body></html>' | Should BeNullOrEmpty
        }

        It "tolera vacio y nulo" {
            Get-HashFromChecksumText -Text ''    | Should BeNullOrEmpty
            Get-HashFromChecksumText -Text $null | Should BeNullOrEmpty
        }
    }

    Context "Get-ToolLine" {

        It "reduce a linea las versiones de Maven y Gradle" {
            Get-ToolLine -Version '3.9.16' | Should Be '3.9'
            Get-ToolLine -Version '9.7.1'  | Should Be '9.7'
        }

        It "dos parches de la misma linea dan la misma carpeta" {
            (Get-ToolLine -Version '3.9.6') | Should Be (Get-ToolLine -Version '3.9.16')
        }

        It "Get-GitLine delega en el, asi que dan lo mismo" {
            Get-GitLine -Version '2.55.0.5' | Should Be (Get-ToolLine -Version '2.55.0.5')
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

Describe "devenv.json (Read-DevEnvManifest)" {

    function Manifiesto($json) { return (ConvertFrom-Json $json) }

    It "devuelve los runtimes pedidos con su version" {
        $p = Read-DevEnvManifest -Config (Manifiesto '{ "version": 1, "runtimes": { "python": "3.12", "java": "21" } }')
        $p.Errores.Count  | Should Be 0
        $p.Runtimes.Count | Should Be 2
        ($p.Runtimes | Where-Object { $_.Clave -eq 'python' }).Version | Should Be '3.12'
    }

    # El orden lo fija el catalogo, no el archivo: Maven y Gradle necesitan un
    # JDK, asi que Java tiene que instalarse antes aunque en el JSON vaya despues.
    It "instala Java antes que Maven aunque el manifiesto los ponga al reves" {
        $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "maven": "3.9", "java": "21" } }')
        $p.Runtimes[0].Clave | Should Be 'java'
        $p.Runtimes[1].Clave | Should Be 'maven'
    }

    # Una errata no puede pasar en silencio: dejaria el entorno a medias sin
    # decir por que, que es lo contrario de para lo que sirve el comando.
    It "senala un runtime desconocido en vez de ignorarlo" {
        $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "phyton": "3.12" } }')
        $p.Errores.Count | Should BeGreaterThan 0
        ($p.Errores -join ' ') | Should Match 'phyton'
    }

    It "el error de runtime desconocido dice cuales si valen" {
        $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "rust": "1.0" } }')
        ($p.Errores -join ' ') | Should Match 'python'
        ($p.Errores -join ' ') | Should Match 'dotnet'
    }

    It "acepta las claves en mayusculas" {
        $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "PYTHON": "3.12" } }')
        $p.Errores.Count  | Should Be 0
        $p.Runtimes.Count | Should Be 1
    }

    It "recoge los paquetes de pip para Python" {
        $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "python": "3.12" }, "paquetes": { "python": ["django", "flask"] } }')
        ($p.Runtimes | Where-Object { $_.Clave -eq 'python' }).Paquetes | Should Be 'django,flask'
    }

    Context "varias versiones del mismo runtime" {

        # Con un solo valor por runtime, una maquina con dos JDK -trabajar en
        # proyectos con Javas distintos- no se podia reproducir desde su propio
        # manifiesto. Es el motivo de admitir listas.
        It "una lista instala las dos versiones" {
            $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "java": ["25", "21"] } }')
            $p.Errores.Count  | Should Be 0
            $p.Runtimes.Count | Should Be 2
            ($p.Runtimes.Version -join ',') | Should Be '21,25'
        }

        It "un valor suelto sigue funcionando igual" {
            $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "java": "21" } }')
            $p.Runtimes.Count   | Should Be 1
            $p.Runtimes[0].Java | Should BeNullOrEmpty
        }

        It "sigue instalando Java antes que Maven con varias lineas" {
            $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "maven": "3.9", "java": ["25", "21"] } }')
            ($p.Runtimes.Clave -join ',') | Should Be 'java,java,maven'
        }

        It "una lista vacia es un error, no un runtime sin version" {
            $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "java": [] } }')
            $p.Errores.Count | Should BeGreaterThan 0
        }

        # Instalarla dos veces no rompe nada, pero es una errata: mas vale
        # decirlo que ejecutar el mismo Setup dos veces sin explicacion.
        It "una version repetida se senala" {
            $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "java": ["21", "21"] } }')
            ($p.Errores -join ' ') | Should Match '21'
        }
    }

    Context "seccion java: a que JDK va el shell de Maven y Gradle" {

        It "ata Maven al JDK que se le diga" {
            $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "java": ["21", "25"], "maven": "3.9" }, "java": { "maven": "21" } }')
            $p.Errores.Count | Should Be 0
            ($p.Runtimes | Where-Object { $_.Clave -eq 'maven' }).Java | Should Be '21'
        }

        # Este es el error que justifica la validacion: sin ella, Restore-Env
        # instalaba Java y Maven y solo al final fallaba el -JavaVersion, con el
        # entorno ya a medias.
        It "rechaza atar Maven a un JDK que el manifiesto no instala" {
            $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "java": "25", "maven": "3.9" }, "java": { "maven": "21" } }')
            $p.Errores.Count | Should BeGreaterThan 0
            ($p.Errores -join ' ') | Should Match '21'
            ($p.Errores -join ' ') | Should Match 'instala: 25'
        }

        It "rechaza atar un runtime que no elige JDK" {
            $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "python": "3.12" }, "java": { "python": "21" } }')
            ($p.Errores -join ' ') | Should Match 'python'
        }

        It "rechaza un runtime desconocido en la seccion java" {
            $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "maven": "3.9" }, "java": { "grade": "21" } }')
            ($p.Errores -join ' ') | Should Match 'grade'
        }

        It "rechaza algo que no es una linea de JDK" {
            $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "java": "21", "maven": "3.9" }, "java": { "maven": "jdk-21" } }')
            ($p.Errores -join ' ') | Should Match 'jdk-21'
        }

        # Sin Java en el manifiesto la atadura puede ser legitima -un JDK ya
        # instalado a mano- asi que avisa en vez de parar.
        It "avisa, sin parar, si el manifiesto no instala Java" {
            $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "maven": "3.9" }, "java": { "maven": "21" } }')
            $p.Errores.Count | Should Be 0
            $p.Avisos.Count  | Should BeGreaterThan 0
            ($p.Runtimes | Where-Object { $_.Clave -eq 'maven' }).Java | Should Be '21'
        }

        It "avisa si se ata una herramienta que el manifiesto no instala" {
            $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "java": "21" }, "java": { "gradle": "21" } }')
            $p.Errores.Count | Should Be 0
            $p.Avisos.Count  | Should BeGreaterThan 0
        }
    }

    It "sin paquetes, deja el campo vacio" {
        $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "python": "3.12" } }')
        $p.Runtimes[0].Paquetes | Should BeNullOrEmpty
    }

    # Mejor negarse que instalar mal algo escrito para una version futura.
    It "rechaza un manifiesto de una version mas nueva que el kit" {
        $p = Read-DevEnvManifest -Config (Manifiesto '{ "version": 99, "runtimes": { "python": "3.12" } }')
        ($p.Errores -join ' ') | Should Match 'version 99'
    }

    It "avisa si no hay seccion runtimes" {
        $p = Read-DevEnvManifest -Config (Manifiesto '{ "version": 1 }')
        ($p.Errores -join ' ') | Should Match 'runtimes'
    }

    It "tolera un manifiesto nulo" {
        $p = Read-DevEnvManifest -Config $null
        $p.Errores.Count  | Should BeGreaterThan 0
        $p.Runtimes.Count | Should Be 0
    }

    It "todos los runtimes del catalogo se pueden pedir" {
        $claves = (Get-RuntimeCatalog).Clave
        $json = '{ "runtimes": { ' + (($claves | ForEach-Object { "`"$_`": `"latest`"" }) -join ', ') + ' } }'
        $p = Read-DevEnvManifest -Config (Manifiesto $json)
        $p.Errores.Count  | Should Be 0
        $p.Runtimes.Count | Should Be $claves.Count
    }
}

Describe "devenv.lock.json (Read-DevEnvLock)" {

    function Lock($json) { return (ConvertFrom-Json $json) }

    # El lock es al devenv.json lo que un package-lock.json al package.json: el
    # manifiesto dice "3.12", el lock dice "3.12.10".
    It "usa la version exacta cuando el Setup la admite" {
        $p = Read-DevEnvLock -Config (Lock '{ "runtimes": { "python": { "linea": "3.12", "exacta": "3.12.10", "fijable": true } } }')
        $p.Errores.Count      | Should Be 0
        $p.Runtimes[0].Version | Should Be '3.12.10'
        $p.Runtimes[0].Fijado  | Should Be $true
    }

    # Java tambien se fija desde que -JavaVersion acepta el release exacto.
    # Antes era el ejemplo del caso contrario: su parametro era un entero y no
    # habia forma de pedir 25.0.4.1+1.
    It "Java tambien usa la exacta" {
        $p = Read-DevEnvLock -Config (Lock '{ "runtimes": { "java": { "linea": "25", "exacta": "jdk-25.0.4.1+1" } } }')
        $p.Runtimes[0].Version | Should Be 'jdk-25.0.4.1+1'
        $p.Runtimes[0].Fijado  | Should Be $true
    }

    # La caida a la linea sigue en el codigo aunque hoy ningun runtime la
    # necesite: es la red de seguridad para el siguiente que se anada sin
    # soporte de version exacta. Se prueba con una entrada marcada a mano.
    It "sin exacta en el lock, se usa la linea" {
        $p = Read-DevEnvLock -Config (Lock '{ "runtimes": { "java": { "linea": "25" } } }')
        $p.Runtimes[0].Version | Should Be '25'
        $p.Runtimes[0].Fijado  | Should Be $false
    }

    It "conserva el checksum cuando el lock lo trae" {
        $p = Read-DevEnvLock -Config (Lock '{ "runtimes": { "python": { "linea": "3.12", "exacta": "3.12.10", "sha256": "abc123" } } }')
        $p.Runtimes[0].Sha256 | Should Be 'abc123'
    }

    It "respeta el orden del catalogo, no el del archivo" {
        $p = Read-DevEnvLock -Config (Lock '{ "runtimes": { "maven": { "linea": "3.9" }, "java": { "linea": "25" } } }')
        $p.Runtimes[0].Clave | Should Be 'java'
        $p.Runtimes[1].Clave | Should Be 'maven'
    }

    It "senala un runtime desconocido" {
        $p = Read-DevEnvLock -Config (Lock '{ "runtimes": { "rust": { "linea": "1.0" } } }')
        ($p.Errores -join ' ') | Should Match 'rust'
    }

    It "senala una entrada sin linea ni exacta" {
        $p = Read-DevEnvLock -Config (Lock '{ "runtimes": { "python": { "fijable": true } } }')
        ($p.Errores -join ' ') | Should Match 'ni linea ni exacta'
    }

    It "con solo exacta y sin linea, la usa igualmente" {
        $p = Read-DevEnvLock -Config (Lock '{ "runtimes": { "git": { "exacta": "2.55.0.5" } } }')
        $p.Errores.Count       | Should Be 0
        $p.Runtimes[0].Version | Should Be '2.55.0.5'
    }

    It "rechaza un lock de una version mas nueva que el kit" {
        $p = Read-DevEnvLock -Config (Lock '{ "version": 99, "runtimes": { "python": { "linea": "3.12" } } }')
        ($p.Errores -join ' ') | Should Match 'version 99'
    }

    It "tolera un lock nulo o sin runtimes" {
        (Read-DevEnvLock -Config $null).Errores.Count | Should BeGreaterThan 0
        (Read-DevEnvLock -Config (Lock '{ "version": 1 }')).Errores.Count | Should BeGreaterThan 0
    }

    # Un lock que solo sabe anotar un Java no reproduce la maquina que tiene el
    # 21 y el 25, que es justo lo que se queria fijar.
    It "fija varias lineas del mismo runtime" {
        $p = Read-DevEnvLock -Config (Lock '{ "runtimes": { "java": [ { "linea": "21", "exacta": "jdk-21.0.12.1+1", "fijable": true }, { "linea": "25", "exacta": "jdk-25.0.4.1+1", "fijable": true } ] } }')
        $p.Errores.Count  | Should Be 0
        $p.Runtimes.Count | Should Be 2
        ($p.Runtimes.Exacta -join ',') | Should Be 'jdk-21.0.12.1+1,jdk-25.0.4.1+1'
    }

    It "una entrada suelta sigue funcionando igual" {
        $p = Read-DevEnvLock -Config (Lock '{ "runtimes": { "java": { "linea": "25", "exacta": "jdk-25.0.4.1+1" } } }')
        $p.Runtimes.Count | Should Be 1
    }

    It "recoge a que JDK va el shell por defecto de Maven" {
        $p = Read-DevEnvLock -Config (Lock '{ "runtimes": { "maven": { "linea": "3.9", "java": "21" } } }')
        $p.Runtimes[0].Java | Should Be '21'
    }

    # Si esto se desalinea, el lock pediria versiones que el Setup rechaza.
    # Los nueve son fijables desde que Java, Angular, .NET y VS Code aceptan la
    # version exacta en su propio parametro; antes solo lo eran cinco.
    It "los nueve runtimes se pueden fijar" {
        foreach ($e in (Get-RuntimeCatalog)) {
            $e.Fijable | Should Be $true
        }
    }

    # Fijable sin parametro con que pedirlo seria mentira: Restore-Env no
    # tendria como pasar la version.
    It "todo runtime fijable tiene parametro de version" {
        foreach ($e in (Get-RuntimeCatalog | Where-Object { $_.Fijable })) {
            [string]::IsNullOrWhiteSpace($e.ParamVersion) | Should Be $false
        }
    }
}

Describe "Split-RuntimeVersionSpec" {

    # Los Setup aceptan la linea y la version exacta en el MISMO parametro, para
    # que un lock pueda fijarla sin necesitar otro distinto por runtime. Esto es
    # lo que distingue una forma de la otra, y no es igual para todos: la de
    # Java lleva prefijo y un '+', la de Angular es un semver.

    It "Java: reconoce el release exacto y saca su linea" {
        $r = Split-RuntimeVersionSpec -Clave java -Spec 'jdk-21.0.9+10'
        $r.Linea  | Should Be '21'
        $r.Exacta | Should Be 'jdk-21.0.9+10'
    }

    It "Java: la linea sola no fija nada" {
        $r = Split-RuntimeVersionSpec -Clave java -Spec '21'
        $r.Linea  | Should Be '21'
        $r.Exacta | Should BeNullOrEmpty
    }

    It "Java: acepta el release sin el prefijo jdk- y lo normaliza" {
        $r = Split-RuntimeVersionSpec -Clave java -Spec '21.0.9+10'
        $r.Linea  | Should Be '21'
        $r.Exacta | Should Be 'jdk-21.0.9+10'
    }

    It "Angular: 20.3.35 es exacta de la linea 20" {
        $r = Split-RuntimeVersionSpec -Clave angular -Spec '20.3.35'
        $r.Linea  | Should Be '20'
        $r.Exacta | Should Be '20.3.35'
    }

    It "Angular: 20 es solo la linea" {
        (Split-RuntimeVersionSpec -Clave angular -Spec '20').Exacta | Should BeNullOrEmpty
    }

    # .NET y VS Code tienen linea de DOS componentes, no uno: 10.0 y 1.135.
    It ".NET: 10.0.400 es exacta del canal 10.0" {
        $r = Split-RuntimeVersionSpec -Clave dotnet -Spec '10.0.400'
        $r.Linea  | Should Be '10.0'
        $r.Exacta | Should Be '10.0.400'
    }

    It ".NET: 10.0 es solo el canal" {
        $r = Split-RuntimeVersionSpec -Clave dotnet -Spec '10.0'
        $r.Linea  | Should Be '10.0'
        $r.Exacta | Should BeNullOrEmpty
    }

    It "VS Code: 1.135.0 es exacta de la linea 1.135" {
        $r = Split-RuntimeVersionSpec -Clave vscode -Spec '1.135.0'
        $r.Linea  | Should Be '1.135'
        $r.Exacta | Should Be '1.135.0'
    }

    It "vacio no pide nada" {
        $r = Split-RuntimeVersionSpec -Clave java -Spec ''
        $r.Linea  | Should BeNullOrEmpty
        $r.Exacta | Should BeNullOrEmpty
    }

    # La linea que devuelve tiene que servir para componer el nombre de carpeta
    # del catalogo; si no, se instalaria en un sitio y se buscaria en otro.
    It "la linea encaja con el patron de carpeta del catalogo" {
        $casos = @{ java = 'jdk-21.0.9+10'; angular = '20.3.35'; dotnet = '10.0.400'; vscode = '1.135.0' }
        foreach ($clave in $casos.Keys) {
            $e = @(Get-RuntimeCatalog | Where-Object { $_.Clave -eq $clave })[0]
            $linea = (Split-RuntimeVersionSpec -Clave $clave -Spec $casos[$clave]).Linea
            $carpeta = switch ($clave) {
                'java'    { "jdk-$linea" }
                'angular' { "angular-v$linea" }
                default   { "$clave-$linea" }
            }
            $carpeta | Should Match $e.Patron
        }
    }
}

Describe "Expand-BundledRuntime" {

    # Los archivos de los runtimes no vienen todos igual, y equivocarse deja la
    # instalacion un nivel mas abajo o mas arriba de donde toca:
    #   con envoltorio  el zip trae dentro una carpeta (node-vX, apache-maven-X)
    #   plano           el zip vuelca su contenido directo (dotnet, vscode)
    # El tercer modo, el autoextraible de PortableGit, no se puede probar con un
    # zip sintetico porque necesita el .exe real.

    function NuevoTemp {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ("exp-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        return $d
    }

    function ZipDe($origen, $destino) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::CreateFromDirectory($origen, $destino)
    }

    It "con envoltorio, sube el contenido un nivel" {
        $t = NuevoTemp
        try {
            # Un zip que dentro trae "apache-maven-3.9.16\bin\mvn.cmd"
            $src = Join-Path $t "src"
            New-Item -ItemType Directory -Path (Join-Path $src "apache-maven-3.9.16\bin") -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $src "apache-maven-3.9.16\bin\mvn.cmd") -Value 'x'
            $zip = Join-Path $t "a.zip"
            ZipDe $src $zip

            $destino = Join-Path $t "maven-3.9"
            $e = [PSCustomObject]@{ Envoltorio = $true; Sfx = $false }
            Expand-BundledRuntime -Archivo $zip -Destino $destino -Entrada $e | Should Be $true

            # El bin queda directamente bajo maven-3.9, no bajo otra carpeta.
            Test-Path (Join-Path $destino "bin\mvn.cmd") | Should Be $true
        }
        finally { Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "plano, deja el contenido tal cual" {
        $t = NuevoTemp
        try {
            $src = Join-Path $t "src"
            New-Item -ItemType Directory -Path $src -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $src "dotnet.exe") -Value 'x'
            $zip = Join-Path $t "b.zip"
            ZipDe $src $zip

            $destino = Join-Path $t "dotnet-10.0"
            $e = [PSCustomObject]@{ Envoltorio = $false; Sfx = $false }
            Expand-BundledRuntime -Archivo $zip -Destino $destino -Entrada $e | Should Be $true

            Test-Path (Join-Path $destino "dotnet.exe") | Should Be $true
        }
        finally { Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # Si el zip con envoltorio trae MAS de una carpeta arriba no hay envoltorio
    # que quitar, y hay que volcarlo todo en vez de perder contenido.
    It "con envoltorio pero varias carpetas arriba, no pierde nada" {
        $t = NuevoTemp
        try {
            $src = Join-Path $t "src"
            New-Item -ItemType Directory -Path (Join-Path $src "uno") -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $src "dos") -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $src "uno\a.txt") -Value 'a'
            Set-Content -LiteralPath (Join-Path $src "dos\b.txt") -Value 'b'
            $zip = Join-Path $t "c.zip"
            ZipDe $src $zip

            $destino = Join-Path $t "x"
            $e = [PSCustomObject]@{ Envoltorio = $true; Sfx = $false }
            Expand-BundledRuntime -Archivo $zip -Destino $destino -Entrada $e | Should Be $true

            Test-Path (Join-Path $destino "uno\a.txt") | Should Be $true
            Test-Path (Join-Path $destino "dos\b.txt") | Should Be $true
        }
        finally { Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe "Firma Authenticode" {

    # Es lo unico del kit que da AUTENTICIDAD. Los checksums dan integridad
    # pero salen del mismo servidor que el archivo -y con un espejo interno,
    # del mismo espejo-, asi que no dicen de quien viene.
    #
    # Y NUNCA bloquea. No es una postura: el MSI de 7-Zip que el propio kit
    # descarga no esta firmado, asi que bloquear lo no firmado romperia el kit
    # consigo mismo.

    Context "Get-FileSignerInfo" {

        It "un .zip no es firmable: no se dice que le falte firma" {
            $z = Join-Path ([System.IO.Path]::GetTempPath()) ("f-" + [Guid]::NewGuid().ToString('N') + ".zip")
            Set-Content -LiteralPath $z -Value 'x'
            try {
                (Get-FileSignerInfo -FilePath $z).Firmable | Should Be $false
            }
            finally { Remove-Item $z -Force -ErrorAction SilentlyContinue }
        }

        It "un .exe si es firmable, aunque no este firmado" {
            $e = Join-Path ([System.IO.Path]::GetTempPath()) ("f-" + [Guid]::NewGuid().ToString('N') + ".exe")
            Set-Content -LiteralPath $e -Value 'no soy un PE'
            try {
                $r = Get-FileSignerInfo -FilePath $e
                $r.Firmable | Should Be $true
                $r.Firmante | Should BeNullOrEmpty
            }
            finally { Remove-Item $e -Force -ErrorAction SilentlyContinue }
        }

        It "lee el firmante de un binario firmado de Windows" {
            # powershell.exe lo firma Microsoft y esta en cualquier equipo.
            $r = Get-FileSignerInfo -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
            $r.Firmable | Should Be $true
            $r.Estado   | Should Be 'Valid'
            $r.Firmante | Should Match 'Microsoft'
        }

        It "un archivo que no existe no revienta" {
            (Get-FileSignerInfo -FilePath 'C:\no-existe-esto.exe').Firmable | Should Be $false
        }

        It "reconoce como firmables los formatos que llevan Authenticode" {
            foreach ($ext in @('.exe', '.msi', '.dll', '.ps1', '.cab')) {
                $f = Join-Path ([System.IO.Path]::GetTempPath()) ("f-" + [Guid]::NewGuid().ToString('N') + $ext)
                Set-Content -LiteralPath $f -Value 'x'
                try { (Get-FileSignerInfo -FilePath $f).Firmable | Should Be $true }
                finally { Remove-Item $f -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    Context "Write-SignerReport" {

        function Texto($ruta, $esperado) {
            if ($esperado) { return ((Write-SignerReport -FilePath $ruta -Esperado $esperado 6>&1) | Out-String) }
            return ((Write-SignerReport -FilePath $ruta 6>&1) | Out-String)
        }

        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

        It "dice quien firma" {
            (Texto $psExe $null) | Should Match 'Firmado por'
            (Texto $psExe $null) | Should Match 'Microsoft'
        }

        It "avisa si firma alguien distinto del esperado" {
            $t = Texto $psExe 'Otra Empresa SL'
            $t | Should Match 'se esperaba'
        }

        It "no avisa si firma quien se esperaba" {
            (Texto $psExe 'Microsoft') | Should Not Match 'se esperaba'
        }

        It "de un zip no dice nada: no hay nada que comprobar" {
            $z = Join-Path ([System.IO.Path]::GetTempPath()) ("f-" + [Guid]::NewGuid().ToString('N') + ".zip")
            Set-Content -LiteralPath $z -Value 'x'
            try { (Texto $z $null).Trim() | Should Be '' }
            finally { Remove-Item $z -Force -ErrorAction SilentlyContinue }
        }

        # Lo importante: sin firma se informa, no se alarma ni se bloquea. Un
        # archivo que ni siquiera es un ejecutable devuelve UnknownError, que NO
        # es lo mismo que una firma invalida; confundirlos alarmaria de mas.
        It "sin firma reconocible lo dice sin tratarlo como error" {
            $e = Join-Path ([System.IO.Path]::GetTempPath()) ("f-" + [Guid]::NewGuid().ToString('N') + ".exe")
            Set-Content -LiteralPath $e -Value 'no soy un PE'
            try {
                $t = Texto $e $null
                $t | Should Match 'Sin firma'
                $t | Should Not Match 'ERROR'
                $t | Should Not Match 'NO valida'
            }
            finally { Remove-Item $e -Force -ErrorAction SilentlyContinue }
        }

        # El caso mas importante y el que se escapaba: firmado por alguien en
        # quien el equipo NO confia. Windows devuelve UnknownError igual que con
        # un archivo que no es un ejecutable, y agrupar los dos hacia que un
        # binario firmado por un desconocido se anunciara como "sin firma".
        # Lo que los distingue es si hay certificado.
        It "un editor desconocido se avisa, no se confunde con no tener firma" {
            $cert = New-SelfSignedCertificate -Type CodeSigningCert `
                        -Subject 'CN=Editor Desconocido De Prueba' `
                        -CertStoreLocation 'Cert:\CurrentUser\My' -NotAfter (Get-Date).AddDays(1)
            $f = Join-Path ([System.IO.Path]::GetTempPath()) ("f-" + [Guid]::NewGuid().ToString('N') + ".ps1")
            try {
                Set-Content -LiteralPath $f -Value '"hola"' -Encoding ASCII
                Set-AuthenticodeSignature -LiteralPath $f -Certificate $cert | Out-Null

                $info = Get-FileSignerInfo -FilePath $f
                $info.Firmante | Should Match 'Editor Desconocido De Prueba'

                $t = Texto $f $null
                $t | Should Match 'NO confia'
                $t | Should Match 'Editor Desconocido De Prueba'
                # Lo que NUNCA debe decir de un archivo que SI esta firmado:
                $t | Should Not Match 'Sin firma'
            }
            finally {
                Remove-Item $f -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($cert.Thumbprint)" -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe "Cobertura del catalogo" {

    # ESTA es la prueba que faltaba. El catalogo existe desde hace tiempo, pero
    # nada obligaba a que los comandos lo siguieran: se anadieron seis runtimes
    # y Export-Env e Import-Env se quedaron en tres, asi que el bundle
    # "portable" ignoraba en silencio Git, Maven, Gradle, .NET y VS Code.
    # Nadie se entero hasta que se comprobo a mano meses despues.
    #
    # A partir de aqui, anadir un runtime al catalogo y olvidarse de un comando
    # pone la suite en rojo el mismo dia.

    $scripts  = Join-Path (Split-Path -Parent $PSScriptRoot) "scripts"
    $catalogo = Get-RuntimeCatalog

    # Los comandos que deben admitir -Runtime con TODOS los del catalogo.
    $conValidateSet = @('Doctor-Env', 'Update-Env', 'Uninstall-Env', 'Use-Env', 'Export-Env', 'Import-Env')

    foreach ($nombre in $conValidateSet) {
        It "$nombre admite los $($catalogo.Count) runtimes del catalogo" {
            $txt = Get-Content (Join-Path $scripts "$nombre.ps1") -Raw

            # Doctor no tiene -Runtime; se comprueba que nombre cada carpeta.
            if ($nombre -eq 'Doctor-Env') {
                foreach ($e in $catalogo) {
                    $txt | Should Match ([regex]::Escape($e.Carpeta))
                }
                return
            }

            $m = [regex]::Match($txt, "ValidateSet\(([^)]*)\)")
            $m.Success | Should Be $true
            foreach ($e in $catalogo) {
                $m.Groups[1].Value | Should Match ([regex]::Escape("'$($e.Carpeta)'"))
            }
        }
    }

    It "todo runtime empaquetable sabe decir su archivo de descarga" {
        foreach ($e in ($catalogo | Where-Object { $_.Bundle })) {
            # No se llama a la red: solo se comprueba que Get-BundleArchiveInfo
            # contempla la clave, que es lo que se olvida al anadir un runtime.
            $cuerpo = (Get-Command Get-BundleArchiveInfo).Definition
            $cuerpo | Should Match ([regex]::Escape("'$($e.Clave)'"))
        }
    }

    It "todo runtime empaquetable sabe regenerar su shell" {
        foreach ($e in ($catalogo | Where-Object { $_.Bundle })) {
            (Get-Command Write-RuntimeShell).Definition | Should Match ([regex]::Escape("'$($e.Clave)'"))
        }
    }

    # Sin estos metadatos, Expand-BundledRuntime no sabe si el zip trae carpeta
    # dentro y dejaria el runtime un nivel mas abajo de donde toca.
    It "todo runtime empaquetable declara como viene empaquetado" {
        foreach ($e in ($catalogo | Where-Object { $_.Bundle })) {
            ($null -ne $e.Envoltorio) | Should Be $true
            ($null -ne $e.Sfx)        | Should Be $true
        }
    }

    It "los que NO se empaquetan tienen su tratamiento propio en Export-Env" {
        $txt = Get-Content (Join-Path $scripts "Export-Env.ps1") -Raw
        foreach ($e in ($catalogo | Where-Object { -not $_.Bundle })) {
            $txt | Should Match "Get-$($e.Carpeta)Entries"
        }
    }

    It "Restore-Env no nombra runtimes: los saca del catalogo" {
        $txt = Get-Content (Join-Path $scripts "Restore-Env.ps1") -Raw
        $txt | Should Match 'Get-RuntimeCatalog'
    }

    # El menu construye sus opciones de instalacion recorriendo el catalogo. Si
    # alguien las escribiera a mano, un runtime nuevo no apareceria y nadie se
    # enteraria hasta echarlo en falta.
    It "el menu saca los runtimes del catalogo" {
        $txt = Get-Content (Join-Path $scripts "Menu.ps1") -Raw
        $txt | Should Match 'Get-RuntimeCatalog'
    }

    # Cada opcion del menu llama a un .bat de la raiz. Uno mal escrito solo se
    # notaria al pulsarlo.
    It "todos los .bat que invoca el menu existen" {
        $raiz = Split-Path -Parent $PSScriptRoot
        $txt = Get-Content (Join-Path $scripts "Menu.ps1") -Raw
        $bats = @([regex]::Matches($txt, "Bat\s*=\s*'([^']+\.bat)'") | ForEach-Object { $_.Groups[1].Value })
        $bats.Count | Should BeGreaterThan 5
        foreach ($b in ($bats | Sort-Object -Unique)) {
            Test-Path (Join-Path $raiz $b) | Should Be $true
        }
    }

    # Los Setup y los Start se componen a partir del catalogo, asi que se
    # comprueban aparte de los literales.
    It "existen el Setup y el Start de cada runtime del catalogo" {
        $raiz = Split-Path -Parent $PSScriptRoot
        foreach ($e in $catalogo) {
            Test-Path (Join-Path $raiz "Setup-$($e.Carpeta)Env.bat") | Should Be $true
            Test-Path (Join-Path $raiz "Start-$($e.Carpeta)Env.bat") | Should Be $true
        }
    }
}

Describe "Resolve-RuntimeFromPath" {

    # Traduce "esta carpeta esta tapada en el PATH" a "esto se arregla con
    # Use-Env -Runtime Java -Version 25", que es lo que permite a Doctor
    # ofrecer la reparacion en vez de limitarse a contar el problema.

    It "reconoce el bin de un JDK del kit" {
        $r = Resolve-RuntimeFromPath -Path (Join-Path $WorkspaceRoot 'Java\jdk-25\bin')
        $r.Runtime | Should Be 'Java'
        $r.Version | Should Be '25'
    }

    It "reconoce la carpeta de un Python del kit" {
        $r = Resolve-RuntimeFromPath -Path (Join-Path $WorkspaceRoot 'Python\python-3.12')
        $r.Runtime | Should Be 'Python'
        $r.Version | Should Be '3.12'
    }

    It "reconoce una subcarpeta profunda" {
        $r = Resolve-RuntimeFromPath -Path (Join-Path $WorkspaceRoot 'Python\python-3.12\Scripts')
        $r.Version | Should Be '3.12'
    }

    It "el nombre que devuelve sirve tal cual para Use-Env" {
        $valida = @('Angular','Python','Java','Node','Git','Maven','Gradle','Dotnet','VSCode')
        foreach ($e in (Get-RuntimeCatalog)) {
            $valida -contains $e.Carpeta | Should Be $true
        }
    }

    It "devuelve nulo para algo ajeno al kit" {
        Resolve-RuntimeFromPath -Path 'C:\Program Files\Java\jdk1.8.0_202\bin' | Should BeNullOrEmpty
        Resolve-RuntimeFromPath -Path 'C:\Program Files\nodejs' | Should BeNullOrEmpty
    }

    # Una carpeta con nombre libre dentro de la raiz de un runtime no es del
    # kit: solo cuentan las que siguen su patron.
    It "devuelve nulo para una carpeta que no sigue el patron" {
        Resolve-RuntimeFromPath -Path (Join-Path $WorkspaceRoot 'Java\mi-jdk-a-mano\bin') | Should BeNullOrEmpty
    }

    It "tolera vacio" {
        Resolve-RuntimeFromPath -Path '' | Should BeNullOrEmpty
    }
}

Describe "Get-RuntimeCatalog" {

    # El catalogo es el unico sitio que sabe como se instala cada runtime. Si
    # una entrada esta mal, Restore-Env falla en tiempo de ejecucion y no al
    # leerse, asi que conviene comprobar la forma aqui.
    $catalogo = Get-RuntimeCatalog

    It "no repite claves" {
        ($catalogo.Clave | Sort-Object -Unique).Count | Should Be $catalogo.Count
    }

    It "cada entrada apunta a un script que existe" {
        $scripts = Join-Path (Split-Path -Parent $PSScriptRoot) "scripts"
        foreach ($e in $catalogo) {
            Test-Path (Join-Path $scripts $e.Script) | Should Be $true
        }
    }

    It "cada patron de carpeta captura un grupo" {
        foreach ($e in $catalogo) {
            $e.Patron | Should Match '\('
        }
    }

    It "las claves van en minuscula, que es como se escriben en el JSON" {
        foreach ($e in $catalogo) {
            $e.Clave | Should Be $e.Clave.ToLowerInvariant()
        }
    }

    # Uninstall-Env -Everything compone las carpetas a barrer con
    # Join-Path $WorkspaceRoot $e.Carpeta. Una Carpeta vacia daria la RAIZ DEL
    # WORKSPACE, o sea la carpeta que contiene el kit y todos los proyectos del
    # usuario, y esa se borraria por "estar vacia". Es la propiedad mas critica
    # del catalogo entero.
    It "ninguna Carpeta esta vacia: compondrian la raiz del workspace" {
        foreach ($e in $catalogo) {
            [string]::IsNullOrWhiteSpace($e.Carpeta) | Should Be $false
        }
    }

    It "ninguna Carpeta escapa hacia arriba" {
        foreach ($e in $catalogo) {
            $e.Carpeta | Should Not Match '\.\.'
            $e.Carpeta | Should Not Match '^[A-Za-z]:'
            $e.Carpeta | Should Not Match '^[\\/]'
        }
    }

    It "no hay dos runtimes compartiendo carpeta" {
        ($catalogo.Carpeta | Sort-Object -Unique).Count | Should Be $catalogo.Count
    }

    # Sin firmante esperado, Doctor solo puede DECIR quien firma; con el, puede
    # detectar una suplantacion. Declarar uno sin el otro deja la comprobacion a
    # medias sin que se note.
    It "ExeFirma y FirmanteEsperado van juntos o no van" {
        foreach ($e in $catalogo) {
            if ($e.ExeFirma) {
                [string]::IsNullOrWhiteSpace($e.FirmanteEsperado) | Should Be $false
            }
            else {
                [string]::IsNullOrWhiteSpace($e.FirmanteEsperado) | Should Be $true
            }
        }
    }

    It "el ejecutable a firmar es una ruta relativa" {
        foreach ($e in ($catalogo | Where-Object { $_.ExeFirma })) {
            $e.ExeFirma | Should Not Match '^[A-Za-z]:'
            $e.ExeFirma | Should Not Match '\.\.'
        }
    }
}

Describe "Version de un JDK" {

    Context "Get-JavaMajor" {

        # Sin normalizar el esquema antiguo, comparar versiones daria que un
        # Java 8 ("1.8.0_202") es MAS NUEVO que un Java 25, y el aviso de
        # JAVA_HOME obsoleto no saltaria nunca. Es el caso real que lo motivo.
        It "entiende el esquema antiguo: 1.8.0_202 es Java 8" {
            Get-JavaMajor -Version '1.8.0_202' | Should Be 8
        }

        It "entiende el esquema moderno" {
            Get-JavaMajor -Version '25.0.4.1' | Should Be 25
            Get-JavaMajor -Version '24.0.2'   | Should Be 24
        }

        It "un Java 8 es MENOR que un Java 25, que es lo que hay que detectar" {
            (Get-JavaMajor -Version '1.8.0_202') -lt (Get-JavaMajor -Version '25.0.4.1') | Should Be $true
        }

        It "1.7.0 es Java 7 y no Java 1" {
            Get-JavaMajor -Version '1.7.0_80' | Should Be 7
        }

        It "tolera vacio, nulo y basura" {
            Get-JavaMajor -Version ''      | Should BeNullOrEmpty
            Get-JavaMajor -Version $null   | Should BeNullOrEmpty
            Get-JavaMajor -Version 'nada'  | Should BeNullOrEmpty
        }
    }

    Context "Get-JdkVersionAt" {

        # Se lee del archivo "release" que todo JDK trae en su raiz: es
        # instantaneo y funciona aunque ese JDK este roto.
        It "lee la version del archivo release" {
            $d = Join-Path ([System.IO.Path]::GetTempPath()) ("jdk-" + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            try {
                Set-Content -LiteralPath (Join-Path $d "release") -Value @(
                    'IMPLEMENTOR="Eclipse Adoptium"'
                    'JAVA_VERSION="25.0.4.1"'
                    'OS_ARCH="x86_64"'
                )
                Get-JdkVersionAt -JavaHome $d | Should Be '25.0.4.1'
            }
            finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
        }

        It "devuelve nulo si la carpeta no existe" {
            Get-JdkVersionAt -JavaHome 'C:\no-existe-este-jdk' | Should BeNullOrEmpty
        }

        It "tolera vacio y nulo" {
            Get-JdkVersionAt -JavaHome ''    | Should BeNullOrEmpty
            Get-JdkVersionAt -JavaHome $null | Should BeNullOrEmpty
        }

        It "devuelve nulo si hay carpeta pero no es un JDK" {
            $d = Join-Path ([System.IO.Path]::GetTempPath()) ("nojdk-" + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            try { Get-JdkVersionAt -JavaHome $d | Should BeNullOrEmpty }
            finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
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

Describe "Un shell de Maven/Gradle por cada JDK" {

    # Quien trabaja a diario en proyectos que piden Javas distintos no puede
    # reejecutar el Setup cada vez que cambia de proyecto. Estas pruebas fijan
    # que exista un shell por JDK y que cada uno apunte al SUYO: si todos
    # acabaran en el mismo JAVA_HOME el resultado seria una compilacion con el
    # Java equivocado, que es un fallo silencioso.

    $raizReal = $WorkspaceRoot
    $falso    = Join-Path $env:TEMP ("kit-multijdk-" + [Guid]::NewGuid().ToString('N'))

    function New-JdkFalso {
        param([string]$Linea)
        $bin = Join-Path (Join-Path (Join-Path $falso "Java") "jdk-$Linea") "bin"
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $bin "java.exe") -Value "" -Encoding ASCII
    }

    function New-HerramientaFalsa {
        param([string]$Nombre)
        $p = Join-Path $falso $Nombre
        New-Item -ItemType Directory -Path (Join-Path $p "bin") -Force | Out-Null
        return $p
    }

    BeforeEach {
        if (Test-Path -LiteralPath $falso) { Remove-Item -LiteralPath $falso -Recurse -Force }
        New-Item -ItemType Directory -Path $falso -Force | Out-Null
        $script:WorkspaceRoot = $falso
    }

    AfterEach {
        $script:WorkspaceRoot = $raizReal
        Remove-Item -LiteralPath $falso -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context "Get-KitJdkLines" {

        # Ordenar como texto pondria "21" antes que "9". Con Java 8 y Java 21
        # instalados eso haria que "el mas alto" fuera el 8.
        It "ordena por numero y no como texto" {
            New-JdkFalso 21; New-JdkFalso 8; New-JdkFalso 25
            (Get-KitJdkLines) -join ',' | Should Be '8,21,25'
        }

        It "no cuenta una carpeta sin java.exe" {
            New-JdkFalso 21
            New-Item -ItemType Directory -Path (Join-Path $falso "Java\jdk-99") -Force | Out-Null
            (Get-KitJdkLines) -join ',' | Should Be '21'
        }

        It "sin carpeta Java devuelve vacio" {
            (Get-KitJdkLines).Count | Should Be 0
        }
    }

    Context "Resolve-KitJdk" {

        It "devuelve el JDK que se le pide" {
            New-JdkFalso 21; New-JdkFalso 25
            Resolve-KitJdk -Linea '21' | Should Be (Join-Path $falso "Java\jdk-21")
        }

        It "devuelve nulo si esa linea no esta instalada" {
            New-JdkFalso 25
            Resolve-KitJdk -Linea '21' | Should BeNullOrEmpty
        }

        It "sin linea se queda con el mas alto, como antes" {
            New-JdkFalso 21; New-JdkFalso 25
            Resolve-KitJdk | Should Be (Join-Path $falso "Java\jdk-25")
        }
    }

    Context "Write-BuildToolShell -SufijoJdk" {

        It "nombra el archivo con el JDK al que ata" {
            $mvn = New-HerramientaFalsa "maven-3.9"
            $f = Write-BuildToolShell -Tool Maven -ToolPath $mvn -Version '3.9.11' `
                                      -JavaHome 'C:\jdk-21' -SufijoJdk '21'
            Split-Path -Leaf $f | Should Be 'mvn39-java21-shell.bat'
        }

        It "sin sufijo mantiene el nombre de siempre" {
            $mvn = New-HerramientaFalsa "maven-3.9"
            $f = Write-BuildToolShell -Tool Maven -ToolPath $mvn -Version '3.9.11' -JavaHome 'C:\jdk-21'
            Split-Path -Leaf $f | Should Be 'mvn39-shell.bat'
        }
    }

    Context "Write-BuildToolShellsPorJdk" {

        It "escribe uno por JDK y cada uno apunta al suyo" {
            New-JdkFalso 21; New-JdkFalso 25
            $g = New-HerramientaFalsa "gradle-9.7"

            $hechos = (Write-BuildToolShellsPorJdk -Tool Gradle -ToolPath $g -Version '9.7.1').Escritos
            $hechos.Count | Should Be 2

            foreach ($h in $hechos) {
                $null = (Split-Path -Leaf $h) -match '-java(\d+)-shell\.bat$'
                $linea = $Matches[1]
                $jh = ([regex]::Match((Get-Content -LiteralPath $h -Raw), 'set "JAVA_HOME=([^"]+)"')).Groups[1].Value
                Split-Path -Leaf $jh | Should Be "jdk-$linea"
            }
        }

        # Con un solo JDK el shell normal ya apunta ahi: un segundo archivo
        # identico solo haria dudar de cual abrir.
        It "con un solo JDK no escribe ninguno" {
            New-JdkFalso 25
            $g = New-HerramientaFalsa "gradle-9.7"
            (Write-BuildToolShellsPorJdk -Tool Gradle -ToolPath $g -Version '9.7.1').Escritos.Count | Should Be 0
        }

        # Un shell que exporta un JAVA_HOME inexistente hace fallar la compilacion
        # con un error de Java que no menciona la desinstalacion.
        It "borra el shell de un JDK que ya no esta" {
            New-JdkFalso 21; New-JdkFalso 25
            $g = New-HerramientaFalsa "gradle-9.7"
            Write-BuildToolShellsPorJdk -Tool Gradle -ToolPath $g -Version '9.7.1' | Out-Null
            Test-Path (Join-Path $g "gradle97-java21-shell.bat") | Should Be $true

            Remove-Item -LiteralPath (Join-Path $falso "Java\jdk-21") -Recurse -Force
            Write-BuildToolShellsPorJdk -Tool Gradle -ToolPath $g -Version '9.7.1' | Out-Null

            Test-Path (Join-Path $g "gradle97-java21-shell.bat") | Should Be $false
            Test-Path (Join-Path $g "gradle97-java25-shell.bat") | Should Be $false
        }

        It "no toca el shell por defecto al limpiar" {
            New-JdkFalso 25
            $g = New-HerramientaFalsa "gradle-9.7"
            Write-BuildToolShell -Tool Gradle -ToolPath $g -Version '9.7.1' -JavaHome (Join-Path $falso "Java\jdk-25") | Out-Null
            Write-BuildToolShellsPorJdk -Tool Gradle -ToolPath $g -Version '9.7.1' | Out-Null
            Test-Path (Join-Path $g "gradle97-shell.bat") | Should Be $true
        }
    }

    Context "Sync-BuildToolShells" {

        # Se monta un Gradle creible: Sync lee la version del jar, no de ejecutar
        # nada, asi que basta con el nombre del archivo.
        function New-GradleFalso {
            $g = Join-Path $falso "Gradle\gradle-9.7"
            New-Item -ItemType Directory -Path (Join-Path $g "bin") -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $g "lib") -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $g "bin\gradle.bat") -Value "" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $g "lib\gradle-launcher-9.7.1.jar") -Value "" -Encoding ASCII
            return $g
        }

        # Instalar un JDK despues de Gradle tiene que dar shell para el nuevo sin
        # reejecutar Setup-GradleEnv: es justo el caso de trabajar en proyectos
        # con Javas distintos.
        It "al aparecer un segundo JDK escribe los shells sin tocar el Setup" {
            New-JdkFalso 25
            $g = New-GradleFalso
            Write-BuildToolShell -Tool Gradle -ToolPath $g -Version '9.7.1' -JavaHome (Join-Path $falso "Java\jdk-25") | Out-Null

            New-JdkFalso 21
            $r = @(Sync-BuildToolShells)

            Test-Path (Join-Path $g "gradle97-java21-shell.bat") | Should Be $true
            Test-Path (Join-Path $g "gradle97-java25-shell.bat") | Should Be $true
            ($r -join ' ') | Should Match '2 shells'
        }

        # Sin esto, desinstalar el JDK al que apuntaba el shell por defecto deja
        # Gradle roto hasta que alguien reejecute su Setup, y el error que da
        # Java no menciona la desinstalacion.
        It "reapunta el shell por defecto si su JDK desaparecio" {
            New-JdkFalso 21; New-JdkFalso 25
            $g = New-GradleFalso
            Write-BuildToolShell -Tool Gradle -ToolPath $g -Version '9.7.1' -JavaHome (Join-Path $falso "Java\jdk-21") | Out-Null

            Remove-Item -LiteralPath (Join-Path $falso "Java\jdk-21") -Recurse -Force
            $r = @(Sync-BuildToolShells)

            $jh = Get-ShellJavaHome -ShellBat (Join-Path $g "gradle97-shell.bat")
            Split-Path -Leaf $jh | Should Be 'jdk-25'
            ($r -join ' ') | Should Match 'ahora a jdk-25'
        }

        It "no toca el shell por defecto si su JDK sigue ahi" {
            New-JdkFalso 21; New-JdkFalso 25
            $g = New-GradleFalso
            Write-BuildToolShell -Tool Gradle -ToolPath $g -Version '9.7.1' -JavaHome (Join-Path $falso "Java\jdk-21") | Out-Null

            Sync-BuildToolShells | Out-Null

            $jh = Get-ShellJavaHome -ShellBat (Join-Path $g "gradle97-shell.bat")
            Split-Path -Leaf $jh | Should Be 'jdk-21'
        }

        It "sin Maven ni Gradle instalados no dice nada" {
            New-JdkFalso 21; New-JdkFalso 25
            (Sync-BuildToolShells).Count | Should Be 0
        }
    }
}
