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

# --------------------------------------------------------------------------
# Descarga por trozos, reanudable
# --------------------------------------------------------------------------

function Get-KitUserAgent {
    <#
        El mismo agente que manda Invoke-WebRequest. Hay proxies corporativos
        que filtran por agente, y cambiar de motor no deberia cambiar quien dice
        el kit que es.
    #>
    try {
        $p = [Microsoft.PowerShell.Commands.PSUserAgent].GetProperty('UserAgent', [Reflection.BindingFlags]'NonPublic, Static')
        $ua = $p.GetValue($null)
        if ($ua) { return [string]$ua }
    }
    catch { }
    return "Mozilla/5.0 (Windows NT) WindowsPowerShell/$($PSVersionTable.PSVersion)"
}

function ConvertTo-DownloadErrorRecord {
    <#
        Un fallo de HttpWebRequest llega a PowerShell envuelto: "Excepcion al
        llamar a GetResponse..." con la WebException DENTRO. Get-WebErrorStatus
        busca el codigo HTTP en la excepcion de fuera, asi que sin desenvolverla
        un 404 no tenia codigo, contaba como transitorio y se reintentaba.
    #>
    param([Parameter(Mandatory=$true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $e = $ErrorRecord.Exception
    while ($e -is [System.Management.Automation.MethodInvocationException] -and $e.InnerException) {
        $e = $e.InnerException
    }
    if ($e -eq $ErrorRecord.Exception) { return $ErrorRecord }
    return (New-Object System.Management.Automation.ErrorRecord(
        $e, 'Descarga', [System.Management.Automation.ErrorCategory]::ConnectionError, $null))
}

function Read-PartialDownloadInfo {
    <# De donde salio un .part y con que se comprueba que no ha cambiado. #>
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $j = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        return [PSCustomObject]@{ Url = [string]$j.url; Validador = [string]$j.validador }
    }
    catch { return $null }
}

function Receive-HttpFile {
    <#
        UNA peticion: escribe en -Parte, siguiendo desde el byte -Desde si el
        servidor lo admite (206) o desde cero si no (200). Lanza la excepcion
        de red tal cual; reintentar es cosa de Invoke-Download.

        Si el servidor da un validador fuerte (ETag que no sea W/, o
        Last-Modified), se anota en -Meta: es lo que deja continuar en otra
        ejecucion sin riesgo de pegar trozos de dos versiones.
    #>
    param(
        [string]$Uri,
        [string]$Parte,
        [string]$Meta,
        [long]$Desde = 0,
        [string]$Validador,
        [string]$Proxy,
        [string]$Description
    )

    $req = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($Uri)
    $req.UserAgent = Get-KitUserAgent
    $req.AllowAutoRedirect = $true
    $req.Timeout = 300000
    # Sin datos en un minuto es un corte, aunque la conexion siga abierta: un
    # proxy que se queda colgado no tiene que dejar la descarga parada para
    # siempre. Lo que llevaba se conserva y se sigue.
    $req.ReadWriteTimeout = 60000

    # El mismo montaje que Add-ProxyToRequest le hace a Invoke-WebRequest.
    if ($Proxy) {
        $partes = Split-ProxyCredential -Proxy $Proxy
        $wp = New-Object System.Net.WebProxy($partes.Direccion)
        $wp.BypassProxyOnLocal = $false
        if ($partes.Credencial) { $wp.Credentials = $partes.Credencial.GetNetworkCredential() }
        else { $wp.UseDefaultCredentials = $true }
        $req.Proxy = $wp
    }

    if ($Desde -gt 0) {
        $req.AddRange($Desde)
        if ($Validador) { $req.Headers.Add('If-Range', $Validador) }
    }

    $resp = $req.GetResponse()
    try {
        $sigue = ($Desde -gt 0 -and [int]$resp.StatusCode -eq 206)
        $base = if ($sigue) { $Desde } else { [long]0 }
        $total = if ($resp.ContentLength -ge 0) { $base + $resp.ContentLength } else { [long]-1 }

        if (-not $sigue) {
            $etag = $resp.Headers['ETag']
            $nuevo = if ($etag -and -not $etag.StartsWith('W/')) { $etag } else { $resp.Headers['Last-Modified'] }
            if ($nuevo) {
                (@{ url = $Uri; validador = $nuevo } | ConvertTo-Json) | Set-Content -LiteralPath $Meta -Encoding UTF8
            }
            else {
                Remove-Item -LiteralPath $Meta -Force -ErrorAction SilentlyContinue
            }
        }

        $modo = if ($sigue) { [IO.FileMode]::Append } else { [IO.FileMode]::Create }
        $entrada = $resp.GetResponseStream()
        $salida = [IO.File]::Open($Parte, $modo, [IO.FileAccess]::Write, [IO.FileShare]::None)

        # Los scripts apagan el progreso porque el de Invoke-WebRequest frena
        # la descarga. Este se pinta cada medio segundo y no cuesta nada.
        $ProgressPreference = 'Continue'
        $reloj = [Diagnostics.Stopwatch]::StartNew()
        $pintado = -1000
        $hecho = $base
        try {
            $buffer = New-Object byte[] 81920
            while (($n = $entrada.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $salida.Write($buffer, 0, $n)
                $hecho += $n
                if ($reloj.ElapsedMilliseconds - $pintado -ge 500) {
                    $pintado = $reloj.ElapsedMilliseconds
                    $vel = ($hecho - $base) / [Math]::Max($reloj.Elapsed.TotalSeconds, 0.001) / 1MB
                    if ($total -gt 0) {
                        Write-Progress -Id 7 -Activity "Descargando $Description" -PercentComplete ([int](100 * $hecho / $total)) `
                                       -Status ("{0:N1} de {1:N1} MB  ({2:N1} MB/s)" -f ($hecho / 1MB), ($total / 1MB), $vel)
                    }
                    else {
                        Write-Progress -Id 7 -Activity "Descargando $Description" `
                                       -Status ("{0:N1} MB  ({1:N1} MB/s)" -f ($hecho / 1MB), $vel)
                    }
                }
            }
        }
        finally {
            $salida.Dispose()
            $entrada.Dispose()
            Write-Progress -Id 7 -Activity "Descargando $Description" -Completed
        }

        # Hay servidores y proxies que cierran antes de tiempo sin dar error:
        # el flujo termina y faltan bytes. Se trata como un corte.
        if ($total -gt 0 -and $hecho -lt $total) {
            throw (New-Object System.IO.IOException("La conexion se cerro a los $hecho de $total bytes"))
        }

        return [PSCustomObject]@{ Bytes = $hecho; Segundos = $reloj.Elapsed.TotalSeconds; Siguio = $sigue }
    }
    finally {
        $resp.Close()
    }
}

# --------------------------------------------------------------------------
# Cache de descargas
# --------------------------------------------------------------------------
#
# Solo entra lo que llego con hash oficial y cuadro con el: el nombre es el
# propio hash, asi que lo que se saca de aqui es lo mismo que se bajaria.
#
# En %LOCALAPPDATA% y no junto al kit: la carpeta de trabajo suele estar en
# OneDrive, y llenarla de cientos de MB de zips los subiria a la nube.

$KitDownloadCache = Join-Path $env:LOCALAPPDATA "CriisDevKit\descargas"
$script:KitDownloadCacheMaxBytes = 3GB

function Get-CachedDownload {
    <#
        La copia de la cache con ese hash, o $null. Se vuelve a comprobar el
        hash al sacarla: un archivo tocado en la cache no tiene que poder pasar
        por bueno solo por como se llama.
    #>
    param([string]$Hash)

    if ([string]::IsNullOrWhiteSpace($Hash) -or $env:CRIISDEVKIT_NOCACHE) { return $null }
    if (-not (Test-Path -LiteralPath $KitDownloadCache)) { return $null }

    $h = $Hash.Trim().ToLowerInvariant()
    $f = @(Get-ChildItem -LiteralPath $KitDownloadCache -Filter "$h-*" -File -ErrorAction SilentlyContinue)[0]
    if (-not $f) { return $null }

    $real = if ($h.Length -eq 128) { Get-FileSha512 -FilePath $f.FullName } else { Get-FileSha256 -FilePath $f.FullName }
    if ($real -ne $h) {
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        return $null
    }

    # La fecha de escritura hace de "ultimo uso" para saber que tirar primero.
    try { $f.LastWriteTimeUtc = [DateTime]::UtcNow } catch { }
    return $f.FullName
}

function Save-CachedDownload {
    <#
        Guarda una copia de lo recien descargado y verificado. Nunca es fatal:
        sin disco o sin permiso, simplemente no hay cache.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][string]$Hash
    )

    if ($env:CRIISDEVKIT_NOCACHE) { return }
    try {
        if (-not (Test-Path -LiteralPath $KitDownloadCache)) {
            New-Item -ItemType Directory -Path $KitDownloadCache -Force | Out-Null
        }
        $h = $Hash.Trim().ToLowerInvariant()
        $dest = Join-Path $KitDownloadCache ("$h-" + (Split-Path -Leaf $FilePath))
        Copy-Item -LiteralPath $FilePath -Destination $dest -Force
        Limit-DownloadCache
    }
    catch { }
}

function Limit-DownloadCache {
    <# Tira lo que lleva mas tiempo sin usarse hasta quedar por debajo del tope. #>
    param(
        [string]$Carpeta = $KitDownloadCache,
        [long]$Maximo = $script:KitDownloadCacheMaxBytes
    )

    $todo = @(Get-ChildItem -LiteralPath $Carpeta -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc)
    $suma = ($todo | Measure-Object -Property Length -Sum).Sum
    foreach ($f in $todo) {
        if ($suma -le $Maximo) { break }
        $suma -= $f.Length
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Get-DownloadCacheInfo {
    <# Cuantos archivos y cuanto ocupa la cache, para Doctor. #>
    $todo = @(Get-ChildItem -LiteralPath $KitDownloadCache -File -ErrorAction SilentlyContinue)
    return [PSCustomObject]@{
        Carpeta  = $KitDownloadCache
        Archivos = $todo.Count
        Bytes    = [long](($todo | Measure-Object -Property Length -Sum).Sum)
    }
}

function Invoke-Download {
    <#
    .SYNOPSIS
        Descarga un archivo de forma segura en un entorno corporativo.
    .DESCRIPTION
        - Detecta y usa el proxy (variables de entorno o proxy del sistema).
        - Reintenta solo los fallos transitorios.
        - Si la conexion se corta, sigue desde donde iba en vez de empezar de
          cero; y si se cae del todo, la siguiente ejecucion tambien.
        - Ensena el progreso: cuanto lleva, cuanto falta y a que velocidad.
        - Descarga a un archivo .part y solo lo publica si todo salio bien, para
          no dejar nunca un archivo a medias que parezca una descarga valida.
        - Verifica SHA-256 o SHA-512 si se le pasa uno, y entonces lo guarda en
          la cache de descargas: la proxima vez no hace falta la red.
        - Explica en castellano que fallo y como arreglarlo.
        Devuelve $true / $false; no lanza excepciones.

        Va con HttpWebRequest y no con Invoke-WebRequest porque en PowerShell
        5.1 este no deja mandar la cabecera Range, y sin ella no hay forma de
        pedir "lo que falta". El proxy se monta igual que antes, con las mismas
        funciones (Resolve-DownloadProxy y Split-ProxyCredential).
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

    $esperado = $null
    $algoritmo = $null
    if (-not [string]::IsNullOrWhiteSpace($Sha256)) {
        $esperado = $Sha256.Trim().ToLowerInvariant(); $algoritmo = 'SHA-256'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Sha512)) {
        $esperado = $Sha512.Trim().ToLowerInvariant(); $algoritmo = 'SHA-512'
    }

    # Lo que ya se bajo una vez y cuadra con su hash no se vuelve a bajar:
    # reinstalar con -Force o exportar despues de instalar repetia cientos de MB.
    $cache = Get-CachedDownload -Hash $esperado
    if ($cache) {
        Copy-Item -LiteralPath $cache -Destination $OutFile -Force
        Write-Log "  De la cache de descargas, sin red ($algoritmo verificado)" "SUCCESS"
        Write-SignerReport -FilePath $OutFile -Esperado $FirmanteEsperado
        return $true
    }

    # El espejo interno, si lo hay, antes que nada: todo lo de abajo -incluido
    # el mensaje de error- debe hablar de la URL por la que se salio de verdad.
    $Uri = Resolve-KitUrl -Uri $Uri

    $temp = "$OutFile.part"
    $meta = "$OutFile.part.json"

    # Una descarga a medias de otra ejecucion se continua SOLO si es de la misma
    # URL y el servidor dio con que comprobar que el archivo no ha cambiado
    # (ETag o Last-Modified, que se le devuelven en If-Range). Si no, se tira:
    # pegar dos trozos de archivos distintos daria uno que parece bueno.
    $desde = [long]0
    $validador = $null
    if (Test-Path -LiteralPath $temp) {
        $previa = Read-PartialDownloadInfo -Path $meta
        if ($previa -and $previa.Url -eq $Uri -and $previa.Validador) {
            $desde = (Get-Item -LiteralPath $temp).Length
            $validador = $previa.Validador
            Write-Log ("  Hay {0:N1} MB de una descarga anterior: se sigue desde ahi" -f ($desde / 1MB))
        }
        else {
            Remove-Item -LiteralPath $temp, $meta -Force -ErrorAction SilentlyContinue
        }
    }

    $proxy = Resolve-DownloadProxy -Uri ([Uri]$Uri)
    if ($proxy) { Write-Log "  Proxy detectado: $(Format-ProxyForDisplay $proxy)" }

    # Un corte que deja el archivo MAS LARGO que antes no cuenta como fallo: la
    # conexion va, solo se cae. Con un tope para no quedarse en bucle.
    $fallos = 0
    $intentos = 0
    while ($true) {
        $intentos++
        $antes = $desde
        try {
            $r = Receive-HttpFile -Uri $Uri -Parte $temp -Meta $meta -Desde $desde -Validador $validador `
                                  -Proxy $proxy -Description $Description
            break
        }
        catch {
            $err = ConvertTo-DownloadErrorRecord -ErrorRecord $_
            $status = Get-WebErrorStatus -ErrorRecord $err
            $desde = if (Test-Path -LiteralPath $temp) { (Get-Item -LiteralPath $temp).Length } else { [long]0 }
            $previa = Read-PartialDownloadInfo -Path $meta
            $validador = if ($previa) { $previa.Validador } else { $null }

            # 416: lo que habia no encaja con el archivo de ahora. Desde cero.
            if ($status -eq 416 -and $antes -gt 0 -and $intentos -lt 10) {
                Remove-Item -LiteralPath $temp, $meta -Force -ErrorAction SilentlyContinue
                $desde = [long]0; $validador = $null
                continue
            }

            $avanzo = $desde -gt $antes
            if (-not $avanzo) { $fallos++ }
            if ($fallos -le $Retries -and $intentos -lt 10 -and (Test-TransientError -ErrorRecord $err)) {
                if ($avanzo) {
                    Write-Log ("  Se corto a los {0:N1} MB; se sigue desde ahi..." -f ($desde / 1MB)) "WARN"
                }
                else {
                    Write-Log "  Intento $intentos fallo; reintentando..." "WARN"
                    Start-Sleep -Seconds (2 * $fallos)
                }
                continue
            }

            Write-Log "No se pudo descargar: $Description" "ERROR"
            Write-Log "  URL: $Uri" "ERROR"
            Write-Log "  $(Get-WebErrorText -ErrorRecord $err)" "ERROR"

            $hint = Get-DownloadErrorHint -ErrorRecord $err
            if ($hint) { Write-Log "  -> $hint" "WARN" }

            # Lo bajado se guarda solo si se podra continuar con garantias.
            if ($desde -gt 0 -and $validador) {
                Write-Log ("  Lo descargado ({0:N1} MB) se guarda: la proxima vez se sigue desde ahi." -f ($desde / 1MB))
            }
            else {
                Remove-Item -LiteralPath $temp, $meta -Force -ErrorAction SilentlyContinue
            }
            return $false
        }
    }

    Write-Log ("  {0:N1} MB en {1:N1} s" -f ($r.Bytes / 1MB), $r.Segundos)

    if ($esperado) {
        $obtenido = if ($algoritmo -eq 'SHA-256') { Get-FileSha256 -FilePath $temp } else { Get-FileSha512 -FilePath $temp }
        if ($obtenido -ne $esperado) {
            Write-Log "El archivo descargado no coincide con el hash oficial." "ERROR"
            Write-Log "  esperado: $esperado" "ERROR"
            Write-Log "  obtenido: $obtenido" "ERROR"
            Write-Log "  -> Descarga corrupta o alterada en transito. No se va a usar." "WARN"
            Remove-Item -LiteralPath $temp, $meta -Force -ErrorAction SilentlyContinue
            return $false
        }

        Write-Log "  $algoritmo verificado" "SUCCESS"
    }

    Remove-Item -LiteralPath $meta -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $OutFile) {
        Remove-Item -LiteralPath $OutFile -Force
    }
    Move-Item -LiteralPath $temp -Destination $OutFile -Force

    if ($esperado) { Save-CachedDownload -FilePath $OutFile -Hash $esperado }

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
