#Requires -Version 5.1
<#
    Descargas: errores, checksums, firmas y reintentos

    Parte de lib\Common.ps1, que es quien carga este archivo. No se toma
    por separado: los scripts siguen haciendo un unico dot-source de
    Common.ps1 y no se enteran de esta division.
#>


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
