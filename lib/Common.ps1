#Requires -Version 5.1
<#
.SYNOPSIS
    Common.ps1 - Funciones compartidas por todas las herramientas del kit.
.DESCRIPTION
    Se carga con dot-sourcing desde los scripts de la carpeta scripts\:

        . (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

    Expone:
      $DevKitRoot            Carpeta raiz del kit (la que contiene lib\ y scripts\).
      $WorkspaceRoot         Carpeta madre, donde viven Angular\, Python\ y Apps\.

      Write-Log              Log con timestamp y color.
      Invoke-Download        Descarga con proxy corporativo, TLS 1.2, reintentos,
                             verificacion SHA-256 y diagnostico de errores.
      Get-FileSha256         SHA-256 de un archivo local.
      Get-Sha256FromShasums  Lee un SHASUMS256.txt remoto (formato de nodejs.org).
      Test-ZipIntegrity      Comprueba que un .zip no llego truncado.
      Add-UserPathEntry      Agrega rutas al PATH de usuario sin duplicar ni romper.
#>

# --------------------------------------------------------------------------
# Rutas base
# --------------------------------------------------------------------------

# lib\ vive dentro del kit, y el kit vive al lado de las carpetas que crea
# (Angular\, Python\, Apps\). Estas dos rutas son el unico punto donde se
# decide "donde se instala todo": los scripts no vuelven a calcularlo.
$DevKitRoot    = Split-Path -Parent $PSScriptRoot
$WorkspaceRoot = Split-Path -Parent $DevKitRoot

# Version del kit. No es lo mismo que $ManifestVersion de Export-Env: aquella
# describe el FORMATO del env.json y decide si un bundle se puede importar; esta
# identifica el kit que lo genero y sirve para diagnosticar ("que version tienes"
# en un informe) y para saber con que se creo un bundle.
#
# Subela al cambiar comportamiento visible; Doctor la muestra y Export-Env la
# anota en el manifiesto.
#
# 2.0.0 y no 1.x: se quedo en 1.0.0 durante mucho tiempo mientras el kit pasaba
# de 4 runtimes a 9, ganaba seis comandos y cambiaba el formato del bundle. Eso
# no es cosmetico: Export-Env estampa este numero en cada bundle e Import-Env
# avisa si no coincide con el suyo, asi que un bundle de hoy y uno de hace meses
# decian ser lo mismo y ese aviso no podia funcionar.
$KitVersion = "2.0.0"

# Windows PowerShell 5.1 negocia TLS 1.0 por defecto, y python.org y nodejs.org
# ya lo rechazan. Sin esto, las descargas fallan con un error de "conexion cerrada"
# que no dice nada.
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
catch {
    # .NET demasiado antiguo para TLS 1.2: seguimos con lo que haya disponible.
}

# --------------------------------------------------------------------------
# Registro en archivo
# --------------------------------------------------------------------------
#
# Se usa Start-Transcript y no un append dentro de Write-Log por una razon
# concreta: Doctor imprime con Write-Host casi todo (39 llamadas frente a 3 de
# Write-Log), asi que enganchar solo Write-Log dejaria el registro vacio justo en
# el caso que mas importa, que es mandarle el diagnostico a IT. El transcript
# captura toda la salida de consola sin tocar ni una de las 300 llamadas del kit.

$KitLogDir = Join-Path $env:LOCALAPPDATA "AssassinSkipAdm\logs"

# Eran 20, y se quedaba corto de largo. Un solo rato de trabajo -instalar cuatro
# runtimes, comprobar con Doctor, desinstalar- se come esos 20 y borra todo lo
# anterior: al intentar auditar que comandos se habian ejecutado, el historial
# solo cubria los ultimos 25 minutos y no servia para nada.
#
# 200 archivos son unos pocos MB y cubren semanas de uso normal. El limite sigue
# siendo por CANTIDAD y no por antiguedad, para que la carpeta no pueda crecer
# sin tope aunque el kit se use en bucle desde un script.
$script:KitLogsToKeep = 200

function Remove-OldKitLogs {
    try {
        $viejos = @(Get-ChildItem -LiteralPath $KitLogDir -Filter '*.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip $script:KitLogsToKeep)
        foreach ($f in $viejos) {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        # La rotacion nunca debe impedir que el registro se haya abierto.
    }
}

function Start-KitLog {
    <#
    .SYNOPSIS
        Abre el registro en archivo de esta ejecucion. Devuelve la ruta, o $null.
    .DESCRIPTION
        Un archivo por ejecucion, en %LOCALAPPDATA%\AssassinSkipAdm\logs, para
        poder decir "mandame el ultimo" sin mas explicaciones.

        Se llama solo al cargar Common.ps1. Reglas que cumple:

          - NUNCA rompe nada. Disco lleno, permisos, un transcript que el usuario
            ya tenia abierto: todo se traga y la herramienta sigue.
          - Silencioso: el "Transcript started" iria a parar a la salida que leen
            otros procesos.
          - Uno por proceso. Common.ps1 se carga por dot-sourcing desde varios
            sitios y Start-Transcript da error si ya hay uno abierto.
          - Se puede desactivar con ASSASSINSKIPADM_NOLOG.

        La clave del proxy no acaba aqui: todo lo que la imprime pasa antes por
        Format-ProxyForDisplay, asi que al registro llega ya enmascarada.
    #>
    param([string]$Name)

    if ($env:ASSASSINSKIPADM_NOLOG) { return $null }
    if ($env:ASSASSINSKIPADM_LOGFILE) { return $env:ASSASSINSKIPADM_LOGFILE }

    try {
        if ([string]::IsNullOrWhiteSpace($Name)) {
            # El frame mas externo de la pila con nombre de script es el que
            # lanzo el usuario; los de dentro son este archivo y sus funciones.
            $conNombre = @(Get-PSCallStack | Where-Object { $_.ScriptName })
            $Name = if ($conNombre.Count) {
                [IO.Path]::GetFileNameWithoutExtension($conNombre[-1].ScriptName)
            } else { 'kit' }
        }

        if (-not (Test-Path -LiteralPath $KitLogDir)) {
            New-Item -ItemType Directory -Path $KitLogDir -Force | Out-Null
        }

        $file = Join-Path $KitLogDir ("{0}-{1}.log" -f $Name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Start-Transcript -LiteralPath $file -Force | Out-Null
        $env:ASSASSINSKIPADM_LOGFILE = $file

        Remove-OldKitLogs
        return $file
    }
    catch {
        return $null
    }
}

# --------------------------------------------------------------------------
# Log
# --------------------------------------------------------------------------

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "HH:mm:ss"
    $color = switch ($Level) {
        "SUCCESS" { "Green" }
        "ERROR" { "Red" }
        "WARN" { "Yellow" }
        default { "White" }
    }
    # Red de seguridad, no sustituto de enmascarar en origen: la fuga que motivo
    # esto llego dentro de un mensaje de excepcion, o sea desde un sitio donde
    # nadie se habria acordado de llamar a Format-ProxyForDisplay. Sobre un texto
    # ya enmascarado no hace nada.
    Write-Host "[$timestamp] [$Level] $(Protect-ProxySecrets -Text $Message)" -ForegroundColor $color
}

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

function Get-WebErrorText {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)

    $parts = @($ErrorRecord.Exception.Message)
    $inner = $ErrorRecord.Exception.InnerException
    while ($inner) {
        $parts += $inner.Message
        $inner = $inner.InnerException
    }
    return (Protect-ProxySecrets -Text ($parts -join ' '))
}

function Get-WebErrorStatus {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)

    $response = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($response -and $response.Value -and $response.Value.StatusCode) {
        return [int]$response.Value.StatusCode
    }
    return $null
}

function Get-DownloadErrorHint {
    <#
        Traduce el error tecnico a la causa real. Este es el valor principal de
        la funcion: en un equipo corporativo casi siempre es el proxy o el
        certificado, y el mensaje crudo de .NET no lo dice.
    #>
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)

    $status = Get-WebErrorStatus -ErrorRecord $ErrorRecord
    $text   = Get-WebErrorText -ErrorRecord $ErrorRecord

    if ($status -eq 407) {
        # Caso mas concreto primero: el proxy pide autenticacion integrada de
        # Windows y la sesion no tiene identidad de red que ofrecer. SSPI
        # responde SEC_E_NO_CREDENTIALS, que .NET traduce por "no hay
        # credenciales disponibles en el paquete de seguridad": un mensaje que
        # no le dice nada a quien lo lee. Pasa en cualquier equipo que no este
        # unido al dominio, donde DefaultNetworkCredentials viene vacio.
        if ($text -match 'paquete de seguridad|security package') {
            return 'El proxy pide autenticacion integrada de Windows, y tu sesion no tiene ninguna identidad de red que ofrecerle (pasa en los equipos que no estan unidos al dominio). Escribe las credenciales a mano:  $env:HTTPS_PROXY = "http://dominio%5Cusuario:clave@proxy.empresa:8080"'
        }

        # Y despues, dos consejos segun si ya habia credenciales puestas. Antes
        # habia uno solo -"pon tus credenciales en HTTPS_PROXY"- y a quien ya las
        # tenia puestas le decia que hiciera lo que acababa de hacer.
        $puesto = @($env:HTTPS_PROXY, $env:HTTP_PROXY, $env:ALL_PROXY | Where-Object { $_ })
        $conCredenciales = @($puesto | Where-Object { $_ -match '^[A-Za-z][A-Za-z0-9+.-]*://[^/@]+@' })

        if ($conCredenciales.Count -gt 0) {
            return 'El proxy rechazo tus credenciales (407). El usuario o la clave no son los que espera. Si es una cuenta de dominio escribela como dominio%5Cusuario, y escapa los caracteres especiales de la clave (@ es %40, : es %3A).'
        }
        return 'El proxy corporativo pide autenticacion (407). Define el proxy con tus credenciales antes de reintentar:  $env:HTTPS_PROXY = "http://usuario:clave@proxy.empresa:8080"'
    }
    if ($status -eq 404) {
        return 'El servidor responde que ese archivo no existe (404). Lo mas probable es que la version pedida no exista; revisa el numero de version.'
    }
    if ($status -eq 403) {
        return 'Acceso denegado (403). Puede que el proxy de la empresa bloquee este dominio; pide a IT que lo permita.'
    }

    if ($text -match 'SSL|secure channel|trust relationship|certificat|certificad') {
        # Lo de la confirmacion no es un detalle menor: comprobado montando un
        # HTTPS con una CA desconocida, Windows saca un cuadro de seguridad al
        # dar de alta una raiz de confianza, y no hay forma de evitarlo (ni
        # siquiera con "certutil -f"). Quien no lo espera lo confunde con el
        # aviso de administrador y responde que no, que es justo lo contrario
        # de lo que hay que hacer aqui.
        return 'Fallo la validacion del certificado TLS. Es lo tipico con proxies que inspeccionan HTTPS: pide a IT el certificado raiz e importalo en "Certificados - Usuario actual" > "Entidades de certificacion raiz de confianza". No necesita admin, pero Windows te pedira una confirmacion: NO es el aviso de administrador, y a esta hay que decirle que si.'
    }
    if ($text -match 'remote name could not be resolved|No such host|nombre remoto') {
        return 'No se pudo resolver el dominio. Revisa la conexion de red o si necesitas la VPN.'
    }
    if ($text -match 'timed out|tiempo de espera|Operation timed out') {
        return 'La conexion agoto el tiempo de espera. Puede ser red lenta, o un proxy que hay que declarar en $env:HTTPS_PROXY.'
    }
    if ($text -match 'Unable to connect|No connection could be made|forcibly closed') {
        return 'No se pudo conectar al servidor. Si sales a internet por proxy, declaralo en $env:HTTPS_PROXY.'
    }

    return $null
}

function Test-TransientError {
    <#
        Solo reintentamos lo que puede arreglarse solo. Un 404 o un 407 no
        mejoran reintentando: fallan igual y hacen esperar al usuario.
    #>
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)

    $status = Get-WebErrorStatus -ErrorRecord $ErrorRecord
    if ($null -ne $status -and $status -lt 500 -and $status -ne 408 -and $status -ne 429) {
        return $false
    }
    return $true
}

function Get-FileSha256 {
    param([Parameter(Mandatory=$true)][string]$FilePath)
    return (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-FileSha512 {
    <#
        Hace falta porque no todo el mundo publica SHA-256: Apache firma sus
        distribuciones (Maven, entre otras) con SHA-512.
    #>
    param([Parameter(Mandatory=$true)][string]$FilePath)
    return (Get-FileHash -LiteralPath $FilePath -Algorithm SHA512).Hash.ToLowerInvariant()
}

function Get-FileSignerInfo {
    <#
    .SYNOPSIS
        Quien firmo un archivo, segun la firma Authenticode de Windows.
    .DESCRIPTION
        Es lo unico que da AUTENTICIDAD en este kit. Los checksums dan
        integridad -el archivo llego entero- pero no autenticidad, porque salen
        del MISMO servidor que el archivo; con un espejo interno configurado,
        del mismo espejo. Authenticode responde a otra pregunta: quien lo firmo
        y si ha cambiado desde entonces, contra una cadena de confianza que
        Windows ya trae.

        Se intento antes con GPG y se abandono por el problema de distribuir y
        rotar las claves publicas. Authenticode no tiene ese problema.

        NUNCA se usa para bloquear, y no es una postura sino una necesidad: el
        MSI de 7-Zip, que el propio kit descarga para extraer instaladores NSIS,
        NO esta firmado. Bloquear lo no firmado romperia el kit consigo mismo.
        Ademas firmar no es cosa de empresas grandes: el instalador de
        Notepad++ lo firma una persona con su correo.

        Devuelve Firmable, Estado y Firmante. Firmable es $false para un .zip:
        ahi no hay nada que comprobar y no tiene sentido decir "sin firma".
    #>
    param([Parameter(Mandatory=$true)][string]$FilePath)

    $sinFirma = [PSCustomObject]@{ Firmable = $false; Estado = $null; Firmante = $null }

    if (-not (Test-Path -LiteralPath $FilePath)) { return $sinFirma }

    # Solo estos formatos llevan Authenticode. Un zip o un tar.gz no.
    $ext = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()
    if ($ext -notin @('.exe', '.msi', '.dll', '.ps1', '.cab', '.msp', '.sys', '.cat')) {
        return $sinFirma
    }

    try {
        $s = Get-AuthenticodeSignature -LiteralPath $FilePath -ErrorAction Stop
    }
    catch {
        return [PSCustomObject]@{ Firmable = $true; Estado = 'NoSePudoLeer'; Firmante = $null }
    }

    $quien = $null
    if ($s.SignerCertificate) {
        # Del sujeto del certificado interesa el CN, o el correo si no hay CN:
        # asi lo firma alguna gente a titulo personal.
        $subject = $s.SignerCertificate.Subject
        if ($subject -match 'CN=(?:")?([^",]+)') { $quien = $Matches[1].Trim() }
        elseif ($subject -match 'E=([^,]+)')     { $quien = $Matches[1].Trim() }
        else { $quien = $subject }
    }

    return [PSCustomObject]@{ Firmable = $true; Estado = [string]$s.Status; Firmante = $quien }
}

function Write-SignerReport {
    <#
        Cuenta quien firma un archivo recien descargado. Informativo: describe,
        no decide. Con -Esperado ademas avisa si el firmante NO es el de
        siempre, que es la senal que de verdad importa; aun asi solo avisa.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string]$Esperado
    )

    $f = Get-FileSignerInfo -FilePath $FilePath
    if (-not $f.Firmable) { return }

    if ($f.Estado -eq 'Valid') {
        Write-Log "  Firmado por: $($f.Firmante)" "SUCCESS"

        if ($Esperado -and $f.Firmante -notlike "*$Esperado*") {
            Write-Log "  OJO: se esperaba a $Esperado y firma otro." "WARN"
            Write-Log "  Puede ser un cambio legitimo de certificado, o no. Revisalo." "WARN"
        }
    }
    elseif ($f.Estado -eq 'NotSigned') {
        # Ni error ni sospecha por si sola: hay software legitimo sin firmar,
        # empezando por el 7-Zip que usa este mismo kit.
        Write-Log "  Sin firma Authenticode (no todo el software se firma)" "INFO"
    }
    elseif ($f.Estado -in @('UnknownError', 'NoSePudoLeer') -and -not $f.Firmante) {
        # SIN certificado: Windows no pudo determinar nada, normalmente porque
        # el archivo ni siquiera tiene el formato que sabe firmar. Ni error ni
        # sospecha.
        Write-Log "  Sin firma reconocible (Windows no pudo determinarla)" "INFO"
    }
    elseif ($f.Estado -in @('UnknownError', 'NoSePudoLeer')) {
        # CON certificado y aun asi UnknownError: esta firmado, pero la cadena
        # no llega a una raiz de confianza de este equipo. Es lo que devuelve un
        # archivo firmado por alguien desconocido, y agruparlo con "sin firma"
        # seria taparlo justo cuando mas conviene decirlo. Comprobado firmando
        # un script con un certificado autofirmado.
        Write-Log "  Firmado por $($f.Firmante), pero tu equipo NO confia en quien lo emitio" "WARN"
        Write-Log "  Certificado autofirmado, caducado, o de una entidad que no reconoces." "WARN"
    }
    else {
        # Aqui si conviene mirar: hay firma y NO valida. Caducada, revocada,
        # alterada tras firmarse, o de una entidad en la que no se confia.
        Write-Log "  Firma presente pero NO valida: $($f.Estado)" "WARN"
        if ($f.Firmante) { Write-Log "  Dice ser: $($f.Firmante)" "WARN" }
    }
}

function Get-HashFromChecksumText {
    <#
    .SYNOPSIS
        Saca el hash del contenido de un archivo de checksum suelto.
    .DESCRIPTION
        No hay un formato unico. Los tres que se encuentran en la practica:

            <hash>                      (Apache Maven)
            <hash>  nombre-archivo      (formato de sha256sum)
            nombre-archivo: <hash>      (algun mirror de BSD)

        Se acepta cualquiera de los tres y se comprueba que lo hallado tenga la
        longitud que corresponde al algoritmo, para no dar por bueno el trozo de
        una pagina de error HTML.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [ValidateSet('SHA256', 'SHA512')][string]$Algorithm = 'SHA256'
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $largo = if ($Algorithm -eq 'SHA512') { 128 } else { 64 }

    foreach ($linea in ($Text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($linea)) { continue }
        $m = [regex]::Match($linea, "\b([0-9a-fA-F]{$largo})\b")
        if ($m.Success) { return $m.Groups[1].Value.ToLowerInvariant() }
    }
    return $null
}

function Invoke-Download {
    <#
    .SYNOPSIS
        Descarga un archivo de forma segura en un entorno corporativo.
    .DESCRIPTION
        - Detecta y usa el proxy (variables de entorno o proxy del sistema).
        - Reintenta solo los fallos transitorios.
        - Descarga a un archivo .part y solo lo publica si todo salio bien, para
          no dejar nunca un archivo a medias que parezca una descarga valida.
        - Verifica SHA-256 si se le pasa uno.
        - Explica en castellano que fallo y como arreglarlo.
        Devuelve $true / $false; no lanza excepciones.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [Parameter(Mandatory=$true)][string]$OutFile,
        [string]$Sha256,
        # Apache publica SHA-512 en vez de SHA-256, asi que no basta con uno.
        [string]$Sha512,
        # Quien deberia firmar esto. Solo para avisar si firma otro; nunca
        # bloquea, ni siquiera si no hay firma ninguna.
        [string]$FirmanteEsperado,
        [string]$Description,
        [int]$Retries = 2
    )

    if ([string]::IsNullOrWhiteSpace($Description)) {
        $Description = Split-Path -Leaf $Uri
    }

    $parent = Split-Path -Parent $OutFile
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $temp = "$OutFile.part"
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }

    # El espejo interno, si lo hay, antes que nada: todo lo de abajo -incluido
    # el mensaje de error- debe hablar de la URL por la que se salio de verdad.
    $Uri = Resolve-KitUrl -Uri $Uri

    $params = @{
        Uri             = $Uri
        OutFile         = $temp
        UseBasicParsing = $true
        TimeoutSec      = 300
    }

    Add-ProxyToRequest -Params $params -Uri ([Uri]$Uri) -Announce

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            Invoke-WebRequest @params
            break
        }
        catch {
            if (Test-Path -LiteralPath $temp) {
                Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
            }

            if ($attempt -le $Retries -and (Test-TransientError -ErrorRecord $_)) {
                Write-Log "  Intento $attempt fallo; reintentando..." "WARN"
                Start-Sleep -Seconds (2 * $attempt)
                continue
            }

            Write-Log "No se pudo descargar: $Description" "ERROR"
            Write-Log "  URL: $Uri" "ERROR"
            Write-Log "  $(Get-WebErrorText -ErrorRecord $_)" "ERROR"

            $hint = Get-DownloadErrorHint -ErrorRecord $_
            if ($hint) { Write-Log "  -> $hint" "WARN" }

            return $false
        }
    }

    $esperado = $null
    $algoritmo = $null
    if (-not [string]::IsNullOrWhiteSpace($Sha256)) {
        $esperado = $Sha256.Trim().ToLowerInvariant(); $algoritmo = 'SHA-256'
        $obtenido = Get-FileSha256 -FilePath $temp
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Sha512)) {
        $esperado = $Sha512.Trim().ToLowerInvariant(); $algoritmo = 'SHA-512'
        $obtenido = Get-FileSha512 -FilePath $temp
    }

    if ($esperado) {
        if ($obtenido -ne $esperado) {
            Write-Log "El archivo descargado no coincide con el hash oficial." "ERROR"
            Write-Log "  esperado: $esperado" "ERROR"
            Write-Log "  obtenido: $obtenido" "ERROR"
            Write-Log "  -> Descarga corrupta o alterada en transito. No se va a usar." "WARN"
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
            return $false
        }

        Write-Log "  $algoritmo verificado" "SUCCESS"
    }

    # La firma se mira SIEMPRE, haya checksum o no, y se cuenta sin decidir
    # nada por el usuario. Es lo unico que dice de QUIEN viene el archivo: el
    # checksum solo dice que llego entero, y encima sale del mismo sitio.
    if (Test-Path -LiteralPath $OutFile) {
        Remove-Item -LiteralPath $OutFile -Force
    }
    Move-Item -LiteralPath $temp -Destination $OutFile -Force

    # La firma se mira SIEMPRE, haya checksum o no, y se cuenta sin decidir nada
    # por el usuario. Es lo unico que dice de QUIEN viene el archivo: el checksum
    # solo dice que llego entero, y encima sale del mismo sitio.
    #
    # Va DESPUES de publicar el archivo, no antes: mientras se descarga se llama
    # ".part", y Get-FileSignerInfo decide si mirar por la extension. Con el
    # nombre temporal no reconocia ni un .exe ni un .ps1 como firmables, asi que
    # no se anunciaba ninguna firma. Salio al probarlo con Git y con
    # dotnet-install.ps1, que si estan firmados y no decian nada.
    Write-SignerReport -FilePath $OutFile -Esperado $FirmanteEsperado

    return $true
}

function Restore-EnvVar {
    <#
        Devuelve una variable de entorno del proceso a su valor anterior.
        Si antes no existia hay que ELIMINARLA, no ponerla a cadena vacia:
        para muchas herramientas (npm entre ellas) "definida y vacia" no
        significa lo mismo que "no definida".
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [AllowNull()][AllowEmptyString()][string]$Value
    )

    if ([string]::IsNullOrEmpty($Value)) {
        Remove-Item -LiteralPath "Env:\$Name" -ErrorAction SilentlyContinue
    }
    else {
        Set-Item -LiteralPath "Env:\$Name" -Value $Value
    }
}

function Invoke-NativeCommand {
    <#
    .SYNOPSIS
        Ejecuta un binario externo y devuelve su codigo de salida.
    .DESCRIPTION
        En Windows PowerShell 5.1, todo lo que un .exe escribe en stderr se
        envuelve en un ErrorRecord. Con $ErrorActionPreference = "Stop" eso
        aborta el script aunque el comando solo estuviera comprobando algo, y
        ni "2>$null" ni "*> $null" lo impiden: la redireccion tira la salida,
        pero el ErrorRecord ya se genero.

        Casos reales que rompia: "python -m pip --version" en una instalacion
        nueva (escribe "No module named pip" en stderr, que es la respuesta
        esperada) y cualquier "npm install" que emita warnings.

        Con -Quiet la salida se captura y se devuelve; sin el, se muestra
        indentada segun va llegando.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$Quiet
    )

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        try {
            if ($Quiet) {
                $captured = & $FilePath @Arguments 2>&1
            }
            else {
                $captured = & $FilePath @Arguments 2>&1 |
                    ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray; $_ }
            }

            return [PSCustomObject]@{
                ExitCode = $LASTEXITCODE
                Output   = ($captured | Out-String)
            }
        }
        catch {
            # Un binario que ni siquiera arranca (descarga truncada, arquitectura
            # incorrecta, archivo que no es un ejecutable) lanza una excepcion
            # TERMINANTE, que $ErrorActionPreference = 'Continue' no neutraliza.
            # Se devuelve como un fallo normal para que quien llama decida.
            return [PSCustomObject]@{
                ExitCode = -1
                Output   = $_.Exception.Message
                Failed   = $true
            }
        }
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

function Invoke-JsonApi {
    <#
        GET de una API JSON con el mismo tratamiento de proxy que Invoke-Download.
        Devuelve el objeto ya convertido, o $null si fallo (sin lanzar excepcion:
        quien llama decide si eso es fatal o si tira de un valor de respaldo).
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [hashtable]$Headers,
        [int]$TimeoutSec = 60,
        [switch]$Quiet
    )

    $Uri = Resolve-KitUrl -Uri $Uri -Quiet:$Quiet

    $params = @{
        Uri             = $Uri
        UseBasicParsing = $true
        TimeoutSec      = $TimeoutSec
    }
    if ($Headers) { $params.Headers = $Headers }

    Add-ProxyToRequest -Params $params -Uri ([Uri]$Uri)

    try {
        return Invoke-RestMethod @params
    }
    catch {
        if (-not $Quiet) {
            Write-Log "No se pudo consultar $Uri" "WARN"
            $hint = Get-DownloadErrorHint -ErrorRecord $_
            if ($hint) { Write-Log "  -> $hint" "WARN" }
        }
        return $null
    }
}

# --------------------------------------------------------------------------
# Semver (lo justo para leer campos "engines" de npm)
# --------------------------------------------------------------------------

function ConvertTo-SemverObject {
    param([Parameter(Mandatory=$true)][string]$Version)

    # Quita la 'v' inicial y cualquier sufijo de prerelease o build.
    $clean = $Version.Trim().TrimStart('v', 'V').Split('-')[0].Split('+')[0]
    $parts = @($clean.Split('.') | Where-Object { $_ -match '^\d+$' })
    while ($parts.Count -lt 3) { $parts += '0' }

    return [version]("{0}.{1}.{2}" -f $parts[0], $parts[1], $parts[2])
}

function Test-SemverComparator {
    param(
        [Parameter(Mandatory=$true)][version]$Version,
        [Parameter(Mandatory=$true)][string]$Comparator
    )

    $c = $Comparator.Trim()
    if ($c -eq '' -or $c -eq '*') { return $true }

    if ($c -match '^\^\s*(.+)$') {
        # ^X.Y.Z  =>  >= X.Y.Z  y  < (X+1).0.0
        $base  = ConvertTo-SemverObject $Matches[1]
        $upper = [version]("{0}.0.0" -f ($base.Major + 1))
        return ($Version -ge $base -and $Version -lt $upper)
    }
    if ($c -match '^~\s*(.+)$') {
        # ~X.Y.Z  =>  >= X.Y.Z  y  < X.(Y+1).0
        $base  = ConvertTo-SemverObject $Matches[1]
        $upper = [version]("{0}.{1}.0" -f $base.Major, ($base.Minor + 1))
        return ($Version -ge $base -and $Version -lt $upper)
    }
    if ($c -match '^>=\s*(.+)$') { return $Version -ge (ConvertTo-SemverObject $Matches[1]) }
    if ($c -match '^<=\s*(.+)$') { return $Version -le (ConvertTo-SemverObject $Matches[1]) }
    if ($c -match '^>\s*(.+)$')  { return $Version -gt (ConvertTo-SemverObject $Matches[1]) }
    if ($c -match '^<\s*(.+)$')  { return $Version -lt (ConvertTo-SemverObject $Matches[1]) }
    if ($c -match '^=\s*(.+)$')  { return $Version -eq (ConvertTo-SemverObject $Matches[1]) }

    # Comodines y versiones parciales: "20", "20.x", "20.*", "20.19", "20.19.x".
    # La forma "14.x" es de lo mas comun en un campo engines, y antes caia en el
    # ultimo return de esta funcion, que la trataba como version EXACTA: la 'x' se
    # descartaba al normalizar y "14.x" acababa significando "exactamente 14.0.0".
    # Cualquier Node 14.21 quedaba descartado y nadie se enteraba.
    if ($c -match '^v?(\d+)(?:\.(\d+|[xX*]))?(?:\.(\d+|[xX*]))?$') {
        $major = [int]$Matches[1]
        $minor = $Matches[2]
        $patch = $Matches[3]

        # Sin menor, o con comodin => toda la mayor:  >=X.0.0  <(X+1).0.0
        if ([string]::IsNullOrEmpty($minor) -or $minor -match '^[xX*]$') {
            return ($Version -ge [version]("{0}.0.0" -f $major) -and
                    $Version -lt [version]("{0}.0.0" -f ($major + 1)))
        }

        # Sin parche, o con comodin => toda la menor:  >=X.Y.0  <X.(Y+1).0
        if ([string]::IsNullOrEmpty($patch) -or $patch -match '^[xX*]$') {
            return ($Version -ge [version]("{0}.{1}.0" -f $major, [int]$minor) -and
                    $Version -lt [version]("{0}.{1}.0" -f $major, ([int]$minor + 1)))
        }

        return ($Version -eq [version]("{0}.{1}.{2}" -f $major, [int]$minor, [int]$patch))
    }

    # No se entiende. Se devuelve $false, que es lo conservador, pero quien llama
    # deberia haber avisado antes con Get-UnsupportedSemverComparators: fallar en
    # silencio aqui es como "14.x" paso desapercibido tanto tiempo.
    return $false
}

function Test-SemverComparatorSupported {
    <#
        Dice si Test-SemverComparator sabe interpretar este termino. Se mantiene
        al lado de la funcion anterior a proposito: si alli se anade una forma
        nueva, aqui hay que anadirla tambien o se avisara de algo que si funciona.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Comparator)

    $c = $Comparator.Trim()
    if ($c -eq '' -or $c -eq '*') { return $true }
    if ($c -match '^(\^|~|>=|<=|>|<|=)\s*v?\d') { return $true }
    if ($c -match '^v?\d+(\.(\d+|[xX*]))?(\.(\d+|[xX*]))?$') { return $true }
    return $false
}

function Get-UnsupportedSemverComparators {
    <#
    .SYNOPSIS
        Devuelve los terminos de un rango que Test-SemverRange no sabe leer.
    .DESCRIPTION
        Sirve para avisar UNA vez, antes de usar el rango, en vez de que
        Test-SemverRange devuelva $false en silencio por cada version candidata.

        Lo tipico que aparece aqui es un rango con guion ("1.2 - 1.5"), que sigue
        sin soportarse. Si algun dia un campo engines lo usara, el usuario vera el
        aviso y podra forzar la version a mano en vez de quedarse sin entender por
        que el kit eligio lo que eligio.
    .EXAMPLE
        Get-UnsupportedSemverComparators -Range '^20.19.0 || 1.2 - 1.5'
        # -1.2, -, 1.5  ->  se avisa del guion
    #>
    param([Parameter(Mandatory=$true)][string]$Range)

    $raros = @()
    foreach ($branch in ($Range -split '\|\|')) {
        foreach ($c in @($branch.Trim() -split '\s+' | Where-Object { $_ -ne '' })) {
            if (-not (Test-SemverComparatorSupported -Comparator $c)) { $raros += $c }
        }
    }
    return @($raros | Select-Object -Unique)
}

function Test-SemverRange {
    <#
    .SYNOPSIS
        Comprueba si una version cumple un rango semver de npm.
    .DESCRIPTION
        Soporta lo que usan los campos "engines" en la practica: ^, ~, >=, <=,
        >, <, versiones exactas, alternativas con || y conjunciones separadas
        por espacio (">=18.0.0 <21.0.0").
        No implementa semver completo: no cubre rangos con guion ("1.2 - 1.5")
        ni comodines parciales ("1.x").
    .EXAMPLE
        Test-SemverRange -Version "20.20.2" -Range "^22.22.3 || ^24.15.0 || >=26.0.0"
        # False
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Version,
        [Parameter(Mandatory=$true)][string]$Range
    )

    $v = ConvertTo-SemverObject $Version

    foreach ($branch in ($Range -split '\|\|')) {
        $comparators = @($branch.Trim() -split '\s+' | Where-Object { $_ -ne '' })
        if ($comparators.Count -eq 0) { continue }

        $all = $true
        foreach ($c in $comparators) {
            if (-not (Test-SemverComparator -Version $v -Comparator $c)) {
                $all = $false
                break
            }
        }
        if ($all) { return $true }
    }

    return $false
}

# --------------------------------------------------------------------------
# Shells generados
# --------------------------------------------------------------------------
#
# Los .bat que abre Start-*Env viven aqui y no en cada setup porque los generan
# CUATRO sitios: los tres Setup-*, Import-Env (que los rehace con las rutas de la
# maquina destino) y Doctor -Fix (que los regenera si faltan). Con copias sueltas
# acabarian divergiendo y el shell diria una cosa distinta segun quien lo escribio.

function ConvertTo-PsLiteral {
    <#
        Escapa un valor para incrustarlo entre comillas SIMPLES en codigo de
        PowerShell generado. Ahi el unico caracter con significado es la propia
        comilla simple, y se anula duplicandola.

        Sin esto, un usuario llamado O'Brien producia un activate.ps1
        sintacticamente roto que el perfil carga en CADA PowerShell nuevo.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Value)
    return $Value.Replace("'", "''")
}

function ConvertTo-CmdLiteral {
    <#
        Escapa un valor para incrustarlo en un .bat dentro de set "VAR=...".
        Las comillas ya neutralizan &, |, ^, < y >; lo que sigue vivo es el
        porcentaje, que cmd expande al leer la linea y que es legal en un nombre
        de carpeta de Windows. Duplicarlo lo deja literal.

        Se aplica SOLO a los valores, nunca a la plantilla: el %PATH% del final
        tiene que expandirse de verdad.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Value)
    return $Value.Replace('%', '%%')
}

function ConvertFrom-CmdLiteral {
    <#
        Deshace ConvertTo-CmdLiteral. Hace falta porque Use-Env vuelve a LEER los
        shells generados para saber que rutas antepone cada uno: sin esto, una
        ruta con porcentaje se leeria con el %% puesto y se volveria a escapar en
        cada pasada (%%%%, %%%%%%%%...).
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Value)
    return $Value.Replace('%%', '%')
}

function ConvertTo-CmdEchoText {
    <#
        Escapa un valor para una linea "echo ..." de un .bat. Aqui no se puede
        recurrir a las comillas como en set: se imprimirian. Hay que escapar a
        mano cada caracter especial de cmd.

        El circunflejo va PRIMERO porque es el propio caracter de escape: hacerlo
        despues escaparia los que acabamos de anadir.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Value)

    $result = $Value.Replace('^', '^^')
    foreach ($c in @('&', '|', '<', '>')) { $result = $result.Replace($c, "^$c") }
    return $result.Replace('%', '%%')
}

function Write-AngularShell {
    param(
        [Parameter(Mandatory=$true)][string]$AngularPath,
        [Parameter(Mandatory=$true)][string]$NodePath,
        [Parameter(Mandatory=$true)][string]$Version,
        [Parameter(Mandatory=$true)][string]$NodeVersion
    )

    $angularRoot = Split-Path -Parent $AngularPath
    $npmPrefix   = Join-Path $AngularPath "npm-global"
    $npmCache    = Join-Path $angularRoot "npm-cache"

    # El prefix y la cache van aqui, no en el .npmrc del usuario: asi el npm que
    # ya tuviera instalado sigue intacto y este shell queda autocontenido.
    #
    # Las rutas van en set "VAR=..." y escapadas. Sin las comillas, un & o un ^
    # en la ruta (legales en Windows: "Marks & Spencer", muy posible en el nombre
    # de una carpeta corporativa) rompia la linea entera.
    $nodeCmd    = ConvertTo-CmdLiteral $NodePath
    $prefixCmd  = ConvertTo-CmdLiteral $npmPrefix
    $cacheCmd   = ConvertTo-CmdLiteral $npmCache
    $proyectos  = ConvertTo-CmdEchoText (Join-Path $AngularPath "projects")

    $lines = @(
        "@echo off",
        "set `"PATH=$nodeCmd;$prefixCmd;%PATH%`"",
        "set `"NPM_CONFIG_PREFIX=$prefixCmd`"",
        "set `"NPM_CONFIG_CACHE=$cacheCmd`"",
        "title Angular v$Version Development Shell",
        "echo.",
        "echo ============================================",
        "echo   Angular v$Version Development Shell",
        "echo ============================================",
        "echo.",
        "echo Node: $NodeVersion",
        "echo Angular CLI: v$Version",
        "echo.",
        "echo Proyectos: $proyectos",
        "echo.",
        "echo Comandos:",
        "echo   ng new [nombre]     - Crear proyecto",
        "echo   ng serve            - Iniciar servidor",
        "echo.",
        "echo Escribe exit para cerrar",
        "cmd /k"
    )

    $file = Join-Path $AngularPath "shell-v$Version.bat"
    Set-Content -Path $file -Value ($lines -join "`n") -Encoding ASCII
    return $file
}

function Write-PythonShell {
    param(
        [Parameter(Mandatory=$true)][string]$PythonPath,
        [Parameter(Mandatory=$true)][string]$Version
    )

    $tag = $Version -replace '\.', ''
    $scripts = Join-Path $PythonPath "Scripts"

    $pythonCmd  = ConvertTo-CmdLiteral $PythonPath
    $scriptsCmd = ConvertTo-CmdLiteral $scripts

    $lines = @(
        "@echo off",
        "set `"PATH=$pythonCmd;$scriptsCmd;%PATH%`"",
        "title Python v$Version Shell",
        "echo.",
        "echo ============================================",
        "echo   Python v$Version Shell",
        "echo ============================================",
        "echo.",
        "python.exe --version",
        "echo.",
        "echo Comandos:",
        "echo   python --version    - Ver version",
        "echo   pip install [paq]   - Instalar paquete",
        "echo.",
        "echo Escribe exit para cerrar",
        "cmd /k"
    )

    $file = Join-Path $PythonPath "py$tag-shell.bat"
    Set-Content -Path $file -Value ($lines -join "`n") -Encoding ASCII
    return $file
}

function Write-JavaShell {
    param(
        [Parameter(Mandatory=$true)][string]$JdkPath,
        [Parameter(Mandatory=$true)][string]$Major,
        [string]$Release
    )

    $bin = Join-Path $JdkPath "bin"

    $binCmd     = ConvertTo-CmdLiteral $bin
    $jdkCmd     = ConvertTo-CmdLiteral $JdkPath
    $jdkEcho    = ConvertTo-CmdEchoText $JdkPath

    $lines = @(
        "@echo off",
        "set `"PATH=$binCmd;%PATH%`"",
        "set `"JAVA_HOME=$jdkCmd`"",
        "title Java $Major Shell",
        "echo.",
        "echo ============================================",
        "echo   Java $Major Shell",
        "echo ============================================",
        "echo.",
        "echo Release: $Release",
        "echo JAVA_HOME: $jdkEcho",
        "echo.",
        "java -version",
        "echo.",
        "echo Comandos:",
        "echo   javac Archivo.java  - Compilar",
        "echo   jar                 - Empaquetar",
        "echo.",
        "echo Escribe exit para cerrar",
        "cmd /k"
    )

    $file = Join-Path $JdkPath "java$Major-shell.bat"
    Set-Content -Path $file -Value ($lines -join "`n") -Encoding ASCII
    return $file
}

# --------------------------------------------------------------------------
# Herramientas auxiliares (7z, innoextract)
# --------------------------------------------------------------------------
#
# Install-NoAdmin necesita un extractor para los instaladores NSIS e Inno Setup.
# Antes se limitaba a decir que faltaba y parar. Ahora el kit puede conseguirlos
# el mismo y los deja aqui, en una carpeta hermana como el resto.

$KitToolsDir = Join-Path $WorkspaceRoot "Apps\tools"

function Find-KitTool {
    <#
    .SYNOPSIS
        Localiza una herramienta auxiliar. Devuelve su ruta, o $null.
    .DESCRIPTION
        Busca en dos sitios y en este orden:

          1. El PATH. Si el usuario ya tiene la herramienta instalada, se usa la
             suya: el kit no debe imponer su copia sobre algo que ya funciona.
          2. Apps\tools, donde deja las que ha descargado el propio kit.

        Solo busca. Descargarla es cosa de Install-NoAdmin, que es quien sabe si
        hace falta de verdad; Doctor usa esto para informar sin descargar nada.
    #>
    param([Parameter(Mandatory=$true)][string]$FileName)

    $enPath = Get-Command $FileName -ErrorAction SilentlyContinue
    if ($enPath) { return $enPath.Source }

    $propia = Join-Path $KitToolsDir $FileName
    if (Test-Path -LiteralPath $propia) { return $propia }

    return $null
}

function Test-RuntimeSelected {
    <#
        Ayuda a los scripts que aceptan un -Runtime opcional: sin valor, todos
        entran; con valor, solo el elegido.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [AllowEmptyString()][AllowNull()][string]$Selected
    )
    return ([string]::IsNullOrWhiteSpace($Selected) -or $Selected -eq $Name)
}

function Get-NodeArchiveInfo {
    <#
        URL y checksum oficial del zip de Node para una version concreta.
        Se centraliza aqui porque lo usan Setup-AngularEnv y Export-Env, y si
        divergieran el bundle offline traeria un archivo distinto al que instala
        el setup normal.
    #>
    param([Parameter(Mandatory=$true)][string]$Version)

    $v = $Version.TrimStart('v')
    $folder = "node-v$v-win-x64"
    $file = "$folder.zip"

    return [PSCustomObject]@{
        FileName   = $file
        FolderName = $folder
        Url        = "https://nodejs.org/dist/v$v/$file"
        ShasumsUrl = "https://nodejs.org/dist/v$v/SHASUMS256.txt"
    }
}

$NodeIndexUrl = "https://nodejs.org/dist/index.json"

function Get-NodeLtsReleases {
    <#
        Ultima release de cada linea LTS de Node que tenga zip para win-x64.
        El indice viene ordenado de mas nueva a mas vieja.

        Vive aqui y no en Setup-AngularEnv porque lo usan tres sitios: la
        resolucion de Node para Angular, Setup-NodeEnv y Update-Env.
    #>
    $index = Invoke-JsonApi -Uri $NodeIndexUrl -TimeoutSec 120 -Quiet
    if (-not $index) { return @() }

    $seen = @{}
    $result = @()
    foreach ($rel in $index) {
        if (-not $rel.lts -or $rel.lts -eq $false) { continue }
        if ($rel.files -notcontains 'win-x64-zip') { continue }

        $major = [int](($rel.version.TrimStart('v')).Split('.')[0])
        if ($seen.ContainsKey($major)) { continue }

        $seen[$major] = $true
        $result += [PSCustomObject]@{
            Major   = $major
            Version = $rel.version.TrimStart('v')
            Lts     = $rel.lts
        }
    }

    return @($result | Sort-Object Major)
}

function Write-NodeShell {
    <#
        Shell de una Node instalada suelta (sin Angular). No define
        NPM_CONFIG_PREFIX: al no haber un CLI global que aislar, npm usa su
        prefijo normal dentro de la propia carpeta de Node.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$NodePath,
        [Parameter(Mandatory=$true)][string]$Version
    )

    $nodeCmd = ConvertTo-CmdLiteral $NodePath
    $major   = $Version.Split('.')[0]

    $lines = @(
        "@echo off",
        "set `"PATH=$nodeCmd;%PATH%`"",
        "title Node v$Version Shell",
        "echo.",
        "echo ============================================",
        "echo   Node v$Version Shell",
        "echo ============================================",
        "echo.",
        "node --version",
        "npm --version",
        "echo.",
        "echo Comandos:",
        "echo   node archivo.js     - Ejecutar",
        "echo   npm install         - Instalar dependencias",
        "echo.",
        "echo Escribe exit para cerrar",
        "cmd /k"
    )

    $file = Join-Path $NodePath "node$major-shell.bat"
    Set-Content -Path $file -Value ($lines -join "`n") -Encoding ASCII
    return $file
}

# --------------------------------------------------------------------------
# Git portable
#
# Git es el peor caso que se encontro probando Install-NoAdmin: su instalador
# ignora /CURRENTUSER, pide admin y se instala para toda la maquina; y tampoco
# se puede extraer, porque usa un Inno Setup mas nuevo del que sabe leer
# innoextract (y 7-Zip no reconoce el formato).
#
# PortableGit es la salida, y es oficial: no es un instalador sino un 7-Zip
# autoextraible que Git for Windows publica en cada release. No toca el
# registro, no pide admin y trae Git Bash entero.
# --------------------------------------------------------------------------

$GitReleasesApi = "https://api.github.com/repos/git-for-windows/git/releases"

function Get-Sha256FromReleaseBody {
    <#
        Saca el SHA-256 de un archivo de la tabla que Git for Windows publica en
        el cuerpo de cada release:

            Filename | SHA-256
            -------- | -------
            PortableGit-2.55.0.5-64-bit.7z.exe | 5aa8a20f6e9a...

        Es texto libre escrito por quien publica la release, no un campo de la
        API, asi que se busca la linea del archivo EXACTO en vez de fiarse de la
        posicion, y se comprueba que lo hallado tenga forma de SHA-256.
    #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][AllowNull()][string]$Body,
        [Parameter(Mandatory=$true)][string]$FileName
    )

    if ([string]::IsNullOrWhiteSpace($Body)) { return $null }

    foreach ($linea in ($Body -split "`r?`n")) {
        $partes = $linea -split '\|'
        if ($partes.Count -lt 2) { continue }
        if ($partes[0].Trim() -ne $FileName) { continue }

        $hash = $partes[1].Trim().ToLowerInvariant()
        if ($hash -match '^[0-9a-f]{64}$') { return $hash }
    }
    return $null
}

function Get-GitPortableAsset {
    <#
        De una release de la API de GitHub saca el autoextraible de PortableGit
        de 64 bits, con su version y su checksum.

        Separada de la llamada de red para poder probarla: recibe el objeto de
        la release ya descargado. Devuelve $null si esa release no publica un
        PortableGit de 64 bits, que pasa en algunas.
    #>
    param([Parameter(Mandatory=$true)]$Release)

    $asset = @($Release.assets | Where-Object { $_.name -match '^PortableGit-([\d.]+)-64-bit\.7z\.exe$' })
    if ($asset.Count -eq 0) { return $null }

    $nombre = $asset[0].name
    $null = $nombre -match '^PortableGit-([\d.]+)-64-bit\.7z\.exe$'

    return [PSCustomObject]@{
        Version  = $Matches[1]
        FileName = $nombre
        Url      = $asset[0].browser_download_url
        Sha256   = (Get-Sha256FromReleaseBody -Body $Release.body -FileName $nombre)
        Tag      = $Release.tag_name
    }
}

function Get-GitPortableRelease {
    <#
        Devuelve el PortableGit a instalar. Sin -Version, el de la ultima
        release; con -Version (ej: 2.55.0.5), se busca entre las ultimas
        publicadas.

        No se compone la etiqueta a mano a partir de la version: la etiqueta es
        "v2.55.0.windows.5" y el archivo "PortableGit-2.55.0.5-64-bit.7z.exe",
        dos formas distintas del mismo numero. Buscar por nombre de archivo
        entre las releases evita esa traduccion.
    #>
    param([string]$Version)

    $cabeceras = @{ 'User-Agent' = "AssassinSkipAdm/$KitVersion"; 'Accept' = 'application/vnd.github+json' }

    if ([string]::IsNullOrWhiteSpace($Version)) {
        $release = Invoke-JsonApi -Uri "$GitReleasesApi/latest" -Headers $cabeceras
        if (-not $release) { return $null }
        return Get-GitPortableAsset -Release $release
    }

    $buscada = $Version.Trim().TrimStart('v')
    $releases = Invoke-JsonApi -Uri "$GitReleasesApi`?per_page=30" -Headers $cabeceras
    if (-not $releases) { return $null }

    foreach ($r in $releases) {
        $a = Get-GitPortableAsset -Release $r
        if ($a -and $a.Version -eq $buscada) { return $a }
    }
    return $null
}

function ConvertFrom-GitVersionOutput {
    <#
        Convierte lo que escupe "git --version" en la version tal como se llama
        el archivo publicado:

            "git version 2.55.0.windows.5"  ->  "2.55.0.5"

        Existe porque tres sitios distintos parseaban esa cadena cada uno a su
        manera, y uno lo hacia mal: con [\d.]+ el cuantificador voraz se comia
        tambien el punto de ".windows", devolvia "2.55.0." y la parte
        ".windows.5" ya no encajaba en el grupo opcional. Se veia como
        "Git 2.55.0." en la lista de versiones instaladas.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Output)

    if ([string]::IsNullOrWhiteSpace($Output)) { return $null }

    if ($Output -match 'git version (\d+\.\d+\.\d+)\.windows\.(\d+)') {
        return "$($Matches[1]).$($Matches[2])"
    }
    # Un Git que no sea el de Windows no lleva el sufijo .windows.N.
    if ($Output -match 'git version (\d+(?:\.\d+)*)') {
        return $Matches[1]
    }
    return $null
}

function Get-GitLine {
    <#
        La "linea" de una version de Git: 2.55.0.5 -> 2.55, que es lo que da
        nombre a la carpeta git-2.55. Es la misma regla que para Maven y Gradle,
        asi que delega en Get-ToolLine en vez de repetirla; se conserva el
        nombre propio porque es como se lee en Setup-GitEnv.
    #>
    param([Parameter(Mandatory=$true)][string]$Version)
    return (Get-ToolLine -Version $Version)
}

function Write-GitShell {
    <#
        Shell de Git portable. Solo se pone cmd\ en el PATH, que es lo que hace
        tambien el instalador oficial en su opcion por defecto: bin\ trae bash,
        sh y otros que taparian los comandos del sistema con el mismo nombre.
        Para el entorno Unix completo esta git-bash.exe, que se anuncia abajo.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$GitPath,
        [Parameter(Mandatory=$true)][string]$Version
    )

    $cmdDir = ConvertTo-CmdLiteral (Join-Path $GitPath "cmd")
    $bash   = ConvertTo-CmdEchoText (Join-Path $GitPath "git-bash.exe")
    $linea  = (Get-GitLine -Version $Version) -replace '\.', ''

    $lines = @(
        "@echo off",
        "set `"PATH=$cmdDir;%PATH%`"",
        "title Git $Version Shell",
        "echo.",
        "echo ============================================",
        "echo   Git $Version Shell",
        "echo ============================================",
        "echo.",
        "git --version",
        "echo.",
        "echo Comandos:",
        "echo   git clone <url>     - Clonar un repositorio",
        "echo   git status          - Estado del repositorio",
        "echo.",
        "echo Para el entorno Unix completo (bash, ssh, grep):",
        "echo   $bash",
        "echo.",
        "echo Escribe exit para cerrar",
        "cmd /k"
    )

    $file = Join-Path $GitPath "git$linea-shell.bat"
    Set-Content -Path $file -Value ($lines -join "`n") -Encoding ASCII
    return $file
}

# --------------------------------------------------------------------------
# Maven y Gradle
#
# Los dos son lo mismo desde el punto de vista del kit: un zip que se
# descomprime, se pone su bin\ en el PATH y necesita un JDK para funcionar. Ni
# uno ni otro traen instalador, asi que aqui no hay nada que esquivar: es el
# camino oficial y no pide admin.
# --------------------------------------------------------------------------

$MavenBaseUrl  = "https://dlcdn.apache.org/maven/maven-3/"
$GradleVersionApi = "https://services.gradle.org/versions/current"
$GradleAllVersionsApi = "https://services.gradle.org/versions/all"

function Get-MavenRelease {
    <#
        Devuelve la version de Maven a instalar, su zip y su SHA-512.

        Apache no tiene una API: se lee el listado de directorio de dlcdn y se
        coge la version mas alta. Y publica SHA-512, no SHA-256, que es la razon
        de que Invoke-Download admita los dos.

        Admite tambien una LINEA ("3.9") y devuelve su ultimo parche. Hacia
        falta porque el devenv.json anota la linea, igual que hace con Python:
        pedir "3.9" componia la URL de una version que no existe y Restore-Env
        no podia reinstalar Maven, solo daba un 404.
    #>
    param([string]$Version)

    $elegida = $Version
    $linea   = if ($Version -match '^\d+\.\d+$') { $Version } else { $null }

    if ([string]::IsNullOrWhiteSpace($elegida) -or $linea) {
        $html = Get-WebText -Uri $MavenBaseUrl -Quiet
        if (-not $html) { return $null }

        $vs = @([regex]::Matches($html, 'href="(\d+\.\d+\.\d+)/"') |
                ForEach-Object { $_.Groups[1].Value } |
                Where-Object { -not $linea -or $_ -like "$linea.*" } |
                Sort-Object { [version]$_ } -Descending)
        if ($vs.Count -eq 0) { return $null }
        $elegida = $vs[0]
    }

    $zip = "apache-maven-$elegida-bin.zip"
    $url = "$MavenBaseUrl$elegida/binaries/$zip"

    $sha = Get-HashFromChecksumText -Text (Get-WebText -Uri "$url.sha512" -Quiet) -Algorithm SHA512

    return [PSCustomObject]@{
        Version  = $elegida
        FileName = $zip
        Url      = $url
        Sha512   = $sha
        # La carpeta que el zip trae dentro.
        Inner    = "apache-maven-$elegida"
    }
}

function Get-GradleRelease {
    <#
        Gradle si publica una API con la version actual, su zip y su checksum.
        Para una version concreta se componen las URL, que siguen un patron fijo.

        Una LINEA ("9.7") se resuelve a su ultimo parche consultando el listado
        completo. Aqui no bastaba con componer la URL como con una version
        exacta: Gradle publica tanto 9.7 como 9.7.1, asi que pedir la linea
        habria instalado el primer parche en vez del ultimo, en silencio. Es lo
        que anota el devenv.json, de modo que sin esto Restore-Env reproducia
        una version distinta de la que se guardo.
    #>
    param([string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) {
        $api = Invoke-JsonApi -Uri $GradleVersionApi -Quiet
        if (-not $api -or [string]::IsNullOrWhiteSpace($api.version)) { return $null }
        $elegida = $api.version
        $url     = $api.downloadUrl
        $shaUrl  = $api.checksumUrl
    }
    else {
        $elegida = $Version.Trim()

        if ($elegida -match '^\d+\.\d+$') {
            $todas = Invoke-JsonApi -Uri $GradleAllVersionsApi -Quiet
            if (-not $todas) { return $null }

            # Fuera los candidatos y los rotos: un manifiesto pide una version
            # publicada, no una release candidate.
            $enLinea = @($todas |
                Where-Object { -not $_.snapshot -and -not $_.broken -and -not $_.rcFor -and -not $_.milestoneFor } |
                ForEach-Object { [string]$_.version } |
                Where-Object { $_ -eq $elegida -or $_ -like "$elegida.*" } |
                Sort-Object { try { [version]$_ } catch { [version]'0.0' } } -Descending)

            if ($enLinea.Count -eq 0) { return $null }
            $elegida = $enLinea[0]
        }

        $url     = "https://services.gradle.org/distributions/gradle-$elegida-bin.zip"
        $shaUrl  = "$url.sha256"
    }

    $sha = Get-HashFromChecksumText -Text (Get-WebText -Uri $shaUrl -Quiet) -Algorithm SHA256

    return [PSCustomObject]@{
        Version  = $elegida
        FileName = "gradle-$elegida-bin.zip"
        Url      = $url
        Sha256   = $sha
        Inner    = "gradle-$elegida"
    }
}

function Get-JdkVersionAt {
    <#
        Devuelve la version del JDK que hay en una carpeta, o $null.

        Se lee del archivo "release" que todo JDK trae en su raiz, en vez de
        ejecutar java.exe: es instantaneo, no arranca una JVM y funciona aunque
        ese JDK este roto. Solo se recurre al binario si no hay release.

        El parametro se llama JavaHome y no Home: $Home es una variable
        automatica de PowerShell -la carpeta del usuario- y declararla como
        parametro rompe la funcion entera.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyString()][AllowNull()][string]$JavaHome)

    if ([string]::IsNullOrWhiteSpace($JavaHome)) { return $null }
    $raiz = [Environment]::ExpandEnvironmentVariables($JavaHome)
    if (-not (Test-Path -LiteralPath $raiz)) { return $null }

    $release = Join-Path $raiz "release"
    if (Test-Path -LiteralPath $release) {
        foreach ($l in (Get-Content -LiteralPath $release -ErrorAction SilentlyContinue)) {
            if ($l -match '^JAVA_VERSION\s*=\s*"?([^"]+)"?') { return $Matches[1].Trim() }
        }
    }

    $exe = Join-Path $raiz "bin\java.exe"
    if (Test-Path -LiteralPath $exe) {
        $run = Invoke-NativeCommand -FilePath $exe -Arguments @('-version') -Quiet
        if ($run.Output -match 'version "([^"]+)"') { return $Matches[1] }
    }
    return $null
}

function Get-JavaMajor {
    <#
        La version mayor de un Java, normalizando el esquema antiguo: "1.8.0_202"
        es Java 8, no Java 1. Sin esto, comparar versiones daria que Java 8 es
        mas nuevo que Java 25.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) { return $null }
    if ($Version -match '^1\.(\d+)') { return [int]$Matches[1] }
    if ($Version -match '^(\d+)')    { return [int]$Matches[1] }
    return $null
}

function Resolve-KitJdk {
    <#
        Devuelve la ruta del JDK del kit que se le pida por su linea ("21"), o
        $null si no esta instalado. Sin -Linea devuelve el mas alto, que es lo
        que hacia Get-KitJavaHome y sigue siendo el valor por defecto.
    #>
    param([string]$Linea)

    if ([string]::IsNullOrWhiteSpace($Linea)) { return (Get-KitJavaHome) }

    $ruta = Join-Path (Join-Path $WorkspaceRoot "Java") ("jdk-" + $Linea.Trim())
    if (Test-Path (Join-Path $ruta "bin\java.exe")) { return $ruta }
    return $null
}

function Get-KitJdkLines {
    <#
        Las lineas de JDK del kit instaladas, de menor a mayor.

        No es Get-InstalledRuntimeLines con la entrada de Java porque aqui hacen
        falta dos cosas mas: exigir bin\java.exe -una carpeta a medio borrar daria
        un shell con un JAVA_HOME roto- y ordenar por NUMERO, ya que como texto
        "21" iria antes que "8" y "el mas alto" acabaria siendo el Java 8.
    #>
    $javaRoot = Join-Path $WorkspaceRoot "Java"
    if (-not (Test-Path -LiteralPath $javaRoot)) { return @() }

    return @(Get-ChildItem -LiteralPath $javaRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^jdk-(\d+)$' -and (Test-Path (Join-Path $_.FullName "bin\java.exe")) } |
        ForEach-Object { $_.Name -replace '^jdk-', '' } |
        Sort-Object { [int]$_ })
}

function Get-KitJavaHome {
    <#
        Devuelve el JDK del kit que deben usar Maven y Gradle, o $null.

        Se prefiere el JDK del kit al JAVA_HOME del sistema a proposito: si hay
        uno instalado por el kit es el que el usuario controla, y es el que va a
        seguir ahi. Se coge el de version mas alta.
    #>
    $lineas = @(Get-KitJdkLines)
    if ($lineas.Count -eq 0) { return $null }

    # Get-KitJdkLines ordena de menor a mayor.
    return (Join-Path (Join-Path $WorkspaceRoot "Java") ("jdk-" + $lineas[-1]))
}

function Write-BuildToolShell {
    <#
        Shell de Maven o de Gradle. Los dos necesitan lo mismo: su bin\ en el
        PATH y un JAVA_HOME que apunte a un JDK, porque ninguno de los dos trae
        Java dentro y sin esa variable no arrancan.

        Si hay un JDK del kit se usa ese; si no, se deja el JAVA_HOME que ya
        hubiera y el shell avisa cuando no hay ninguno, en vez de fallar con un
        error de Java que no dice de que va.

        Con -SufijoJdk se escribe un shell APARTE atado a un JDK concreto
        (mvn39-java21-shell.bat). Existe porque con varios JDK instalados el
        shell normal se queda con el mas alto, y quien trabaja a diario con
        proyectos que piden Javas distintos necesitaba reejecutar el Setup para
        cambiar. Con uno por JDK, se abre el que toque.
    #>
    param(
        [Parameter(Mandatory=$true)][ValidateSet('Maven', 'Gradle')][string]$Tool,
        [Parameter(Mandatory=$true)][string]$ToolPath,
        [Parameter(Mandatory=$true)][string]$Version,
        [string]$JavaHome,
        [string]$SufijoJdk
    )

    $binCmd = ConvertTo-CmdLiteral (Join-Path $ToolPath "bin")
    $exe    = if ($Tool -eq 'Maven') { 'mvn' } else { 'gradle' }
    $linea  = (Get-ToolLine -Version $Version) -replace '\.', ''

    $lines = @(
        "@echo off",
        "set `"PATH=$binCmd;%PATH%`""
    )

    if ($JavaHome) {
        $lines += "set `"JAVA_HOME=$(ConvertTo-CmdLiteral $JavaHome)`""
        $lines += "set `"PATH=$(ConvertTo-CmdLiteral (Join-Path $JavaHome 'bin'));%PATH%`""
    }

    $titulo = if ($SufijoJdk) { "$Tool $Version  (Java $SufijoJdk)" } else { "$Tool $Version Shell" }
    $lines += @(
        "title $titulo",
        "echo.",
        "echo ============================================",
        "echo   $titulo",
        "echo ============================================",
        "echo."
    )

    if (-not $JavaHome) {
        $lines += @(
            "if not defined JAVA_HOME (",
            "    echo AVISO: no hay JAVA_HOME y $exe no arranca sin un JDK.",
            "    echo   Instala uno con:  Setup-JavaEnv.bat",
            "    echo.",
            ")"
        )
    }

    $lines += @(
        "$exe -version",
        "echo.",
        "echo Escribe exit para cerrar",
        "cmd /k"
    )

    $nombre = if ($SufijoJdk) { "$($exe)$linea-java$SufijoJdk-shell.bat" } else { "$($exe)$linea-shell.bat" }
    $file = Join-Path $ToolPath $nombre
    Set-Content -Path $file -Value ($lines -join "`n") -Encoding ASCII
    return $file
}

function Write-BuildToolShellsPorJdk {
    <#
        Escribe un shell de la herramienta por CADA JDK del kit instalado, ademas
        del de siempre.

        Solo tiene sentido con mas de un JDK: con uno, el shell normal ya apunta
        ahi y un segundo archivo identico solo confundiria.

        Tambien borra los shells de JDK que ya no estan, para que no queden
        apuntando a una carpeta desinstalada.

        Devuelve { Escritos = rutas; Borrados = cuantos se retiraron }.
    #>
    param(
        [Parameter(Mandatory=$true)][ValidateSet('Maven', 'Gradle')][string]$Tool,
        [Parameter(Mandatory=$true)][string]$ToolPath,
        [Parameter(Mandatory=$true)][string]$Version
    )

    $exe    = if ($Tool -eq 'Maven') { 'mvn' } else { 'gradle' }
    $lineas = @(Get-KitJdkLines)
    if ($lineas.Count -lt 2) { $lineas = @() }

    # Fuera los que sobran antes de escribir: si se desinstalo un JDK, su shell
    # ya no lleva a ningun sitio.
    $borrados = 0
    Get-ChildItem -LiteralPath $ToolPath -Filter "$exe*-java*-shell.bat" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '-java(\d+)-shell\.bat$' -and $lineas -notcontains $Matches[1] } |
        ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            $borrados++
        }

    $escritos = @()
    foreach ($l in $lineas) {
        $escritos += (Write-BuildToolShell -Tool $Tool -ToolPath $ToolPath -Version $Version `
                                           -JavaHome (Join-Path (Join-Path $WorkspaceRoot "Java") "jdk-$l") `
                                           -SufijoJdk $l)
    }

    return [PSCustomObject]@{
        Escritos = $escritos
        Borrados = $borrados
    }
}

function Get-ShellJavaHome {
    <#
        Que JAVA_HOME exporta un shell generado, o cadena vacia si no exporta
        ninguno.
    #>
    param([Parameter(Mandatory=$true)][string]$ShellBat)

    if (-not (Test-Path -LiteralPath $ShellBat)) { return '' }
    return ([regex]::Match((Get-Content -LiteralPath $ShellBat -Raw), 'set "JAVA_HOME=([^"]+)"')).Groups[1].Value
}

function Get-VSCodeSettingsTargets {
    <#
        Donde vive el settings.json de cada VS Code que haya en la maquina.

        Son dos sitios distintos y no uno: el VS Code portable del kit guarda
        sus ajustes dentro de su propia carpeta data\, y el que se instala por
        usuario -sin admin, el habitual- los guarda en %APPDATA%\Code. Registrar
        los JDK en el que no se usa no serviria de nada, asi que se buscan los
        dos y se dice cual es cual.

        Devuelve tambien los que aun no tienen settings.json: el archivo se crea
        la primera vez que se cambia un ajuste, y no tenerlo no significa que ese
        VS Code no exista.
    #>
    $targets = @()

    # 1. El portable del kit, una carpeta data\ por version.
    $vscodeRoot = Join-Path $WorkspaceRoot "VSCode"
    if (Test-Path -LiteralPath $vscodeRoot) {
        foreach ($d in @(Get-ChildItem -LiteralPath $vscodeRoot -Directory -ErrorAction SilentlyContinue)) {
            if ($d.Name -notmatch '^vscode-(\d+\.\d+)$') { continue }
            if (-not (Test-Path (Join-Path $d.FullName "Code.exe"))) { continue }

            $targets += [PSCustomObject]@{
                # Corta a proposito: Doctor la imprime en una columna de 26.
                Etiqueta = "VS Code $($Matches[1]) del kit"
                Ruta     = Join-Path $d.FullName "data\user-data\User\settings.json"
                DelKit   = $true
            }
        }
    }

    # 2. El instalado por usuario. Se comprueba el ejecutable y no solo la
    # carpeta de ajustes: %APPDATA%\Code sobrevive a una desinstalacion.
    $exe = Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code\Code.exe"
    $sys = "C:\Program Files\Microsoft VS Code\Code.exe"
    if ((Test-Path -LiteralPath $exe) -or (Test-Path -LiteralPath $sys)) {
        $targets += [PSCustomObject]@{
            Etiqueta = "VS Code del equipo"
            Ruta     = Join-Path $env:APPDATA "Code\User\settings.json"
            DelKit   = $false
        }
    }

    return $targets
}

function Get-KitJavaRuntimeEntries {
    <#
        Las entradas de java.configuration.runtimes que describen los JDK del
        kit. Es el ajuste con el que la extension de Java elige un JDK POR
        PROYECTO, segun el nivel que declare cada uno, sin tocar los proyectos.

        El nombre no es libre: la extension espera el identificador oficial de la
        plataforma, y el Java 8 se llama JavaSE-1.8 y no JavaSE-8.
    #>
    param([string]$Default)

    $entradas = @()
    $javaRoot = Join-Path $WorkspaceRoot "Java"

    foreach ($l in @(Get-KitJdkLines)) {
        $nombre = if ($l -eq '8') { 'JavaSE-1.8' } else { "JavaSE-$l" }
        $e = [ordered]@{
            name = $nombre
            path = (Join-Path $javaRoot "jdk-$l")
        }
        if ($Default -and $l -eq $Default) { $e['default'] = $true }
        $entradas += [PSCustomObject]$e
    }

    return $entradas
}

function Merge-VSCodeJavaRuntimes {
    <#
        Mezcla las entradas del kit con las que ya hubiera en settings.json.

        Las de fuera del kit se CONSERVAN: quien tenga registrado a mano el JDK
        de la empresa no puede perderlo por ejecutar esto. Solo se reemplazan las
        que apuntan dentro de la carpeta Java del kit, que son las nuestras.

        Si el kit pone un default, se le quita a las conservadas: la extension
        admite un unico runtime por defecto y dos lo dejarian en un estado que
        no se puede predecir.

        Con -Quitar se van las del kit y se quedan solo las ajenas.
    #>
    param(
        [AllowNull()]$Actual,
        [AllowNull()]$DelKit,
        [Parameter(Mandatory=$true)][string]$RaizJava,
        [switch]$Quitar
    )

    $raiz = $RaizJava.TrimEnd('\')
    $ajenas = @(@($Actual) | Where-Object { $_ -and $_.path } | Where-Object {
        $p = ([string]$_.path).TrimEnd('\')
        -not ($p -ieq $raiz -or $p.StartsWith($raiz + '\', [StringComparison]::OrdinalIgnoreCase))
    })

    if ($Quitar) { return @($ajenas) }

    $nuevas = @($DelKit)
    $hayDefaultDelKit = @($nuevas | Where-Object { $_.default }).Count -gt 0

    if ($hayDefaultDelKit) {
        $ajenas = @($ajenas | ForEach-Object {
            $copia = [ordered]@{}
            foreach ($p in $_.PSObject.Properties) {
                if ($p.Name -ne 'default') { $copia[$p.Name] = $p.Value }
            }
            [PSCustomObject]$copia
        })
    }

    return @($ajenas + $nuevas)
}

function Get-BuildToolJavaBindings {
    <#
        A que linea de JDK del kit apunta hoy el shell por defecto de cada
        herramienta: @{ maven = '21'; gradle = '25' }.

        Se lee del shell y no se deduce del catalogo porque es el dato real: es
        ese JAVA_HOME el que decide con que Java compilan. Solo se devuelven los
        que apuntan a un JDK del kit; uno de fuera no lo sabria reproducir
        Restore-Env en otra maquina.
    #>
    $bindings = [ordered]@{}
    $javaRoot = (Join-Path $WorkspaceRoot "Java").TrimEnd('\')

    foreach ($t in @(
        @{ Clave = 'maven';  Root = 'Maven';  Exe = 'mvn';    Jar = 'lib\maven-core-*.jar';      Rx = 'maven-core-([\d.]+)\.jar' },
        @{ Clave = 'gradle'; Root = 'Gradle'; Exe = 'gradle'; Jar = 'lib\gradle-launcher-*.jar'; Rx = 'gradle-launcher-([\d.]+)\.jar' }
    )) {
        $root = Join-Path $WorkspaceRoot $t.Root
        if (-not (Test-Path -LiteralPath $root)) { continue }

        foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            $jars = @(Get-ChildItem -Path (Join-Path $d.FullName $t.Jar) -ErrorAction SilentlyContinue)
            if ($jars.Count -eq 0 -or $jars[0].Name -notmatch $t.Rx) { continue }

            $shell = Join-Path $d.FullName "$($t.Exe)$((Get-ToolLine -Version $Matches[1]) -replace '\.','')-shell.bat"
            $jh = Get-ShellJavaHome -ShellBat $shell
            if (-not $jh) { continue }

            $padre = Split-Path -Parent $jh.TrimEnd('\')
            if ($padre.TrimEnd('\') -ine $javaRoot) { continue }
            if ((Split-Path -Leaf $jh) -match '^jdk-(\d+)$') { $bindings[$t.Clave] = $Matches[1] }
        }
    }

    return $bindings
}

function Sync-BuildToolShells {
    <#
        Repasa los shells por JDK de Maven y Gradle contra los JDK que hay ahora.

        Se llama despues de instalar o desinstalar un JDK: si no, instalar Java
        21 despues de Maven no daria shell para el 21, y habria que reejecutar el
        Setup de Maven a mano.

        Ademas rescata el shell por defecto si su JAVA_HOME se quedo apuntando a
        un JDK borrado: no hacerlo deja la herramienta rota hasta que alguien
        reejecute su Setup, y el error que da Java no menciona nada de esto.

        Devuelve una linea por herramienta tocada; nada si no hay ninguna.
    #>
    $resumen = @()

    foreach ($t in @(
        @{ Tool = 'Maven';  Root = 'Maven';  Exe = 'mvn';    Marca = 'bin\mvn.cmd';    Jar = 'lib\maven-core-*.jar';      Rx = 'maven-core-([\d.]+)\.jar' },
        @{ Tool = 'Gradle'; Root = 'Gradle'; Exe = 'gradle'; Marca = 'bin\gradle.bat'; Jar = 'lib\gradle-launcher-*.jar'; Rx = 'gradle-launcher-([\d.]+)\.jar' }
    )) {
        $root = Join-Path $WorkspaceRoot $t.Root
        if (-not (Test-Path -LiteralPath $root)) { continue }

        foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            if (-not (Test-Path (Join-Path $d.FullName $t.Marca))) { continue }

            # La version sale del jar y no de ejecutar la herramienta: gradle y
            # mvn necesitan JAVA_HOME, que aqui puede no estar puesto.
            $jars = @(Get-ChildItem -Path (Join-Path $d.FullName $t.Jar) -ErrorAction SilentlyContinue)
            if ($jars.Count -eq 0 -or $jars[0].Name -notmatch $t.Rx) { continue }
            $version = $Matches[1]

            $hechos = Write-BuildToolShellsPorJdk -Tool $t.Tool -ToolPath $d.FullName -Version $version
            if ($hechos.Escritos.Count -gt 0) {
                $resumen += "$($t.Tool) $version : $($hechos.Escritos.Count) shells, uno por JDK"
            }
            elseif ($hechos.Borrados -gt 0) {
                $resumen += "$($t.Tool) $version : retirados $($hechos.Borrados) shells de JDK que ya no estan"
            }

            # El shell por defecto atado a un JDK que ya no existe.
            $porDefecto = Join-Path $d.FullName "$($t.Exe)$((Get-ToolLine -Version $version) -replace '\.','')-shell.bat"
            $jh = Get-ShellJavaHome -ShellBat $porDefecto
            if ($jh -and -not (Test-Path -LiteralPath $jh)) {
                $nuevo = Get-KitJavaHome
                Write-BuildToolShell -Tool $t.Tool -ToolPath $d.FullName -Version $version -JavaHome $nuevo | Out-Null
                $resumen += if ($nuevo) {
                    "$($t.Tool) $version : el shell apuntaba a $(Split-Path -Leaf $jh), ahora a $(Split-Path -Leaf $nuevo)"
                } else {
                    "$($t.Tool) $version : el shell apuntaba a $(Split-Path -Leaf $jh), que ya no esta; queda sin JDK"
                }
            }
        }
    }

    return $resumen
}

function Get-ToolLine {
    <#
        La "linea" de una version: 3.9.16 -> 3.9, 9.7.1 -> 9.7. Da nombre a la
        carpeta, igual que en python-3.12 y git-2.55: una carpeta por linea, y
        -Force actualiza el parche dentro.
    #>
    param([Parameter(Mandatory=$true)][string]$Version)

    $p = $Version.TrimStart('v').Split('.')
    if ($p.Count -lt 2) { return $p[0] }
    return "$($p[0]).$($p[1])"
}

# --------------------------------------------------------------------------
# .NET SDK
#
# Es el caso mas facil de todos: Microsoft publica dotnet-install.ps1, un script
# pensado EXPRESAMENTE para instalar sin admin y en la carpeta que le digas. No
# hay nada que esquivar; solo hay que llamarlo bien y pasarle el proxy.
# --------------------------------------------------------------------------

$DotnetIndexUrl   = "https://builds.dotnet.microsoft.com/dotnet/release-metadata/releases-index.json"
$DotnetInstallUrl = "https://dot.net/v1/dotnet-install.ps1"

function Get-DotnetRelease {
    <#
        Devuelve el canal de .NET a instalar y la version exacta de su SDK.

        Sin -Channel se coge el LTS activo mas alto: es lo que quiere quien no
        tiene una preferencia. Los canales fuera de soporte se descartan, para no
        instalar algo que ya no recibe parches de seguridad.
    #>
    param([string]$Channel)

    $idx = Invoke-JsonApi -Uri $DotnetIndexUrl -Quiet
    if (-not $idx -or -not $idx.'releases-index') { return $null }

    $todos = @($idx.'releases-index' | Where-Object { $_.'latest-sdk' })

    if (-not [string]::IsNullOrWhiteSpace($Channel)) {
        $c = @($todos | Where-Object { $_.'channel-version' -eq $Channel.Trim() })
        if ($c.Count -eq 0) { return $null }
        $elegido = $c[0]
    }
    else {
        $vivos = @($todos | Where-Object { $_.'support-phase' -in @('active', 'maintenance') })
        $lts   = @($vivos | Where-Object { $_.'release-type' -eq 'lts' } |
                   Sort-Object { [version]$_.'channel-version' } -Descending)
        if ($lts.Count -gt 0) { $elegido = $lts[0] }
        elseif ($vivos.Count -gt 0) {
            $elegido = @($vivos | Sort-Object { [version]$_.'channel-version' } -Descending)[0]
        }
        else { return $null }
    }

    return [PSCustomObject]@{
        Channel    = $elegido.'channel-version'
        SdkVersion = $elegido.'latest-sdk'
        Tipo       = $elegido.'release-type'
        Soporte    = $elegido.'support-phase'
        Eol        = $elegido.'eol-date'
    }
}

function Write-DotnetShell {
    <#
        Shell del SDK de .NET. Ademas del PATH define DOTNET_ROOT.

        Comprobado: dotnet.exe SI localiza su propio SDK por la ubicacion del
        ejecutable, asi que compilar y ejecutar funciona sin esa variable. Lo que
        DOTNET_ROOT resuelve es lo otro: las herramientas globales y las
        aplicaciones ya publicadas la leen para saber que runtime usar, y en un
        equipo con un .NET instalado por admin en Program Files -lo normal- sin
        ella pueden acabar resolviendo al del sistema en vez de a este. Se pone
        para que el shell no deje esa ambiguedad.

        DOTNET_CLI_TELEMETRY_OPTOUT se pone a 1 porque este kit existe para
        equipos corporativos vigilados, donde una herramienta que llama a casa
        sin avisar es justo lo que no se quiere.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$DotnetPath,
        [Parameter(Mandatory=$true)][string]$Version,
        [Parameter(Mandatory=$true)][string]$Channel
    )

    $raiz  = ConvertTo-CmdLiteral $DotnetPath
    $linea = $Channel -replace '\.', ''

    $lines = @(
        "@echo off",
        "set `"PATH=$raiz;%PATH%`"",
        "set `"DOTNET_ROOT=$raiz`"",
        "set `"DOTNET_CLI_TELEMETRY_OPTOUT=1`"",
        "title .NET $Version Shell",
        "echo.",
        "echo ============================================",
        "echo   .NET SDK $Version Shell",
        "echo ============================================",
        "echo.",
        "dotnet --version",
        "echo.",
        "echo Comandos:",
        "echo   dotnet new console  - Crear un proyecto",
        "echo   dotnet build        - Compilar",
        "echo   dotnet run          - Ejecutar",
        "echo.",
        "echo Escribe exit para cerrar",
        "cmd /k"
    )

    $file = Join-Path $DotnetPath "dotnet$linea-shell.bat"
    Set-Content -Path $file -Value ($lines -join "`n") -Encoding ASCII
    return $file
}

# --------------------------------------------------------------------------
# Visual Studio Code portable
#
# El instalador normal de VS Code -el "System Installer"- pide admin. Pero
# Microsoft publica ademas el .zip, y ese admite MODO PORTABLE oficial: basta
# con crear una carpeta "data" junto al ejecutable y VS Code guarda ahi sus
# ajustes y extensiones en vez de en %APPDATA%. Sin registro y sin admin.
# --------------------------------------------------------------------------

$VSCodeUpdateApi = "https://update.code.visualstudio.com/api/update/win32-x64-archive/stable/latest"

function Get-VSCodeRelease {
    <#
        Devuelve la version, el zip y su SHA-256, que la API de actualizacion de
        VS Code da los tres de una vez. Se pide el canal "archive": el otro es el
        instalador, que es justo el que pide admin.
    #>
    param([string]$Version)

    # Con una version concreta no se usa la API de actualizacion -que solo sabe
    # de la ultima- sino la ruta por version, que redirige al zip. Comprobado
    # con 1.134.0 y 1.135.0. A cambio no hay checksum publicado: se descarga sin
    # el y se dice, en vez de fingir que se verifico.
    if (-not [string]::IsNullOrWhiteSpace($Version)) {
        $v = $Version.Trim()
        return [PSCustomObject]@{
            Version  = $v
            Url      = "https://update.code.visualstudio.com/$v/win32-x64-archive/stable"
            Sha256   = $null
            FileName = "VSCode-win32-x64-$v.zip"
        }
    }

    $api = Invoke-JsonApi -Uri $VSCodeUpdateApi -Quiet
    if (-not $api -or [string]::IsNullOrWhiteSpace($api.url)) { return $null }

    $version = if ($api.productVersion) { $api.productVersion } else { $api.name }

    return [PSCustomObject]@{
        Version  = $version
        Url      = $api.url
        Sha256   = $api.sha256hash
        FileName = "VSCode-win32-x64-$version.zip"
    }
}

function Write-VSCodeShell {
    <#
        Shell de VS Code. Pone bin\ en el PATH, que es donde vive code.cmd, el
        lanzador de linea de comandos.

        VSCODE_PORTABLE se fija ademas de crear la carpeta data\: la carpeta sola
        ya activa el modo portable al arrancar desde ahi, pero la variable lo
        deja explicito para cualquier proceso que se lance desde este shell.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$VSCodePath,
        [Parameter(Mandatory=$true)][string]$Version
    )

    $binCmd  = ConvertTo-CmdLiteral (Join-Path $VSCodePath "bin")
    $dataCmd = ConvertTo-CmdLiteral (Join-Path $VSCodePath "data")
    $exeTxt  = ConvertTo-CmdEchoText (Join-Path $VSCodePath "Code.exe")
    $linea   = (Get-ToolLine -Version $Version) -replace '\.', ''

    $lines = @(
        "@echo off",
        "set `"PATH=$binCmd;%PATH%`"",
        "set `"VSCODE_PORTABLE=$dataCmd`"",
        "title VS Code $Version Shell",
        "echo.",
        "echo ============================================",
        "echo   VS Code $Version (portable)",
        "echo ============================================",
        "echo.",
        "echo Ajustes y extensiones viven en data\, no en tu perfil.",
        "echo.",
        "echo Comandos:",
        "echo   code .              - Abrir la carpeta actual",
        "echo   code archivo.txt    - Abrir un archivo",
        "echo   $exeTxt",
        "echo.",
        "echo Escribe exit para cerrar",
        "cmd /k"
    )

    $file = Join-Path $VSCodePath "code$linea-shell.bat"
    Set-Content -Path $file -Value ($lines -join "`n") -Encoding ASCII
    return $file
}

# --------------------------------------------------------------------------
# Catalogo de runtimes
#
# Un solo sitio que sepa, para cada runtime: como se llama en un devenv.json,
# que script lo instala, con que parametro se le pasa la version, donde
# aterriza y como se llama su carpeta. Antes cada comando llevaba su propia
# lista y cada runtime nuevo obligaba a tocarlas todas.
# --------------------------------------------------------------------------

function Get-RuntimeCatalog {
    <#
        Fijable indica si el Setup de ese runtime acepta una version EXACTA o
        solo su linea. Es lo que decide hasta donde puede fijar un lockfile, y
        no es una eleccion nuestra sino una limitacion de cada script:

          python, node, git, maven, gradle   admiten X.Y.Z  -> exacto
          java, angular                      -Version es un entero: solo la mayor
          dotnet                             -Channel: solo el canal
          vscode                             no tiene parametro: siempre la ultima
    #>
    return @(
        [PSCustomObject]@{
            Clave = 'python'; Nombre = 'Python'; Script = 'Setup-PythonEnv.ps1'
            ParamVersion = 'PythonVersion'; ParamPaquetes = 'InstallPackages'
            Carpeta = 'Python'; Patron = '^python-(\d+\.\d+)$'; AdmiteForce = $true
            ExeFirma = 'python.exe';   FirmanteEsperado = 'Python Software Foundation'
            Bundle = $false
            Fijable = $true
        }
        [PSCustomObject]@{
            Clave = 'java'; Nombre = 'Java'; Script = 'Setup-JavaEnv.ps1'
            ParamVersion = 'JavaVersion'; ParamPaquetes = $null
            Carpeta = 'Java'; Patron = '^jdk-(\d+)$'; AdmiteForce = $true
            # Temurin ha firmado con dos nombres distintos segun la epoca: el
            # JDK 25 sale como "Eclipse Foundation" y el 21 como "Eclipse.org
            # Foundation, Inc.". Por eso el firmante esperado admite varias
            # formas: con una sola, un JDK legitimo se marcaba como suplantado.
            ExeFirma = 'bin\java.exe'; FirmanteEsperado = @('Eclipse Foundation', 'Eclipse.org Foundation')
            Bundle = $false
            Fijable = $true
        }
        [PSCustomObject]@{
            Clave = 'node'; Nombre = 'Node'; Script = 'Setup-NodeEnv.ps1'
            ParamVersion = 'NodeVersion'; ParamPaquetes = $null
            Carpeta = 'Node'; Patron = '^node-(\d+)$'; AdmiteForce = $true
            ExeFirma = 'node.exe';     FirmanteEsperado = 'OpenJS Foundation'
            Bundle = $true; Envoltorio = $true;  Sfx = $false
            Fijable = $true
        }
        [PSCustomObject]@{
            Clave = 'angular'; Nombre = 'Angular'; Script = 'Setup-AngularEnv.ps1'
            ParamVersion = 'AngularVersion'; ParamPaquetes = $null
            Carpeta = 'Angular'; Patron = '^angular-v(\d+)$'; AdmiteForce = $false
            ExeFirma = $null;           FirmanteEsperado = $null
            Bundle = $false
            Fijable = $true
        }
        [PSCustomObject]@{
            Clave = 'git'; Nombre = 'Git'; Script = 'Setup-GitEnv.ps1'
            ParamVersion = 'GitVersion'; ParamPaquetes = $null
            Carpeta = 'Git'; Patron = '^git-(\d+\.\d+)$'; AdmiteForce = $true
            ExeFirma = 'cmd\git.exe';  FirmanteEsperado = 'Johannes Schindelin'
            Bundle = $true; Envoltorio = $false; Sfx = $true
            Fijable = $true
        }
        [PSCustomObject]@{
            Clave = 'maven'; Nombre = 'Maven'; Script = 'Setup-MavenEnv.ps1'
            ParamVersion = 'MavenVersion'; ParamPaquetes = $null; ParamJava = 'JavaVersion'
            Carpeta = 'Maven'; Patron = '^maven-(\d+\.\d+)$'; AdmiteForce = $true
            ExeFirma = $null;           FirmanteEsperado = $null
            Bundle = $true; Envoltorio = $true;  Sfx = $false
            Fijable = $true
        }
        [PSCustomObject]@{
            Clave = 'gradle'; Nombre = 'Gradle'; Script = 'Setup-GradleEnv.ps1'
            ParamVersion = 'GradleVersion'; ParamPaquetes = $null; ParamJava = 'JavaVersion'
            Carpeta = 'Gradle'; Patron = '^gradle-(\d+\.\d+)$'; AdmiteForce = $true
            ExeFirma = $null;           FirmanteEsperado = $null
            Bundle = $true; Envoltorio = $true;  Sfx = $false
            Fijable = $true
        }
        [PSCustomObject]@{
            Clave = 'dotnet'; Nombre = '.NET SDK'; Script = 'Setup-DotnetEnv.ps1'
            ParamVersion = 'Channel'; ParamPaquetes = $null
            Carpeta = 'Dotnet'; Patron = '^dotnet-(\d+\.\d+)$'; AdmiteForce = $true
            ExeFirma = 'dotnet.exe';   FirmanteEsperado = '.NET'
            Bundle = $true; Envoltorio = $false; Sfx = $false
            Fijable = $true
        }
        [PSCustomObject]@{
            Clave = 'vscode'; Nombre = 'VS Code'; Script = 'Setup-VSCodeEnv.ps1'
            ParamVersion = 'VSCodeVersion'; ParamPaquetes = $null
            Carpeta = 'VSCode'; Patron = '^vscode-(\d+\.\d+)$'; AdmiteForce = $true
            ExeFirma = 'Code.exe';     FirmanteEsperado = 'Microsoft Corporation'
            Bundle = $true; Envoltorio = $false; Sfx = $false
            Fijable = $true
        }
    )
}

function Get-BundleArchiveInfo {
    <#
    .SYNOPSIS
        El archivo original de un runtime: URL, nombre y checksum si lo hay.
    .DESCRIPTION
        Lo usa Export-Env para meter en el bundle lo mismo que descargaria el
        Setup, de modo que en destino se instale sin red. Los setups borran el
        archivo tras extraerlo, asi que hay que volver a pedirlo.

        Angular, Python y Java NO pasan por aqui: tienen en Export-Env un
        tratamiento propio porque llevan ademas el arbol de npm-global y las
        ruedas de pip.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Clave,
        [Parameter(Mandatory=$true)][string]$Version
    )

    switch ($Clave) {
        'node' {
            $a = Get-NodeArchiveInfo -Version $Version
            return [PSCustomObject]@{
                Url = $a.Url; FileName = $a.FileName
                Sha256 = (Get-Sha256FromShasums -Uri $a.ShasumsUrl -FileName $a.FileName)
            }
        }
        'git' {
            $r = Get-GitPortableRelease -Version $Version
            if (-not $r) { return $null }
            return [PSCustomObject]@{ Url = $r.Url; FileName = $r.FileName; Sha256 = $r.Sha256 }
        }
        'maven' {
            $r = Get-MavenRelease -Version $Version
            if (-not $r) { return $null }
            return [PSCustomObject]@{ Url = $r.Url; FileName = $r.FileName; Sha512 = $r.Sha512 }
        }
        'gradle' {
            $r = Get-GradleRelease -Version $Version
            if (-not $r) { return $null }
            return [PSCustomObject]@{ Url = $r.Url; FileName = $r.FileName; Sha256 = $r.Sha256 }
        }
        'dotnet' {
            # El SDK tiene URL predecible. Se comprobo con dotnet-install
            # -DryRun, que imprime exactamente esta.
            return [PSCustomObject]@{
                Url      = "https://builds.dotnet.microsoft.com/dotnet/Sdk/$Version/dotnet-sdk-$Version-win-x64.zip"
                FileName = "dotnet-sdk-$Version-win-x64.zip"
                Sha256   = $null
            }
        }
        'vscode' {
            # La API de actualizacion solo da la ULTIMA, pero esta otra ruta
            # sirve cualquier version concreta y redirige al zip.
            return [PSCustomObject]@{
                Url      = "https://update.code.visualstudio.com/$Version/win32-x64-archive/stable"
                FileName = "VSCode-win32-x64-$Version.zip"
                Sha256   = $null
            }
        }
    }
    return $null
}

function Invoke-GitPostInstall {
    <#
        PortableGit trae un post-install.bat que remata la instalacion: crea
        /dev, /etc/mtab y el resto del entorno MSYS que necesita Git Bash. Se
        borra solo al terminar, y esa es la senal de que hizo su trabajo: el
        codigo de salida es 1 aunque vaya bien, porque lo ultimo que ejecuta es
        el DEL de si mismo.

        Se lanza con cmd y el directorio de trabajo puesto. Con el
        "git-bash.exe --command=post-install.bat" que sugiere su cabecera sale
        del paso sin hacer nada.

        Vive aqui y no en Setup-GitEnv porque Import-Env tambien lo necesita:
        un Git sacado del bundle quedaba con Git Bash a medias, y lo detecto
        Doctor avisando de "post-instalacion sin completar".
    #>
    param([Parameter(Mandatory=$true)][string]$GitPath)

    $script = Join-Path $GitPath "post-install.bat"
    if (-not (Test-Path -LiteralPath $script)) { return $true }

    Write-Log "  rematando la instalacion (entorno de Git Bash)..."
    try {
        Start-Process -FilePath "cmd.exe" -ArgumentList @('/c', "`"$script`"") `
                      -WorkingDirectory $GitPath -Wait -WindowStyle Hidden | Out-Null
    }
    catch {
        Write-Log "  no se pudo ejecutar post-install.bat: $($_.Exception.Message)" "WARN"
        return $false
    }

    if (Test-Path -LiteralPath $script) {
        # Git funciona igual; lo que puede quedar a medias es el entorno Unix.
        Write-Log "  post-install.bat no llego a terminar; git funciona, Git Bash puede ir justo" "WARN"
        return $false
    }
    return $true
}

function Expand-BundledRuntime {
    <#
        Coloca el archivo de un runtime en su carpeta definitiva, teniendo en
        cuenta como viene empaquetado cada uno:

          Envoltorio  el zip trae dentro una carpeta (node-vX, apache-maven-X)
                      que hay que renombrar a la del kit
          Plano       el zip vuelca su contenido directamente (dotnet, vscode)
          Sfx         no es un zip sino un autoextraible (PortableGit)
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Archivo,
        [Parameter(Mandatory=$true)][string]$Destino,
        [Parameter(Mandatory=$true)][PSCustomObject]$Entrada
    )

    if ($Entrada.Sfx) {
        $proc = Start-Process -FilePath $Archivo -ArgumentList @("-o`"$Destino`"", '-y') -Wait -PassThru
        return ($proc.ExitCode -eq 0)
    }

    if (-not $Entrada.Envoltorio) {
        if (-not (Test-Path -LiteralPath $Destino)) {
            New-Item -ItemType Directory -Path $Destino -Force | Out-Null
        }
        Expand-Archive -Path $Archivo -DestinationPath $Destino -Force
        return $true
    }

    $temp = "$Destino.tmp"
    if (Test-Path $temp) { Remove-Item $temp -Recurse -Force }
    Expand-Archive -Path $Archivo -DestinationPath $temp -Force

    $inner = @(Get-ChildItem $temp -Directory)
    if ($inner.Count -eq 1) {
        Move-Item -LiteralPath $inner[0].FullName -Destination $Destino -Force
    }
    else {
        New-Item -ItemType Directory -Path $Destino -Force | Out-Null
        Move-Item -Path "$temp\*" -Destination $Destino -Force
    }
    Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
    return $true
}

function Write-RuntimeShell {
    <#
        Regenera el shell de un runtime con las rutas de ESTA maquina. Import-Env
        lo necesita para los seis runtimes que empaqueta: dentro del bundle van
        rutas absolutas del equipo de origen, que aqui no valen.

        Es un despachador y no una funcion nueva: cada Write-*Shell sigue donde
        estaba, aqui solo se elige cual.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Clave,
        [Parameter(Mandatory=$true)][string]$Ruta,
        [Parameter(Mandatory=$true)][string]$Version,
        [string]$Linea
    )

    switch ($Clave) {
        'node'   { return (Write-NodeShell   -NodePath $Ruta -Version $Version) }
        'git'    { return (Write-GitShell    -GitPath  $Ruta -Version $Version) }
        'maven'  { return (Write-BuildToolShell -Tool Maven  -ToolPath $Ruta -Version $Version -JavaHome (Get-KitJavaHome)) }
        'gradle' { return (Write-BuildToolShell -Tool Gradle -ToolPath $Ruta -Version $Version -JavaHome (Get-KitJavaHome)) }
        'dotnet' { return (Write-DotnetShell -DotnetPath $Ruta -Version $Version -Channel $Linea) }
        'vscode' { return (Write-VSCodeShell -VSCodePath $Ruta -Version $Version) }
    }
    return $null
}

function Get-InstalledRuntimeVersion {
    <#
    .SYNOPSIS
        La version EXACTA instalada de un runtime, no la linea de su carpeta.
    .DESCRIPTION
        Cada runtime la guarda en un sitio distinto, y hasta ahora esa logica
        estaba repartida entre Doctor, Update-Env y los Start-*. Este es el sitio
        designado para averiguarlo; lo demas deberia acabar leyendo de aqui.

        Se prefiere leer un archivo a ejecutar el binario siempre que se pueda:
        es mas rapido y no depende de que haya variables de entorno puestas.
    #>
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$Entrada,
        [Parameter(Mandatory=$true)][string]$Linea
    )

    # El nombre de carpeta se compone aparte: un switch entre parentesis no es
    # una expresion valida en PowerShell 5.1 y rompe el archivo entero al
    # cargarlo.
    $nombre = switch ($Entrada.Clave) {
        'angular' { "angular-v$Linea" }
        'java'    { "jdk-$Linea" }
        'node'    { "node-$Linea" }
        default   { "$($Entrada.Clave)-$Linea" }
    }

    $dir = Join-Path (Join-Path $WorkspaceRoot $Entrada.Carpeta) $nombre
    if (-not (Test-Path -LiteralPath $dir)) { return $null }

    switch ($Entrada.Clave) {
        'python' {
            $exe = Join-Path $dir "python.exe"
            if (-not (Test-Path $exe)) { return $null }
            $run = Invoke-NativeCommand -FilePath $exe -Arguments @('-V') -Quiet
            if ($run.Output -match 'Python (\d+\.\d+\.\d+)') { return $Matches[1] }
            return $null
        }
        'java' {
            # El release exacto (jdk-25.0.4.1+1) lo deja Setup-JavaEnv en un
            # marcador, porque el numero de build no sale de java -version.
            $mk = Join-Path $dir ".assassinskipadm-release"
            if (Test-Path $mk) { return (Get-Content $mk -Raw).Trim() }
            return (Get-JdkVersionAt -JavaHome $dir)
        }
        'node' {
            $exe = Join-Path $dir "node.exe"
            if (-not (Test-Path $exe)) { return $null }
            $run = Invoke-NativeCommand -FilePath $exe -Arguments @('--version') -Quiet
            if ($run.Output -match 'v?(\d+\.\d+\.\d+)') { return $Matches[1] }
            return $null
        }
        'angular' {
            $pkg = Join-Path $dir "npm-global\node_modules\@angular\cli\package.json"
            if (-not (Test-Path $pkg)) { return $null }
            try { return (Get-Content $pkg -Raw | ConvertFrom-Json).version } catch { return $null }
        }
        'git' {
            $exe = Join-Path $dir "cmd\git.exe"
            if (-not (Test-Path $exe)) { return $null }
            $run = Invoke-NativeCommand -FilePath $exe -Arguments @('--version') -Quiet
            return (ConvertFrom-GitVersionOutput -Output $run.Output)
        }
        'maven' {
            $jar = @(Get-ChildItem -Path (Join-Path $dir "lib\maven-core-*.jar") -ErrorAction SilentlyContinue)
            if ($jar.Count -gt 0 -and $jar[0].Name -match 'maven-core-([\d.]+)\.jar') { return $Matches[1] }
            return $null
        }
        'gradle' {
            $jar = @(Get-ChildItem -Path (Join-Path $dir "lib\gradle-launcher-*.jar") -ErrorAction SilentlyContinue)
            if ($jar.Count -gt 0 -and $jar[0].Name -match 'gradle-launcher-([\d.]+)\.jar') { return $Matches[1] }
            return $null
        }
        'dotnet' {
            $sdks = @(Get-ChildItem -LiteralPath (Join-Path $dir "sdk") -Directory -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -match '^\d+\.\d+\.\d+' })
            if ($sdks.Count -gt 0) { return @($sdks | Sort-Object Name -Descending)[0].Name }
            return $null
        }
        'vscode' {
            $exe = Join-Path $dir "Code.exe"
            if (-not (Test-Path $exe)) { return $null }
            $v = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
            if ($v -match '(\d+\.\d+\.\d+)') { return $Matches[1] }
            return $v
        }
    }
    return $null
}

function Get-InstalledRuntimeSha256 {
    <#
        El SHA-256 del archivo con que se instalo, si el kit lo anoto. Hoy solo
        lo deja Setup-PythonEnv; los demas verifican el checksum al descargar
        pero no lo guardan. Devuelve $null cuando no consta, y quien llama debe
        decirlo en vez de dar a entender que hay una garantia que no hay.
    #>
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$Entrada,
        [Parameter(Mandatory=$true)][string]$Linea
    )

    if ($Entrada.Clave -ne 'python') { return $null }

    $mk = Join-Path (Join-Path $WorkspaceRoot "Python\python-$Linea") ".assassinskipadm-sha256"
    if (Test-Path -LiteralPath $mk) { return (Get-Content $mk -Raw).Trim() }
    return $null
}

function Resolve-RuntimeFromPath {
    <#
    .SYNOPSIS
        De una ruta dentro del workspace deduce a que runtime pertenece y de que
        version. Devuelve $null si la ruta no es de ninguno.
    .DESCRIPTION
        Sirve para pasar de "esta carpeta esta tapada en el PATH" a "esto se
        arregla con Use-Env -Runtime Java -Version 25".

        El nombre de carpeta del catalogo coincide con el que espera Use-Env en
        -Runtime, asi que se devuelve tal cual.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $p = $Path.TrimEnd('\')

    foreach ($e in (Get-RuntimeCatalog)) {
        $raiz = (Join-Path $WorkspaceRoot $e.Carpeta).TrimEnd('\')
        if (-not $p.StartsWith($raiz + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }

        # La primera carpeta por debajo de la raiz es la de la version.
        $carpeta = (($p.Substring($raiz.Length).TrimStart('\')) -split '\\')[0]
        if ($carpeta -match $e.Patron) {
            return [PSCustomObject]@{
                Runtime = $e.Carpeta      # es lo que espera Use-Env en -Runtime
                Nombre  = $e.Nombre
                Version = $Matches[1]
            }
        }
    }
    return $null
}

function Get-InstalledRuntimeLines {
    <#
        Devuelve que lineas hay instaladas de un runtime del catalogo, leyendo
        los nombres de carpeta. Es la base de Restore-Env -Save.
    #>
    param([Parameter(Mandatory=$true)][PSCustomObject]$Entrada)

    $raiz = Join-Path $WorkspaceRoot $Entrada.Carpeta
    if (-not (Test-Path -LiteralPath $raiz)) { return @() }

    return @(Get-ChildItem -LiteralPath $raiz -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {
            if ($_.Name -match $Entrada.Patron) { $Matches[1] }
        })
}

function Read-DevEnvManifest {
    <#
    .SYNOPSIS
        Valida un devenv.json ya cargado y devuelve lo que hay que instalar.
    .DESCRIPTION
        Separada de la lectura del archivo para poder probarla. Devuelve un
        objeto con Runtimes (lista ordenada segun el catalogo) y Errores.

        Un runtime desconocido no se ignora en silencio: se devuelve como error.
        Un devenv.json con una errata dejaria el entorno a medias sin decir por
        que, y este comando existe justo para lo contrario.

        El valor de un runtime puede ser una lista: "java": ["21", "25"] instala
        las dos. Hacia falta para describir el caso real de trabajar en proyectos
        con Javas distintos; con un solo valor por runtime, el manifiesto no
        sabia reproducir esa maquina.

        La seccion "java" ata el shell por defecto de Maven o Gradle a un JDK
        concreto: sin ella se quedarian con el mas alto instalado.
    #>
    param([AllowNull()]$Config)

    $errores  = @()
    $avisos   = @()
    $runtimes = @()

    if (-not $Config) {
        return [PSCustomObject]@{ Runtimes = @(); Errores = @('el manifiesto esta vacio o no es JSON valido'); Avisos = @() }
    }

    if ($Config.version -and [int]$Config.version -gt 1) {
        $errores += "el manifiesto declara version $($Config.version) y este kit entiende hasta la 1"
    }

    if (-not $Config.runtimes) {
        $errores += "no hay ninguna seccion 'runtimes'"
        return [PSCustomObject]@{ Runtimes = @(); Errores = $errores; Avisos = $avisos }
    }

    $catalogo = Get-RuntimeCatalog
    $pedidos  = @{}
    foreach ($p in $Config.runtimes.PSObject.Properties) {
        $clave = $p.Name.ToLowerInvariant()
        if (-not ($catalogo | Where-Object { $_.Clave -eq $clave })) {
            $errores += "runtime desconocido: '$($p.Name)'  (conocidos: $(($catalogo.Clave) -join ', '))"
            continue
        }

        # Un valor suelto y una lista se tratan igual a partir de aqui.
        $lista = @(@($p.Value) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                   ForEach-Object { ([string]$_).Trim() })
        if ($lista.Count -eq 0) {
            $errores += "$clave : no dice ninguna version"
            continue
        }

        $repes = @($lista | Group-Object | Where-Object { $_.Count -gt 1 })
        if ($repes.Count -gt 0) {
            $errores += "$clave : la version $($repes[0].Name) esta repetida"
            continue
        }

        $pedidos[$clave] = $lista
    }

    # La seccion java se valida contra lo que se va a instalar: atar Maven a un
    # JDK que el manifiesto no instala fallaria a mitad de la reproduccion, y es
    # justo lo que este validador existe para evitar.
    $ataduras = @{}
    if ($Config.java) {
        foreach ($p in $Config.java.PSObject.Properties) {
            $clave = $p.Name.ToLowerInvariant()
            $e = @($catalogo | Where-Object { $_.Clave -eq $clave })

            if ($e.Count -eq 0) {
                $errores += "seccion 'java': runtime desconocido '$($p.Name)'"
                continue
            }
            if (-not $e[0].ParamJava) {
                $conJava = ($catalogo | Where-Object { $_.ParamJava }).Clave -join ', '
                $errores += "seccion 'java': $clave no elige JDK  (solo lo hacen: $conJava)"
                continue
            }
            if (-not $pedidos.ContainsKey($clave)) {
                $avisos += "seccion 'java': se ata $clave a un JDK pero el manifiesto no instala $clave"
                continue
            }

            $linea = ([string]$p.Value).Trim()
            if ($linea -notmatch '^\d+$') {
                $errores += "seccion 'java': '$linea' no es una linea de JDK (se espera 21, 25...)"
                continue
            }
            if ($pedidos.ContainsKey('java') -and $pedidos['java'] -notcontains $linea) {
                $errores += "seccion 'java': se ata $clave al JDK $linea, que el manifiesto no instala (instala: $($pedidos['java'] -join ', '))"
                continue
            }
            if (-not $pedidos.ContainsKey('java')) {
                $avisos += "seccion 'java': se ata $clave al JDK $linea, que el manifiesto no instala; tendra que estar ya en la maquina"
            }

            $ataduras[$clave] = $linea
        }
    }

    # Se recorre el CATALOGO y no lo pedido, para que el orden de instalacion
    # sea siempre el mismo: Java antes que Maven y Gradle, que lo necesitan.
    foreach ($e in $catalogo) {
        if (-not $pedidos.ContainsKey($e.Clave)) { continue }

        $paquetes = $null
        if ($e.ParamPaquetes -and $Config.paquetes) {
            $prop = $Config.paquetes.PSObject.Properties[$e.Clave]
            if ($prop -and $prop.Value) { $paquetes = @($prop.Value) -join ',' }
        }

        # De menor a mayor: si el Setup ordena el PATH por orden de llegada, la
        # version mas alta acaba delante, que es la que se espera por defecto.
        $ordenadas = @($pedidos[$e.Clave] | Sort-Object {
            try { [version]($_ -replace '^(\d+)$', '$1.0') } catch { [version]'0.0' }
        })

        foreach ($v in $ordenadas) {
            $runtimes += [PSCustomObject]@{
                Clave    = $e.Clave
                Nombre   = $e.Nombre
                Version  = $v
                Paquetes = $paquetes
                Java     = $(if ($ataduras.ContainsKey($e.Clave)) { $ataduras[$e.Clave] } else { $null })
                Entrada  = $e
            }
        }
    }

    return [PSCustomObject]@{ Runtimes = $runtimes; Errores = $errores; Avisos = $avisos }
}

function Read-DevEnvLock {
    <#
    .SYNOPSIS
        Valida un devenv.lock.json ya cargado y devuelve que instalar.
    .DESCRIPTION
        El lockfile es al devenv.json lo que un package-lock.json al package.json:
        el manifiesto dice "Python 3.12", el lock dice "3.12.10". Sirve para que
        dos maquinas monten lo MISMO y no dos parches distintos de la misma linea.

        Cada entrada trae linea y exacta. Se usa la exacta solo si el Setup de
        ese runtime la admite -lo dice Fijable en el catalogo-; si no, se cae a
        la linea y se avisa, porque prometer un pin que no se puede cumplir es
        peor que no tenerlo.

        Un runtime puede traer varias entradas en una lista, igual que en el
        manifiesto: una maquina con dos JDK no se describe con una sola.
    #>
    param([AllowNull()]$Config)

    $errores  = @()
    $runtimes = @()

    if (-not $Config) {
        return [PSCustomObject]@{ Runtimes = @(); Errores = @('el lock esta vacio o no es JSON valido') }
    }
    if ($Config.version -and [int]$Config.version -gt 1) {
        $errores += "el lock declara version $($Config.version) y este kit entiende hasta la 1"
    }
    if (-not $Config.runtimes) {
        $errores += "el lock no tiene seccion 'runtimes'"
        return [PSCustomObject]@{ Runtimes = @(); Errores = $errores }
    }

    $catalogo = Get-RuntimeCatalog
    $pedidos  = @{}
    foreach ($p in $Config.runtimes.PSObject.Properties) {
        $clave = $p.Name.ToLowerInvariant()
        $e = @($catalogo | Where-Object { $_.Clave -eq $clave })
        if ($e.Count -eq 0) {
            $errores += "runtime desconocido en el lock: '$($p.Name)'"
            continue
        }
        # Una entrada suelta y una lista se tratan igual a partir de aqui.
        $pedidos[$clave] = @($p.Value)
    }

    foreach ($e in $catalogo) {
        if (-not $pedidos.ContainsKey($e.Clave)) { continue }

        foreach ($v in $pedidos[$e.Clave]) {
            $linea  = if ($v.linea)  { [string]$v.linea }  else { $null }
            $exacta = if ($v.exacta) { [string]$v.exacta } else { $null }

            if (-not $linea -and -not $exacta) {
                $errores += "$($e.Clave): la entrada del lock no trae ni linea ni exacta"
                continue
            }

            $usar = if ($e.Fijable -and $exacta) { $exacta } else { $linea }
            if (-not $usar) { $usar = $exacta }

            $runtimes += [PSCustomObject]@{
                Clave    = $e.Clave
                Nombre   = $e.Nombre
                Version  = $usar
                Exacta   = $exacta
                Linea    = $linea
                Fijado   = [bool]($e.Fijable -and $exacta)
                Sha256   = if ($v.sha256) { [string]$v.sha256 } else { $null }
                Paquetes = $null
                Java     = $(if ($v.java) { [string]$v.java } else { $null })
                Entrada  = $e
            }
        }
    }

    return [PSCustomObject]@{ Runtimes = $runtimes; Errores = $errores }
}

$PythonFtpIndexUrl = "https://www.python.org/ftp/python/"

function Get-PythonArchiveInfo {
    param([Parameter(Mandatory=$true)][string]$FullVersion)

    $file = "python-$FullVersion-embed-amd64.zip"
    return [PSCustomObject]@{
        FileName = $file
        Url      = "https://www.python.org/ftp/python/$FullVersion/$file"
    }
}

function Get-LatestPythonPatch {
    <#
    .SYNOPSIS
        Ultima X.Y.Z de una serie que tenga zip embeddable para Windows.
    .DESCRIPTION
        No basta con coger el numero mas alto: cuando una serie pasa a modo "solo
        seguridad", python.org publica esas versiones SOLO como codigo fuente.
        Por eso se prueban las candidatas de mayor a menor hasta dar con una que
        tenga de verdad el binario.

        Vive aqui porque lo necesitan Setup-PythonEnv (para decidir que instalar)
        y Update-Env (para decidir si lo instalado esta al dia). Con dos copias
        acabarian divergiendo y cada una diria una cosa.

        Devuelve $null si no se pudo determinar. Silencioso salvo con -Verbose:
        quien llama decide como contarlo.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$MinorPrefix,
        [int]$MaxProbes = 12
    )

    # El indice de python.org es un listado HTML de directorio, no JSON.
    $listing = Get-WebText -Uri $PythonFtpIndexUrl -Quiet
    if (-not $listing) { return $null }

    $pattern = 'href="(' + [regex]::Escape($MinorPrefix) + '\.\d+)/"'
    $candidates = @([regex]::Matches($listing, $pattern) |
        ForEach-Object { $_.Groups[1].Value } |
        Sort-Object { [version]$_ } -Descending)

    if ($candidates.Count -eq 0) { return $null }

    foreach ($candidate in ($candidates | Select-Object -First $MaxProbes)) {
        if (Test-UrlExists -Uri (Get-PythonArchiveInfo -FullVersion $candidate).Url) {
            return [PSCustomObject]@{
                Version   = $candidate
                MasNueva  = $candidates[0]   # puede existir pero solo como fuente
                SoloFuente = ($candidate -ne $candidates[0])
            }
        }
    }

    return $null
}

function Get-LatestAngularCliVersion {
    <#
        Ultima version estable del CLI para una mayor de Angular, segun el
        registro de npm. Devuelve $null si el registro no respondio, y cadena
        vacia si respondio pero esa mayor no existe.
    #>
    param([Parameter(Mandatory=$true)][int]$Major)

    $pack = Invoke-JsonApi -Uri "https://registry.npmjs.org/@angular%2fcli" `
                           -Headers @{ Accept = 'application/vnd.npm.install-v1+json' } `
                           -TimeoutSec 120 -Quiet
    if (-not $pack -or -not $pack.versions) { return $null }

    $stable = @($pack.versions.PSObject.Properties.Name |
        Where-Object { $_ -match "^$Major\." -and $_ -notmatch '-(next|rc|beta|alpha)' } |
        Sort-Object { ConvertTo-SemverObject $_ })

    if ($stable.Count -eq 0) { return '' }
    return $stable[-1]
}

function Get-JavaArchiveInfo {
    <#
        Datos del JDK de Adoptium. Con -Major coge el ultimo de esa linea; con
        -Release, ESE exacto (ej: jdk-25.0.4.1+1), que es lo que permite fijarlo
        en un devenv.lock.json.

        Son dos endpoints distintos y la respuesta tiene distinta forma: el de
        "latest" devuelve una lista de objetos con .binary, y el de release_name
        un objeto con .binaries. Devuelve $null si la API no responde.

        Los filtros de la query no son opcionales en el segundo: sin ellos
        devuelve tambien los static-libs y el primer zip no seria el JDK.
    #>
    param(
        [int]$Major,
        [string]$Release
    )

    if (-not [string]::IsNullOrWhiteSpace($Release)) {
        $uri = "https://api.adoptium.net/v3/assets/release_name/eclipse/" +
               [Uri]::EscapeDataString($Release) +
               "?architecture=x64&image_type=jdk&os=windows"

        $r = Invoke-JsonApi -Uri $uri -TimeoutSec 120 -Quiet
        if (-not $r) { return $null }

        $obj = @($r)[0]
        $zip = @($obj.binaries | Where-Object { $_.package.name -like '*.zip' })
        if ($zip.Count -eq 0) { return $null }

        return [PSCustomObject]@{
            FileName = $zip[0].package.name
            Url      = $zip[0].package.link
            Sha256   = $zip[0].package.checksum
            Release  = $obj.release_name
            SizeMb   = [math]::Round($zip[0].package.size / 1MB, 1)
        }
    }

    if ($Major -le 0) { return $null }

    $uri = "https://api.adoptium.net/v3/assets/latest/$Major/hotspot" +
           "?architecture=x64&image_type=jdk&os=windows&vendor=eclipse"

    $assets = Invoke-JsonApi -Uri $uri -TimeoutSec 120 -Quiet
    if (-not $assets -or $assets.Count -eq 0) { return $null }

    $zip = @($assets | Where-Object { $_.binary.package.name -like '*.zip' })
    if ($zip.Count -eq 0) { return $null }

    $r = $zip[0]
    return [PSCustomObject]@{
        FileName = $r.binary.package.name
        Url      = $r.binary.package.link
        Sha256   = $r.binary.package.checksum
        Release  = $r.release_name
    }
}

function Split-RuntimeVersionSpec {
    <#
    .SYNOPSIS
        Separa lo que pide el usuario en "linea" y "exacta".
    .DESCRIPTION
        Los Setup aceptan ahora las dos formas en el MISMO parametro, para que
        un devenv.lock.json pueda fijar la version sin necesitar un parametro
        distinto por runtime:

            -JavaVersion 21              la linea: el ultimo parche de la 21
            -JavaVersion jdk-21.0.5+11   ese release exacto

        Devuelve Linea (siempre) y Exacta ($null si solo se pidio la linea).
        Reconocer una u otra depende del runtime, porque sus versiones no tienen
        la misma forma: la de Java lleva prefijo y un '+', la de Angular es un
        semver, y la de VS Code y .NET son X.Y frente a X.Y.Z.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Clave,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Spec
    )

    $s = $Spec.Trim()
    if ([string]::IsNullOrWhiteSpace($s)) {
        return [PSCustomObject]@{ Linea = $null; Exacta = $null }
    }

    switch ($Clave) {
        'java' {
            # jdk-25.0.4.1+1  ->  linea 25
            if ($s -match '^jdk-(\d+)') {
                return [PSCustomObject]@{ Linea = $Matches[1]; Exacta = $s }
            }
            # 25.0.4.1+1 sin prefijo: se acepta y se normaliza.
            if ($s -match '^(\d+)\.\d+.*\+') {
                return [PSCustomObject]@{ Linea = $Matches[1]; Exacta = "jdk-$s" }
            }
            return [PSCustomObject]@{ Linea = ($s -replace '^jdk-',''); Exacta = $null }
        }
        'angular' {
            # 20.3.35 -> linea 20 ;  20 -> solo linea
            if ($s -match '^(\d+)\.\d+') {
                return [PSCustomObject]@{ Linea = $Matches[1]; Exacta = $s }
            }
            return [PSCustomObject]@{ Linea = $s; Exacta = $null }
        }
        'dotnet' {
            # 10.0.400 -> canal 10.0 ;  10.0 -> solo canal
            if ($s -match '^(\d+\.\d+)\.\d+') {
                return [PSCustomObject]@{ Linea = $Matches[1]; Exacta = $s }
            }
            return [PSCustomObject]@{ Linea = $s; Exacta = $null }
        }
        'vscode' {
            # 1.135.0 -> linea 1.135 ;  1.135 -> solo linea
            if ($s -match '^(\d+\.\d+)\.\d+') {
                return [PSCustomObject]@{ Linea = $Matches[1]; Exacta = $s }
            }
            return [PSCustomObject]@{ Linea = $s; Exacta = $null }
        }
    }

    return [PSCustomObject]@{ Linea = $s; Exacta = $null }
}

function Get-WebText {
    <#
        GET que devuelve el cuerpo como texto, con el mismo tratamiento de proxy
        que el resto. Para paginas HTML o listados de directorio, donde
        Invoke-JsonApi no encaja.
        Devuelve $null si falla; quien llama decide si eso es fatal.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [int]$TimeoutSec = 60,
        [switch]$Quiet
    )

    $Uri = Resolve-KitUrl -Uri $Uri -Quiet:$Quiet

    $params = @{
        Uri             = $Uri
        UseBasicParsing = $true
        TimeoutSec      = $TimeoutSec
    }

    Add-ProxyToRequest -Params $params -Uri ([Uri]$Uri)

    try {
        $contenido = (Invoke-WebRequest @params).Content

        # Cuando el servidor no declara charset, PowerShell 5.1 no decodifica y
        # devuelve un ARRAY DE BYTES en vez de texto. Pasa con archivos sueltos
        # de checksum como el .sha256 de Gradle, y quien llama recibia
        # System.Object[] donde esperaba una cadena.
        if ($contenido -is [byte[]] -or $contenido -is [System.Array]) {
            return [System.Text.Encoding]::UTF8.GetString([byte[]]$contenido)
        }
        return $contenido
    }
    catch {
        if (-not $Quiet) {
            Write-Log "No se pudo leer $Uri" "WARN"
            $hint = Get-DownloadErrorHint -ErrorRecord $_
            if ($hint) { Write-Log "  -> $hint" "WARN" }
        }
        return $null
    }
}

function Test-UrlExists {
    <#
        Comprueba con una peticion HEAD si un archivo existe en el servidor,
        sin descargarlo. Util para probar versiones candidatas antes de elegir.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [int]$TimeoutSec = 30
    )

    # -Quiet: Test-UrlExists se usa en bucle para tantear versiones candidatas,
    # y anunciar el espejo en cada intento llenaria la pantalla de ruido.
    $Uri = Resolve-KitUrl -Uri $Uri -Quiet

    $params = @{
        Uri             = $Uri
        Method          = 'Head'
        UseBasicParsing = $true
        TimeoutSec      = $TimeoutSec
    }

    Add-ProxyToRequest -Params $params -Uri ([Uri]$Uri)

    try {
        Invoke-WebRequest @params | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Get-Sha256FromShasums {
    <#
        Lee un archivo de checksums remoto con el formato "<hash>  <archivo>"
        (el que publica nodejs.org junto a cada release) y devuelve el hash del
        archivo pedido, o $null si no se pudo obtener.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [Parameter(Mandatory=$true)][string]$FileName
    )

    $temp = Join-Path $env:TEMP ("shasums-" + [Guid]::NewGuid().ToString('N') + ".txt")

    if (-not (Invoke-Download -Uri $Uri -OutFile $temp -Description "checksums oficiales")) {
        return $null
    }

    try {
        foreach ($line in (Get-Content -LiteralPath $temp)) {
            $parts = $line -split '\s+', 2
            if ($parts.Count -eq 2 -and $parts[1].Trim() -eq $FileName) {
                return $parts[0].Trim().ToLowerInvariant()
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }

    return $null
}

function Test-ZipIntegrity {
    <#
        Abrir el zip obliga a leer su indice central, que esta al final del
        archivo: detecta descargas truncadas aqui, en vez de dejar que
        Expand-Archive falle luego con un error incomprensible.
    #>
    param([Parameter(Mandatory=$true)][string]$ZipPath)

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        try {
            return ($zip.Entries.Count -gt 0)
        }
        finally {
            $zip.Dispose()
        }
    }
    catch {
        return $false
    }
}

# --------------------------------------------------------------------------
# PATH de usuario
# --------------------------------------------------------------------------

function Get-RawUserPath {
    <#
        Lee el PATH de usuario SIN expandir variables.

        [Environment]::GetEnvironmentVariable("Path","User") expande %USERPROFILE%
        y similares al leer; si luego se vuelve a escribir el resultado, esas
        variables quedan congeladas como rutas absolutas y el PATH del usuario
        se degrada en cada ejecucion. Por eso se lee del registro en crudo.
    #>
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
    if (-not $key) { return '' }
    try {
        $value = $key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($null -eq $value) { return '' }
        return [string]$value
    }
    finally {
        $key.Dispose()
    }
}

function Set-RawUserPath {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Value)

    # Si el PATH contiene %VAR%, tiene que guardarse como REG_EXPAND_SZ o Windows
    # dejaria de resolverlas.
    $kind = if ($Value -like '*%*') {
        [Microsoft.Win32.RegistryValueKind]::ExpandString
    } else {
        [Microsoft.Win32.RegistryValueKind]::String
    }

    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    if (-not $key) { throw "No se pudo abrir HKCU:\Environment para escritura." }
    try {
        $key.SetValue('Path', $Value, $kind)
    }
    finally {
        $key.Dispose()
    }
}

$script:PathBackupsToKeep = 10

function Backup-UserPath {
    <#
        Copia de seguridad del PATH antes de tocarlo. Barato, y convierte un
        posible desastre en un copy/paste. Se guarda fuera del kit.

        Rotacion: se conservan las ultimas $PathBackupsToKeep y, SIEMPRE, la
        primera de todas. Esa primera es el PATH de antes de que el kit tocara
        nada, o sea la que de verdad importa en un desastre; un tope ingenuo del
        tipo "conserva las N ultimas" seria justo la que borraria.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Value)

    try {
        $dir = Join-Path $env:LOCALAPPDATA "AssassinSkipAdm\path-backups"
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"

        # Si no hay ninguna marcada como original, esta lo es. El prefijo
        # distinto la deja fuera de la rotacion para siempre.
        $original = @(Get-ChildItem -LiteralPath $dir -Filter 'path-ORIGINAL-*.txt' -ErrorAction SilentlyContinue)
        $name = if ($original.Count -eq 0) { "path-ORIGINAL-$stamp.txt" } else { "path-$stamp.txt" }

        $file = Join-Path $dir $name
        Set-Content -LiteralPath $file -Value $Value -Encoding UTF8

        Remove-OldPathBackups -Directory $dir

        return $file
    }
    catch {
        return $null
    }
}

function Remove-OldPathBackups {
    param([Parameter(Mandatory=$true)][string]$Directory)

    try {
        $rotables = @(Get-ChildItem -LiteralPath $Directory -Filter 'path-*.txt' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike 'path-ORIGINAL-*' } |
            Sort-Object LastWriteTime -Descending)

        if ($rotables.Count -le $script:PathBackupsToKeep) { return }

        foreach ($old in ($rotables | Select-Object -Skip $script:PathBackupsToKeep)) {
            Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        # La rotacion nunca debe impedir que la copia se haya guardado.
    }
}

function Publish-EnvironmentChange {
    <#
        Avisa a Windows de que las variables de entorno cambiaron, para que las
        ventanas nuevas lo vean sin cerrar sesion. Escribir en el registro por si
        solo no lo notifica (SetEnvironmentVariable si lo hace, pero no podemos
        usarlo aqui por el problema de expansion de Get-RawUserPath).
    #>
    if (-not ('NativeEnvBroadcast' -as [type])) {
        Add-Type -Namespace '' -Name 'NativeEnvBroadcast' -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(
    System.IntPtr hWnd, uint Msg, System.IntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);
'@ -ErrorAction SilentlyContinue
    }

    try {
        $HWND_BROADCAST   = [IntPtr]0xffff
        $WM_SETTINGCHANGE = 0x1A
        $SMTO_ABORTIFHUNG = 0x0002
        $result = [UIntPtr]::Zero
        [NativeEnvBroadcast]::SendMessageTimeout(
            $HWND_BROADCAST, $WM_SETTINGCHANGE, [IntPtr]::Zero, "Environment",
            $SMTO_ABORTIFHUNG, 5000, [ref]$result) | Out-Null
    }
    catch {
        # No es critico: los shells generados fijan su propio PATH igualmente.
    }
}

function Split-UserPath {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Value)
    return @($Value -split ';' | Where-Object { $_.Trim() -ne '' })
}

function Save-UserPath {
    <#
        Escribe el PATH de usuario dejando antes una copia, y avisa a Windows.
        Devuelve la ruta del respaldo.
    #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Previous,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Updated
    )

    $backup = Backup-UserPath -Value $Previous
    Set-RawUserPath -Value $Updated
    Publish-EnvironmentChange
    return $backup
}

function Add-UserPathEntry {
    <#
    .SYNOPSIS
        Agrega una o varias rutas al PATH de usuario, sin duplicar.
    .DESCRIPTION
        Compara entrada por entrada con igualdad exacta. Una version anterior
        usaba -like "*$ruta*", que interpreta la ruta como patron comodin: con
        corchetes en el nombre de carpeta la deteccion fallaba y se anadia una
        entrada duplicada en cada ejecucion.

        Por defecto las rutas van AL PRINCIPIO. Windows resuelve el PATH de
        izquierda a derecha, asi que anadirlas al final hacia que, con varias
        versiones instaladas, respondiera siempre la primera que se instalo y no
        la que el usuario acababa de instalar. Con -Append se conserva el orden
        antiguo para casos en que no se quiera cambiar lo que ya responde.
    #>
    param(
        [Parameter(Mandatory=$true)][string[]]$Path,
        [switch]$Append
    )

    $current = Get-RawUserPath
    $entries = Split-UserPath -Value $current
    $wanted  = @($Path | ForEach-Object { $_.TrimEnd('\') })

    if ($Append) {
        $updated = @($entries)
        foreach ($w in $wanted) {
            $exists = $updated | Where-Object { $_.TrimEnd('\') -ieq $w }
            if (-not $exists) { $updated += $w }
        }
    }
    else {
        # Se retiran las apariciones previas y se reinsertan delante: si solo se
        # anadiera, una ruta ya presente al final seguiria perdiendo la prioridad.
        $rest = @($entries | Where-Object {
            $e = $_.TrimEnd('\')
            -not ($wanted | Where-Object { $_ -ieq $e })
        })
        $updated = @($wanted) + $rest
    }

    if (($updated -join ';') -ceq ($entries -join ';')) {
        Write-Log "PATH de usuario ya estaba correcto" "SUCCESS"
        return
    }

    $backup = Save-UserPath -Previous $current -Updated ($updated -join ';')

    # Tambien en la sesion actual, para que el resto del script pueda usarlo ya.
    $env:Path = ($wanted -join ';') + ';' + $env:Path

    foreach ($w in $wanted) {
        Write-Log "PATH: $w" "SUCCESS"
    }
    if (-not $Append) {
        Write-Log "  Colocadas al principio: son las que responden ahora."
    }
    if ($backup) {
        Write-Log "  Copia del PATH anterior: $backup"
    }
}

function Get-RawMachinePath {
    <#
        Lee el PATH de maquina sin expandir. Solo lectura: el kit nunca escribe
        aqui (haria falta admin, y ese es justo el punto del proyecto).
    #>
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
        'SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $false)
    if (-not $key) { return '' }
    try {
        $value = $key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($null -eq $value) { return '' }
        return [string]$value
    }
    finally {
        $key.Dispose()
    }
}

function Get-ActivationPaths {
    <#
        Rutas que antepone Use-Env al abrir cada terminal, leidas del activate.cmd
        que genera. Van por delante de todo, incluido el PATH de maquina, porque
        se aplican DESPUES de que Windows componga el PATH del proceso.
        Vacio si no hay activacion.
    #>
    $activateCmd = Join-Path $env:LOCALAPPDATA "AssassinSkipAdm\activate.cmd"
    if (-not (Test-Path -LiteralPath $activateCmd)) { return @() }

    foreach ($line in (Get-Content -LiteralPath $activateCmd -ErrorAction SilentlyContinue)) {
        if ($line -match '^\s*set\s+"PATH=(.+?);?%PATH%"\s*$') {
            return @($Matches[1] -split ';' | Where-Object { $_.Trim() -ne '' })
        }
    }
    return @()
}

function Get-EffectivePathEntries {
    <#
    .SYNOPSIS
        Devuelve las entradas del PATH en el orden real en que Windows las busca.
    .DESCRIPTION
        Windows compone el PATH de un proceso nuevo como MAQUINA + USUARIO, en
        ese orden. Es decisivo: una entrada de usuario NUNCA puede ganar a una de
        maquina, por mucho que se coloque la primera dentro del bloque de usuario.

        Si Use-Env esta activado, sus rutas van DELANTE de ambos bloques: el
        enganche de arranque de terminal corre despues de esa composicion.

        Cada elemento trae la ruta cruda, la expandida y de que ambito viene.
    #>
    $result = @()

    foreach ($block in @(
        @{ Scope = 'activado'; Value = ((Get-ActivationPaths) -join ';') },
        @{ Scope = 'maquina';  Value = (Get-RawMachinePath) },
        @{ Scope = 'usuario';  Value = (Get-RawUserPath) }
    )) {
        foreach ($entry in (Split-UserPath -Value $block.Value)) {
            $result += [PSCustomObject]@{
                Raw   = $entry
                Path  = [Environment]::ExpandEnvironmentVariables($entry).TrimEnd('\')
                Scope = $block.Scope
            }
        }
    }

    return $result
}

function Find-CommandInPath {
    <#
        Busca un ejecutable recorriendo el PATH en su orden real y devuelve todas
        las carpetas que lo contienen. La primera es la que responde.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$FileName,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Entries
    )

    $hits = @()
    foreach ($e in $Entries) {
        if ([string]::IsNullOrWhiteSpace($e.Path)) { continue }

        # Se concatena a mano en vez de usar Join-Path: Join-Path pasa por el
        # proveedor de PSDrive y lanza un error NO TERMINANTE si la unidad no
        # existe (una unidad de red desconectada en el PATH, por ejemplo). Al no
        # ser terminante, try/catch no lo captura y ensucia toda la salida.
        $candidate = $e.Path.TrimEnd('\') + '\' + $FileName

        try {
            if (Test-Path -LiteralPath $candidate -ErrorAction SilentlyContinue) { $hits += $e }
        }
        catch {
            # Rutas con caracteres invalidos: se ignoran.
        }
    }
    return $hits
}

function Show-PathConflicts {
    <#
        Avisa si en el PATH ya hay otras versiones del mismo runtime instaladas
        por el kit. Con varias, solo responde una: conviene decir cual y por que.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$Keep,
        [Parameter(Mandatory=$true)][string]$Label
    )

    $rootExpanded = [Environment]::ExpandEnvironmentVariables($Root).TrimEnd('\')
    $keepExpanded = [Environment]::ExpandEnvironmentVariables($Keep).TrimEnd('\')

    $others = @(Split-UserPath -Value (Get-RawUserPath) | Where-Object {
        $e = [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\')
        $e.StartsWith($rootExpanded + '\', [StringComparison]::OrdinalIgnoreCase) -and
        -not $e.StartsWith($keepExpanded, [StringComparison]::OrdinalIgnoreCase)
    })

    if ($others.Count -eq 0) { return }

    Write-Log "Ya habia otras versiones de $Label en el PATH:" "WARN"
    foreach ($o in $others) { Write-Log "  $o" "WARN" }
    Write-Log "  La que se acaba de instalar queda primera y es la que responde." "WARN"
    Write-Log "  Para retirar las demas:  .\Uninstall-Env.bat -Runtime $Label -Version <version>" "WARN"
}

function Remove-UserPathEntry {
    <#
    .SYNOPSIS
        Quita rutas del PATH de usuario. Devuelve cuantas quito.
    .PARAMETER Path
        Rutas exactas a eliminar.
    .PARAMETER UnderFolder
        Elimina cualquier entrada que cuelgue de esta carpeta. Es lo que usa el
        desinstalador: no depende de acertar la ruta exacta que se anadio.
    #>
    param(
        [string[]]$Path,
        [string]$UnderFolder
    )

    $current = Get-RawUserPath
    $entries = Split-UserPath -Value $current

    $targets = @($Path | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') })

    $folder = $null
    if (-not [string]::IsNullOrWhiteSpace($UnderFolder)) {
        $folder = [Environment]::ExpandEnvironmentVariables($UnderFolder).TrimEnd('\')
    }

    $removed = @()
    $kept    = @()

    foreach ($e in $entries) {
        # Las entradas pueden llevar %VAR%: se expanden solo para comparar,
        # nunca para guardar.
        $expanded = [Environment]::ExpandEnvironmentVariables($e).TrimEnd('\')

        $hit = [bool]($targets | Where-Object { $_ -ieq $expanded -or $_ -ieq $e.TrimEnd('\') })

        if (-not $hit -and $folder) {
            $hit = ($expanded -ieq $folder) -or ($expanded.StartsWith($folder + '\', [StringComparison]::OrdinalIgnoreCase))
        }

        if ($hit) { $removed += $e } else { $kept += $e }
    }

    if ($removed.Count -eq 0) {
        return 0
    }

    $backup = Save-UserPath -Previous $current -Updated ($kept -join ';')

    foreach ($r in $removed) {
        Write-Log "PATH -= $r" "SUCCESS"
    }
    if ($backup) {
        Write-Log "  Copia del PATH anterior: $backup"
    }

    return $removed.Count
}

# El registro se abre al cargar la libreria, para que capture desde la primera
# linea del script que la cargo. Silencioso y nunca fatal (ver Start-KitLog).
Start-KitLog | Out-Null
