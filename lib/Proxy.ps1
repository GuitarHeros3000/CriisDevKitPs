#Requires -Version 5.1
<#
    Proxy corporativo y espejo interno de fuentes

    Parte de lib\Common.ps1, que es quien carga este archivo. No se toma
    por separado: los scripts siguen haciendo un unico dot-source de
    Common.ps1 y no se enteran de esta division.
#>

# --------------------------------------------------------------------------
# Descargas
# --------------------------------------------------------------------------

function Test-ProxyUsable {
    <#
        Comprueba que la URL del proxy sea una URI valida ANTES de pasarsela a
        Invoke-WebRequest. Dos motivos, y el segundo no es nada evidente:

        1. Una cuenta de dominio escrita tal cual ("dominio\usuario") hace la URI
           invalida, y entonces el proxy NO FUNCIONA: Invoke-WebRequest ni
           siquiera consigue enlazar el parametro. Hay que codificar la barra
           invertida como %5C. Es el caso normal en una empresa, y el error de
           .NET no dice nada de esto.

        2. Al fallar ese enlace, PowerShell escribe el error CRUDO en el
           transcript -con la clave en claro- antes de que este codigo pueda
           enmascararla. Validando aqui, ese error no llega a producirse.
    #>
    param([Parameter(Mandatory=$true)][string]$Proxy)

    $valida = $false
    try {
        $u = [Uri]$Proxy
        $valida = ($null -ne $u -and -not [string]::IsNullOrWhiteSpace($u.Host))
    }
    catch {
        $valida = $false
    }
    if ($valida) { return $true }

    Write-Log "La URL del proxy no es valida: $(Format-ProxyForDisplay $Proxy)" "ERROR"

    # La pista tiene que apuntar a la causa REAL. Una primera version soltaba
    # siempre el consejo del %5C, que con un proxy al que solo le falta el
    # esquema manda a quien lo lea a mirar justo donde no esta el problema.
    if ($Proxy -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://') {
        Write-Log "  Le falta el esquema. .NET no admite un proxy sin http:// delante:" "WARN"
        Write-Log '    $env:HTTPS_PROXY = "http://proxy.empresa:8080"' "WARN"
    }
    elseif ($Proxy -match '\\') {
        Write-Log "  Lleva una barra invertida. Si tu usuario es de dominio, codificala como %5C:" "WARN"
        Write-Log '    $env:HTTPS_PROXY = "http://dominio%5Cusuario:clave@proxy.empresa:8080"' "WARN"
    }
    else {
        Write-Log "  Revisa que tenga la forma  http://[usuario:clave@]servidor:puerto" "WARN"
    }

    Write-Log "  Se sigue SIN proxy, asi que las descargas fallaran si hace falta pasar por el." "WARN"
    return $false
}

function Resolve-DownloadProxy {
    <#
        Devuelve la URL del proxy a usar, o $null si se sale directo a internet.
        Se mira primero las variables de entorno porque son las que el usuario
        ya suele tener puestas para npm, pip o curl.
    #>
    param([Parameter(Mandatory=$true)][Uri]$Uri)

    $explicit = if ($Uri.Scheme -eq 'https') { $env:HTTPS_PROXY } else { $env:HTTP_PROXY }
    if ([string]::IsNullOrWhiteSpace($explicit)) { $explicit = $env:ALL_PROXY }
    if (-not [string]::IsNullOrWhiteSpace($explicit)) {
        if (Test-ProxyUsable -Proxy $explicit) { return $explicit }
        return $null
    }

    # Proxy del sistema: el que IT configura por WPAD/PAC o en Opciones de Internet.
    # GetProxy() devuelve la misma URL de entrada cuando no hay proxy para ese destino.
    try {
        $system = [System.Net.WebRequest]::GetSystemWebProxy()
        $target = $system.GetProxy($Uri)
        if ($target -and $target.AbsoluteUri -ne $Uri.AbsoluteUri) {
            return $target.AbsoluteUri
        }
    }
    catch {
        # Sin proxy de sistema detectable: salida directa.
    }

    return $null
}

function Resolve-SourceUrl {
    <#
    .SYNOPSIS
        Reescribe una URL segun las reglas de espejo configuradas.
    .DESCRIPTION
        En muchas empresas los dominios publicos (nodejs.org, pypi.org...) estan
        bloqueados pero hay un espejo interno -Nexus, Artifactory- que sirve lo
        mismo. Sin esto, el kit no puede hacer nada en esa red; con esto, se le
        dice de donde sacar cada cosa y todo lo demas sigue igual.

        Las reglas sustituyen el PRINCIPIO de la URL, que es como funcionan los
        repositorios proxy de verdad: cuelgan el arbol entero del original bajo
        una ruta suya.

        Se aplica la regla mas ESPECIFICA (el prefijo mas largo) para poder
        tener una regla general y excepciones debajo.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [array]$Rules
    )

    if (-not $Rules -or $Rules.Count -eq 0) { return $Uri }

    foreach ($r in ($Rules | Sort-Object { $_.De.Length } -Descending)) {
        if ([string]::IsNullOrWhiteSpace($r.De) -or [string]::IsNullOrWhiteSpace($r.A)) { continue }
        if ($Uri.StartsWith($r.De, [StringComparison]::OrdinalIgnoreCase)) {
            return $r.A + $Uri.Substring($r.De.Length)
        }
    }
    return $Uri
}

function Read-SourceRules {
    <#
        Lee y valida las reglas de un sources.json ya cargado como objeto.
        Separada de la lectura del archivo para poder probarla.

        Una regla mal escrita se descarta con aviso en vez de tumbar el kit: si
        alguien se equivoca en el espejo, lo peor que debe pasar es que se salga
        por la fuente oficial.
    #>
    param([AllowNull()]$Config)

    if (-not $Config -or -not $Config.reglas) { return @() }

    $ok = @()
    foreach ($r in @($Config.reglas)) {
        if ([string]::IsNullOrWhiteSpace($r.de) -or [string]::IsNullOrWhiteSpace($r.a)) {
            Write-Log "sources.json: regla sin 'de' o sin 'a'; se ignora" "WARN"
            continue
        }
        if ($r.de -notmatch '^https?://') {
            Write-Log "sources.json: 'de' debe empezar por http:// o https:// ($($r.de)); se ignora" "WARN"
            continue
        }
        if ($r.a -notmatch '^https?://') {
            Write-Log "sources.json: 'a' debe empezar por http:// o https:// ($($r.a)); se ignora" "WARN"
            continue
        }
        $ok += [PSCustomObject]@{ De = $r.de; A = $r.a }
    }
    return $ok
}

$SourcesFile = Join-Path $DevKitRoot "sources.json"
$script:SourceRulesCache = $null

function Get-SourceRules {
    <#
        Devuelve las reglas de sources.json, leyendolo una sola vez por
        ejecucion. Sin archivo no hay reglas y todo va a las fuentes oficiales,
        que es el comportamiento de siempre.
    #>
    param([switch]$Reload)

    if ($null -ne $script:SourceRulesCache -and -not $Reload) { return $script:SourceRulesCache }

    if (-not (Test-Path -LiteralPath $SourcesFile)) {
        $script:SourceRulesCache = @()
        return $script:SourceRulesCache
    }

    try {
        $cfg = Get-Content -LiteralPath $SourcesFile -Raw | ConvertFrom-Json
    }
    catch {
        Write-Log "sources.json no se pudo leer: $($_.Exception.Message)" "ERROR"
        Write-Log "  Se usaran las fuentes oficiales." "WARN"
        $script:SourceRulesCache = @()
        return $script:SourceRulesCache
    }

    $script:SourceRulesCache = @(Read-SourceRules -Config $cfg)
    return $script:SourceRulesCache
}

function Resolve-KitUrl {
    <#
        La URL por la que el kit debe salir de verdad: la oficial, o la del
        espejo si hay una regla que la cubra. Avisa cuando reescribe, porque una
        descarga que viene de otro sitio del que dice el codigo no puede ser
        invisible.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [switch]$Quiet
    )

    $final = Resolve-SourceUrl -Uri $Uri -Rules (Get-SourceRules)
    if ($final -ne $Uri -and -not $Quiet) {
        Write-Log "  Espejo: $final" "INFO"
    }
    return $final
}

function Split-ProxyCredential {
    <#
    .SYNOPSIS
        Separa una URL de proxy en direccion limpia y credenciales.
    .DESCRIPTION
        La forma documentada de atravesar un proxy corporativo -y la que este
        mismo kit aconseja cuando recibe un 407- es:

            $env:HTTPS_PROXY = "http://usuario:clave@proxy.empresa:8080"

        Esas credenciales hay que sacarlas de la URL y pasarlas aparte.
        Invoke-WebRequest -Proxy acepta la URL entera sin protestar pero DESCARTA
        la parte de usuario y clave, asi que el proxy responde 407 igual que si
        no se hubiera puesto nada.

        No es una suposicion: comprobado contra un proxy Basic de verdad. Con la
        clave CORRECTA en la URL fallaba con el mismo 407, byte por byte, que con
        la clave equivocada; en el registro del proxy se veian los dos CONNECT
        rechazados. Y el consejo que daba el kit al fallar era exactamente lo que
        el usuario ya habia hecho, asi que no habia salida.

        Usuario y clave se desescapan, porque una cuenta de dominio se escribe
        "dominio%5Cusuario" -una barra invertida cruda invalida la URI entera- y
        lo que hay que enviarle al proxy es "dominio\usuario".

        Devuelve Direccion (sin credenciales) y Credencial (PSCredential o $null).
    #>
    param([Parameter(Mandatory=$true)][string]$Proxy)

    $sinCredenciales = [PSCustomObject]@{ Direccion = $Proxy; Credencial = $null }

    try { $u = [Uri]$Proxy } catch { return $sinCredenciales }
    if ([string]::IsNullOrEmpty($u.UserInfo)) { return $sinCredenciales }

    $i = $u.UserInfo.IndexOf(':')
    if ($i -lt 0) {
        $usuario = [Uri]::UnescapeDataString($u.UserInfo)
        $clave   = ''
    }
    else {
        $usuario = [Uri]::UnescapeDataString($u.UserInfo.Substring(0, $i))
        $clave   = [Uri]::UnescapeDataString($u.UserInfo.Substring($i + 1))
    }

    # Sin usuario no hay credencial que construir: PSCredential rechaza el vacio.
    if ([string]::IsNullOrEmpty($usuario)) { return $sinCredenciales }

    # SecureString a mano y no ConvertTo-SecureString: ese cmdlet rechaza la
    # cadena vacia, y "usuario:@proxy" (clave vacia) es una entrada posible.
    $sec = New-Object System.Security.SecureString
    foreach ($c in $clave.ToCharArray()) { $sec.AppendChar($c) }
    $sec.MakeReadOnly()

    # Authority es host:puerto SIN la parte de credenciales, que es justo lo que
    # hay que pasarle a -Proxy. Se conserva la ruta si la hubiera.
    $resto = $u.PathAndQuery
    if ($resto -eq '/') { $resto = '' }

    return [PSCustomObject]@{
        Direccion  = ('{0}://{1}{2}' -f $u.Scheme, $u.Authority, $resto)
        Credencial = (New-Object System.Management.Automation.PSCredential($usuario, $sec))
    }
}

function Add-ProxyToRequest {
    <#
        Rellena en la tabla de parametros de Invoke-WebRequest / Invoke-RestMethod
        lo que haga falta para salir por el proxy.

        Es una funcion compartida y no cuatro copias porque eso fue justo el
        problema: el mismo bloque de tres lineas estaba repetido en los cuatro
        sitios que hacen peticiones, con el mismo fallo en los cuatro.
    #>
    param(
        [Parameter(Mandatory=$true)][hashtable]$Params,
        [Parameter(Mandatory=$true)][Uri]$Uri,
        [switch]$Announce
    )

    $proxy = Resolve-DownloadProxy -Uri $Uri
    if (-not $proxy) { return }

    if ($Announce) { Write-Log "  Proxy detectado: $(Format-ProxyForDisplay $proxy)" }

    $partes = Split-ProxyCredential -Proxy $proxy
    $Params.Proxy = $partes.Direccion

    if ($partes.Credencial) {
        # Credenciales explicitas en la URL. No se pueden combinar con
        # ProxyUseDefaultCredentials: PowerShell rechaza los dos a la vez.
        $Params.ProxyCredential = $partes.Credencial
    }
    else {
        # Sin credenciales escritas: se prueba con la identidad de Windows, que
        # es como estan montados los proxies con autenticacion integrada.
        $Params.ProxyUseDefaultCredentials = $true
    }
}

function Format-ProxyForDisplay {
    <#
        Oculta la contrasena de una URL de proxy antes de mostrarla.

        Es obligatorio usar esto en CUALQUIER sitio donde se imprima un proxy: la
        forma documentada de atravesar un proxy corporativo es
        $env:HTTPS_PROXY = "http://usuario:clave@proxy.empresa:8080", asi que la
        credencial viaja dentro de la propia URL. Sin enmascarar, aparecia en
        claro en la salida de Doctor, que es justo la que el usuario copia y pega
        en un ticket para IT.

        Solo se tapa la contrasena; el usuario se conserva porque suele hacer
        falta para diagnosticar (dominio equivocado, cuenta caducada...).
    #>
    param([AllowNull()][AllowEmptyString()][string]$Proxy)

    if ([string]::IsNullOrWhiteSpace($Proxy)) { return $Proxy }

    # El esquema es opcional: HTTPS_PROXY se define a veces sin el.
    #
    # La contrasena se captura con [^/]* GREEDY, que llega hasta el ULTIMO arroba
    # de la parte de autoridad. Con [^/@]* se paraba en el primero, y una clave
    # que contenga un arroba (P@ssw0rd, de lo mas comun) se filtraba a medias:
    #   dominio\usuario:P@ssw0rd@proxy  ->  dominio\usuario:***@ssw0rd@proxy
    # El usuario admite arroba tambien, para cuentas con formato de correo.
    # Ninguno de los dos cruza la barra, asi que una ruta con arroba
    # (http://proxy:8080/pac@algo) no se confunde con una credencial.
    return [regex]::Replace(
        $Proxy,
        '^(?<scheme>[A-Za-z][A-Za-z0-9+.-]*://)?(?<user>[^/:]+):(?<pass>[^/]*)@',
        '${scheme}${user}:***@')
}

function Protect-ProxySecrets {
    <#
        Enmascara credenciales de proxy que aparezcan EN CUALQUIER PARTE de un
        texto, no solo al principio como Format-ProxyForDisplay.

        Hace falta porque los mensajes de excepcion de .NET incrustan la URL del
        proxy tal cual. Con un proxy mal formado, por ejemplo, salia esto:

          No se puede convertir el valor "http://dominio\u:CLAVE@proxy:8080"
          al tipo "System.Uri"

        y ese texto se imprimia y quedaba en el registro. Enmascarar solo lo que
        imprime el kit no basta: hay que enmascarar tambien lo que imprime .NET.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $Text }

    # La clave se captura greedy hasta el ULTIMO arroba antes de un espacio o una
    # comilla, por el mismo motivo que en Format-ProxyForDisplay: una clave puede
    # contener arrobas. El usuario no puede llevar ':' porque ahi empieza ella.
    return [regex]::Replace(
        $Text,
        '([A-Za-z][A-Za-z0-9+.-]*://)([^/:\s"]+):([^/\s"]*)@',
        '${1}${2}:***@')
}
