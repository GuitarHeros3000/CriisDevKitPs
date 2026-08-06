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
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

# --------------------------------------------------------------------------
# Descargas
# --------------------------------------------------------------------------

function Resolve-DownloadProxy {
    <#
        Devuelve la URL del proxy a usar, o $null si se sale directo a internet.
        Se mira primero las variables de entorno porque son las que el usuario
        ya suele tener puestas para npm, pip o curl.
    #>
    param([Parameter(Mandatory=$true)][Uri]$Uri)

    $explicit = if ($Uri.Scheme -eq 'https') { $env:HTTPS_PROXY } else { $env:HTTP_PROXY }
    if ([string]::IsNullOrWhiteSpace($explicit)) { $explicit = $env:ALL_PROXY }
    if (-not [string]::IsNullOrWhiteSpace($explicit)) { return $explicit }

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

function Get-WebErrorText {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)

    $parts = @($ErrorRecord.Exception.Message)
    $inner = $ErrorRecord.Exception.InnerException
    while ($inner) {
        $parts += $inner.Message
        $inner = $inner.InnerException
    }
    return ($parts -join ' ')
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

    $proxy = Resolve-DownloadProxy -Uri ([Uri]$Uri)
    if ($proxy) {
        Write-Log "  Proxy detectado: $(Format-ProxyForDisplay $proxy)"
        $params.Proxy = $proxy
        $params.ProxyUseDefaultCredentials = $true
    }

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

    $proxy = Resolve-DownloadProxy -Uri ([Uri]$Uri)
    if ($proxy) {
        $params.Proxy = $proxy
        $params.ProxyUseDefaultCredentials = $true
    }

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

    return ($Version -eq (ConvertTo-SemverObject $c))
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
    $lines = @(
        "@echo off",
        "set PATH=$NodePath;$npmPrefix;%PATH%",
        "set NPM_CONFIG_PREFIX=$npmPrefix",
        "set NPM_CONFIG_CACHE=$npmCache",
        "title Angular v$Version Development Shell",
        "echo.",
        "echo ============================================",
        "echo   Angular v$Version Development Shell",
        "echo ============================================",
        "echo.",
        "echo Node: $NodeVersion",
        "echo Angular CLI: v$Version",
        "echo.",
        "echo Proyectos: $AngularPath\projects",
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

    $lines = @(
        "@echo off",
        "set PATH=$PythonPath;$scripts;%PATH%",
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

    $lines = @(
        "@echo off",
        "set PATH=$bin;%PATH%",
        "set JAVA_HOME=$JdkPath",
        "title Java $Major Shell",
        "echo.",
        "echo ============================================",
        "echo   Java $Major Shell",
        "echo ============================================",
        "echo.",
        "echo Release: $Release",
        "echo JAVA_HOME: $JdkPath",
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

function Get-PythonArchiveInfo {
    param([Parameter(Mandatory=$true)][string]$FullVersion)

    $file = "python-$FullVersion-embed-amd64.zip"
    return [PSCustomObject]@{
        FileName = $file
        Url      = "https://www.python.org/ftp/python/$FullVersion/$file"
    }
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

    $proxy = Resolve-DownloadProxy -Uri ([Uri]$Uri)
    if ($proxy) {
        $params.Proxy = $proxy
        $params.ProxyUseDefaultCredentials = $true
    }

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

    $proxy = Resolve-DownloadProxy -Uri ([Uri]$Uri)
    if ($proxy) {
        $params.Proxy = $proxy
        $params.ProxyUseDefaultCredentials = $true
    }

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
