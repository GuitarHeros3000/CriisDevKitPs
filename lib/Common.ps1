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
$KitVersion = "1.0.0"

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
$script:KitLogsToKeep = 20

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
        # Dos consejos distintos segun si ya habia credenciales puestas. Antes
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
        return 'Fallo la validacion del certificado TLS. Es lo tipico con proxies que inspeccionan HTTPS: pide a IT el certificado raiz e importalo en "Certificados - Usuario actual" > "Entidades de certificacion raiz de confianza" (no necesita admin).'
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

    if (-not [string]::IsNullOrWhiteSpace($Sha256)) {
        $expected = $Sha256.Trim().ToLowerInvariant()
        $actual   = Get-FileSha256 -FilePath $temp

        if ($actual -ne $expected) {
            Write-Log "El archivo descargado no coincide con el hash oficial." "ERROR"
            Write-Log "  esperado: $expected" "ERROR"
            Write-Log "  obtenido: $actual" "ERROR"
            Write-Log "  -> Descarga corrupta o alterada en transito. No se va a usar." "WARN"
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
            return $false
        }

        Write-Log "  SHA-256 verificado" "SUCCESS"
    }

    if (Test-Path -LiteralPath $OutFile) {
        Remove-Item -LiteralPath $OutFile -Force
    }
    Move-Item -LiteralPath $temp -Destination $OutFile -Force

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
        Datos del JDK de Adoptium para una version mayor. Devuelve $null si la
        API no responde.
    #>
    param([Parameter(Mandatory=$true)][int]$Major)

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

    $params = @{
        Uri             = $Uri
        UseBasicParsing = $true
        TimeoutSec      = $TimeoutSec
    }

    Add-ProxyToRequest -Params $params -Uri ([Uri]$Uri)

    try {
        return (Invoke-WebRequest @params).Content
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
