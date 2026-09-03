#Requires -Version 5.1
<#
    Red corporativa: la CA de la empresa y el proxy en cada herramienta

    Parte de lib\Common.ps1, que es quien carga este archivo. No se toma
    por separado: los scripts siguen haciendo un unico dot-source de
    Common.ps1 y no se enteran de esta division.
#>


$CorpCaFile = Join-Path $env:LOCALAPPDATA "CriisDevKit\corp-ca.cer"

# La misma CA en PEM. Hacen falta las dos: keytool importa DER, y Node, pip y
# Git solo entienden PEM. Guardar una y convertir al vuelo cada vez seria peor:
# estas rutas acaban dentro de archivos de configuracion que tienen que seguir
# siendo validos cuando el kit no esta corriendo.
$CorpCaPem = Join-Path $env:LOCALAPPDATA "CriisDevKit\corp-ca.pem"

function Write-CorpCaPem {
    <#
        Escribe el PEM a partir del .cer guardado. PEM es el DER en base64 entre
        dos lineas de guiones, y se parte en lineas de 64 porque hay lectores
        -entre ellos algunos de OpenSSL- que no aceptan una sola linea larga.
    #>
    param(
        [string]$Origen = $CorpCaFile,
        [string]$Destino = $CorpCaPem
    )

    if (-not (Test-Path -LiteralPath $Origen)) { return $null }

    $x = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($Origen)
    $b64 = [Convert]::ToBase64String($x.RawData)
    $lineas = @('-----BEGIN CERTIFICATE-----')
    for ($i = 0; $i -lt $b64.Length; $i += 64) {
        $lineas += $b64.Substring($i, [Math]::Min(64, $b64.Length - $i))
    }
    $lineas += '-----END CERTIFICATE-----'

    Set-Content -LiteralPath $Destino -Value ($lineas -join "`n") -Encoding ASCII
    return $Destino
}

function Set-GitCorpCa {
    <#
        Le dice al Git del kit en que CA confiar, escribiendo en SU PROPIO
        etc\gitconfig y no en el ~\.gitconfig del usuario, que es personal.

        Ese archivo es el nivel "system" de ese Git portable: aplica siempre que
        se use ese git, tambien fuera de los shells del kit, y desaparece con el
        si se desinstala.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$GitPath,
        [string]$PemPath = $CorpCaPem,
        [switch]$Quitar
    )

    $exe = Join-Path $GitPath "cmd\git.exe"
    $cfg = Join-Path $GitPath "etc\gitconfig"
    if (-not (Test-Path $exe)) { return $false }

    if ($Quitar) {
        & cmd /c "`"$exe`" config -f `"$cfg`" --unset http.sslCAInfo 2>&1" | Out-Null
        return $true
    }

    if (-not (Test-Path -LiteralPath $PemPath)) { return $false }
    & cmd /c "`"$exe`" config -f `"$cfg`" http.sslCAInfo `"$($PemPath -replace '\\','/')`" 2>&1" | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Get-GitCorpCa {
    param([Parameter(Mandatory=$true)][string]$GitPath)

    $exe = Join-Path $GitPath "cmd\git.exe"
    $cfg = Join-Path $GitPath "etc\gitconfig"
    if (-not (Test-Path $exe) -or -not (Test-Path $cfg)) { return $null }

    $v = & cmd /c "`"$exe`" config -f `"$cfg`" --get http.sslCAInfo 2>&1"
    if ($LASTEXITCODE -ne 0) { return $null }
    return ([string]$v).Trim()
}

function Set-PipCorpCa {
    <#
        pip.ini dentro de la propia carpeta de Python, que es el nivel de
        configuracion de ESA instalacion. No se toca el pip.ini del usuario
        (%APPDATA%\pip), que vale para todos sus Python y no es del kit.

        Se escribe 'cert', que es lo que usa pip para verificar TLS.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$PythonPath,
        [string]$PemPath = $CorpCaPem,
        [switch]$Quitar
    )

    $ini = Join-Path $PythonPath "pip.ini"

    if ($Quitar) {
        Remove-Item -LiteralPath $ini -Force -ErrorAction SilentlyContinue
        return $true
    }

    if (-not (Test-Path -LiteralPath $PemPath)) { return $false }

    # Se reescribe entero y no se parchea: el kit es el unico que escribe aqui,
    # y un .ini a medio parchear es peor que uno regenerado.
    $lineas = @(
        "# Escrito por CriisDevKit (Use-CorpCert). Se puede borrar sin miedo.",
        "[global]",
        "cert = $PemPath"
    )
    $proxy = Resolve-DownloadProxy -Uri ([Uri]"https://pypi.org")
    if ($proxy) { $lineas += "proxy = $proxy" }

    Set-Content -LiteralPath $ini -Value ($lineas -join "`n") -Encoding ASCII
    return $true
}

function Get-PipCorpCa {
    param([Parameter(Mandatory=$true)][string]$PythonPath)

    $ini = Join-Path $PythonPath "pip.ini"
    if (-not (Test-Path -LiteralPath $ini)) { return $null }
    $m = [regex]::Match((Get-Content -LiteralPath $ini -Raw), '(?m)^\s*cert\s*=\s*(.+)$')
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value.Trim()
}

function Write-TextoSinBom {
    <#
        Escribe texto tal cual, sin BOM y sin anadir salto al final.

        Set-Content -Encoding UTF8 en PowerShell 5.1 antepone SIEMPRE un BOM de
        tres bytes y anade un salto. En un archivo del kit da igual, pero aqui se
        reescribe el settings.xml que trae Maven, y quitar el bloque tiene que
        dejarlo EXACTAMENTE como estaba, byte a byte.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Ruta,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Texto
    )
    [IO.File]::WriteAllText($Ruta, $Texto, (New-Object System.Text.UTF8Encoding($false)))
}

function Set-MavenCorpProxy {
    <#
        Maven NO lee HTTP_PROXY ni HTTPS_PROXY. Es la diferencia con npm, pip y
        git, que si las respetan y por eso no necesitan nada del kit para el
        proxy: a Maven hay que decirselo en un settings.xml o no sale a la red.

        Se escribe en conf\settings.xml de ESA instalacion de Maven, no en el
        ~\.m2\settings.xml del usuario, que es personal y suele tener sus
        credenciales de repositorio dentro.

        El TLS no hace falta tocarlo: Maven corre sobre el JDK, asi que ya va por
        el cacerts que arregla la parte de Java.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$MavenPath,
        [switch]$Quitar
    )

    $cfg = Join-Path $MavenPath "conf\settings.xml"
    if (-not (Test-Path -LiteralPath $cfg)) { return $false }

    $texto = Get-Content -LiteralPath $cfg -Raw
    $marcaIni = '<!-- criisdevkit:proxy -->'
    $marcaFin = '<!-- /criisdevkit:proxy -->'

    # Fuera el bloque anterior, si lo hubiera. Con marcas propias no se toca
    # nada que hubiera escrito el usuario o la empresa en ese archivo.
    #
    # Se come tambien el salto de linea que lo precede. Sin eso, cada ciclo de
    # poner y quitar dejaba una linea en blanco de mas y el settings.xml crecia
    # unos bytes cada vez.
    $limpio = [regex]::Replace($texto,
                               '\r?\n?[ \t]*' + [regex]::Escape($marcaIni) + '.*?' + [regex]::Escape($marcaFin),
                               '', 'Singleline')

    if ($Quitar) {
        if ($limpio -ne $texto) { Write-TextoSinBom -Ruta $cfg -Texto $limpio }
        return $true
    }

    $proxy = Resolve-DownloadProxy -Uri ([Uri]"https://repo.maven.apache.org")
    if (-not $proxy) { return $false }

    $u = [Uri]$proxy
    $cred = Split-ProxyCredential -Proxy $proxy

    $bloque = @($marcaIni, '  <proxies>', '    <proxy>',
                '      <id>criisdevkit</id>', '      <active>true</active>',
                "      <protocol>$($u.Scheme)</protocol>",
                "      <host>$($u.Host)</host>",
                "      <port>$($u.Port)</port>")
    if ($cred -and $cred.Credencial) {
        $bloque += "      <username>$($cred.Credencial.UserName)</username>"
        $bloque += "      <password>$($cred.Credencial.GetNetworkCredential().Password)</password>"
    }
    $bloque += @('    </proxy>', '  </proxies>', $marcaFin)

    # Va justo despues de <settings ...>, que es donde Maven espera <proxies>.
    $nuevo = [regex]::Replace($limpio, '(<settings[^>]*>)', "`$1`n" + ($bloque -join "`n"), 'Singleline')
    if ($nuevo -eq $limpio) { return $false }

    Write-TextoSinBom -Ruta $cfg -Texto $nuevo
    return $true
}

function Get-MavenCorpProxy {
    param([Parameter(Mandatory=$true)][string]$MavenPath)

    $cfg = Join-Path $MavenPath "conf\settings.xml"
    if (-not (Test-Path -LiteralPath $cfg)) { return $null }
    $m = [regex]::Match((Get-Content -LiteralPath $cfg -Raw),
                        '<!-- criisdevkit:proxy -->.*?<host>([^<]+)</host>.*?<port>([^<]+)</port>', 'Singleline')
    if (-not $m.Success) { return $null }
    return "$($m.Groups[1].Value):$($m.Groups[2].Value)"
}

function Get-TlsChainRoot {
    <#
        La CA raiz con la que se firma el certificado que devuelve un host HTTPS.

        Sirve para reconocer una interceptacion TLS: si tres dominios que no
        tienen nada que ver entre si llegan firmados por la MISMA raiz, esa raiz
        es un intermediario de la empresa y no la CA publica de cada uno.

        Devuelve $null si no se pudo conectar; eso no distingue "sin red" de
        "bloqueado", y por eso quien llama prueba con varios hosts.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$HostName,
        [int]$Port = 443
    )

    $cliente = $null
    try {
        $cliente = New-Object System.Net.Sockets.TcpClient
        $tarea = $cliente.ConnectAsync($HostName, $Port)
        if (-not $tarea.Wait(5000)) { return $null }

        # El callback acepta cualquier cadena a proposito: aqui no se valida
        # nada, solo se quiere VER quien firma.
        $ssl = New-Object System.Net.Security.SslStream($cliente.GetStream(), $false,
                    { param($a, $b, $c, $d) $true })
        $ssl.AuthenticateAsClient($HostName)

        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
        $cadena = New-Object System.Security.Cryptography.X509Certificates.X509Chain
        $cadena.ChainPolicy.RevocationMode = 'NoCheck'
        $cadena.ChainPolicy.VerificationFlags = 'AllFlags'
        $null = $cadena.Build($cert)

        if ($cadena.ChainElements.Count -eq 0) { return $null }
        $raiz = $cadena.ChainElements[$cadena.ChainElements.Count - 1].Certificate

        return [PSCustomObject]@{
            Subject    = $raiz.Subject
            Thumbprint = $raiz.Thumbprint
            Cert       = $raiz
        }
    }
    catch { return $null }
    finally {
        if ($ssl) { $ssl.Dispose() }
        if ($cliente) { $cliente.Close() }
    }
}

function Get-CertSha256 {
    <#
        La huella SHA-256 de un certificado en el formato con dos puntos que usa
        keytool, para poder compararlas directamente.
    #>
    param([Parameter(Mandatory=$true)]$Cert)

    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Cert.RawData)).Replace('-', ':') }
    finally { $sha.Dispose() }
}

function Get-JdkTrustedFingerprints {
    <#
        Las huellas SHA-256 de todas las CA en las que confia un JDK de fabrica.
        Un JDK trae unas 118: las publicas y reconocidas.
    #>
    param([Parameter(Mandatory=$true)][string]$JdkPath)

    $keytool = Join-Path $JdkPath "bin\keytool.exe"
    $store   = Join-Path $JdkPath "lib\security\cacerts"
    if (-not (Test-Path $keytool) -or -not (Test-Path $store)) { return @() }

    $salida = & cmd /c "`"$keytool`" -list -keystore `"$store`" -storepass changeit 2>&1"
    if ($LASTEXITCODE -ne 0) { return @() }

    return @($salida |
        Where-Object { $_ -match 'SHA-?256[^:]*:\s*([0-9A-Fa-f:]{95})' } |
        ForEach-Object { $Matches[1].ToUpperInvariant() })
}

function Find-CorpCa {
    <#
        Busca la CA de la empresa mirando quien firma varios dominios publicos y
        comprobando si Java ya confia en esa raiz.

        La primera version de esto comparaba las raices entre si: si varios
        dominios sin relacion llegaban firmados por la MISMA, se daba por
        interceptado. Al probarlo en una red normal salio que api.adoptium.net y
        registry.npmjs.org comparten raiz de verdad -GlobalSign ECC Root CA R4-,
        asi que esa regla daba falsos positivos por pura casualidad.

        La pregunta buena no es "?se repite la raiz?" sino "?la conoce Java?".
        Un JDK trae las CA publicas de fabrica; la de un proxy corporativo no
        esta ahi por definicion. Y ademas es exactamente la condicion en la que
        importarla sirve de algo, que es lo que se quiere decidir.

        Necesita un JDK del kit para tener contra que comparar.
    #>
    param([string[]]$Hosts = @('api.adoptium.net', 'registry.npmjs.org', 'pypi.org'))

    $lineas = @(Get-KitJdkLines)
    if ($lineas.Count -eq 0) {
        return [PSCustomObject]@{ Interceptado = $false; Motivo = 'no hay ningun JDK con el que comparar'; Cert = $null }
    }
    $conocidas = @(Get-JdkTrustedFingerprints -JdkPath (Join-Path (Join-Path $WorkspaceRoot "Java") "jdk-$($lineas[-1])"))
    if ($conocidas.Count -eq 0) {
        return [PSCustomObject]@{ Interceptado = $false; Motivo = 'no se pudo leer el almacen del JDK'; Cert = $null }
    }

    $vistos = 0
    foreach ($h in $Hosts) {
        $r = Get-TlsChainRoot -HostName $h
        if (-not $r) { continue }
        $vistos++

        if ($conocidas -notcontains (Get-CertSha256 -Cert $r.Cert)) {
            return [PSCustomObject]@{
                Interceptado = $true
                Motivo       = "$h llega firmado por una raiz que Java no conoce"
                Cert         = $r.Cert
                Subject      = $r.Subject
                Thumbprint   = $r.Thumbprint
            }
        }
    }

    if ($vistos -eq 0) {
        return [PSCustomObject]@{ Interceptado = $false; Motivo = 'no se pudo comprobar (sin respuesta)'; Cert = $null }
    }
    return [PSCustomObject]@{
        Interceptado = $false
        Motivo       = "las $vistos raices son publicas y Java ya las conoce"
        Cert         = $null
    }
}

function Get-JdkTrustedAliases {
    <#
        Los alias del almacen de certificados de un JDK. Se lee con keytool
        porque el formato del cacerts no es leible de otra forma sin admin ni
        librerias externas.
    #>
    param([Parameter(Mandatory=$true)][string]$JdkPath)

    $keytool = Join-Path $JdkPath "bin\keytool.exe"
    $store   = Join-Path $JdkPath "lib\security\cacerts"
    if (-not (Test-Path $keytool) -or -not (Test-Path $store)) { return @() }

    $salida = & cmd /c "`"$keytool`" -list -keystore `"$store`" -storepass changeit 2>&1"
    if ($LASTEXITCODE -ne 0) { return @() }

    # Cada entrada empieza por "<alias>, <fecha>, trustedCertEntry". El alias no
    # lleva comas, asi que basta con lo que hay antes de la primera.
    return @($salida | Where-Object { $_ -match 'trustedCertEntry' } |
             ForEach-Object { ($_ -split ',')[0].Trim() })
}

function Import-JdkCertificate {
    <#
        Mete un certificado en el almacen de un JDK del kit.

        NO pide admin: el cacerts vive dentro de la carpeta del JDK, que la puso
        el propio usuario. Es el punto entero de hacerlo aqui.

        Hace falta porque Java tiene su PROPIO almacen: importar la CA de la
        empresa en el almacen de Windows arregla PowerShell, .NET y el navegador,
        pero a Java no le sirve de nada, y Maven y Gradle corren sobre Java.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$JdkPath,
        [Parameter(Mandatory=$true)][string]$CertPath,
        [string]$Alias = 'criisdevkit-corp'
    )

    $keytool = Join-Path $JdkPath "bin\keytool.exe"
    $store   = Join-Path $JdkPath "lib\security\cacerts"

    if (-not (Test-Path $keytool)) {
        return [PSCustomObject]@{ Ok = $false; Salida = @("no hay keytool en $JdkPath") }
    }
    if (-not (Test-Path $store)) {
        return [PSCustomObject]@{ Ok = $false; Salida = @("no hay cacerts en $JdkPath") }
    }

    # -noprompt no basta si el alias ya existe: keytool falla en vez de
    # reemplazar, asi que se retira antes y da igual que no estuviera.
    & cmd /c "`"$keytool`" -delete -alias $Alias -keystore `"$store`" -storepass changeit 2>&1" | Out-Null

    $salida = & cmd /c "`"$keytool`" -importcert -noprompt -trustcacerts -alias $Alias -file `"$CertPath`" -keystore `"$store`" -storepass changeit 2>&1"
    return [PSCustomObject]@{ Ok = ($LASTEXITCODE -eq 0); Salida = @($salida) }
}

function Remove-JdkCertificate {
    param(
        [Parameter(Mandatory=$true)][string]$JdkPath,
        [string]$Alias = 'criisdevkit-corp'
    )

    $keytool = Join-Path $JdkPath "bin\keytool.exe"
    $store   = Join-Path $JdkPath "lib\security\cacerts"
    if (-not (Test-Path $keytool) -or -not (Test-Path $store)) { return $false }

    & cmd /c "`"$keytool`" -delete -alias $Alias -keystore `"$store`" -storepass changeit 2>&1" | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Get-CorpNetStatus {
    <#
        Que herramientas del kit estan preparadas para una red que inspecciona el
        HTTPS, y cuales no. Una fila por instalacion.

        Cada una lo resuelve en un sitio distinto y por un motivo distinto, y esa
        es justo la razon de que exista este comando: no hay un interruptor
        unico que valga para todas.
    #>
    $filas = @()
    $hayCa = Test-Path -LiteralPath $CorpCaPem

    foreach ($l in @(Get-KitJdkLines)) {
        $jdk = Join-Path (Join-Path $WorkspaceRoot "Java") "jdk-$l"
        $filas += [PSCustomObject]@{
            Nombre = "jdk-$l"; Que = 'CA'; Donde = 'cacerts'
            Ok = ((Get-JdkTrustedAliases -JdkPath $jdk) -contains 'criisdevkit-corp')
        }
    }

    foreach ($d in @(Get-ChildItem (Join-Path $WorkspaceRoot "Git") -Directory -ErrorAction SilentlyContinue)) {
        if (-not (Test-Path (Join-Path $d.FullName "cmd\git.exe"))) { continue }
        $filas += [PSCustomObject]@{
            Nombre = $d.Name; Que = 'CA'; Donde = 'etc\gitconfig'
            Ok = (-not [string]::IsNullOrWhiteSpace((Get-GitCorpCa -GitPath $d.FullName)))
        }
    }

    foreach ($d in @(Get-ChildItem (Join-Path $WorkspaceRoot "Python") -Directory -ErrorAction SilentlyContinue)) {
        if (-not (Test-Path (Join-Path $d.FullName "python.exe"))) { continue }
        $filas += [PSCustomObject]@{
            Nombre = $d.Name; Que = 'CA'; Donde = 'pip.ini'
            Ok = (-not [string]::IsNullOrWhiteSpace((Get-PipCorpCa -PythonPath $d.FullName)))
        }
    }

    # Node y Angular lo llevan en su shell, que se regenera con la variable en
    # cuanto hay PEM; basta con mirar si el shell la trae.
    foreach ($par in @(
        @{ Raiz = 'Node';    Patron = '*-shell.bat' },
        @{ Raiz = 'Angular'; Patron = 'shell-v*.bat' }
    )) {
        foreach ($d in @(Get-ChildItem (Join-Path $WorkspaceRoot $par.Raiz) -Directory -ErrorAction SilentlyContinue)) {
            $sh = @(Get-ChildItem -LiteralPath $d.FullName -Filter $par.Patron -ErrorAction SilentlyContinue)
            if ($sh.Count -eq 0) { continue }
            $filas += [PSCustomObject]@{
                Nombre = $d.Name; Que = 'CA'; Donde = (Split-Path -Leaf $sh[0].FullName)
                Ok = ((Get-Content -LiteralPath $sh[0].FullName -Raw) -match 'NODE_EXTRA_CA_CERTS')
            }
        }
    }

    # Maven y Gradle solo aparecen si HAY un proxy que configurarles. Sin proxy
    # no les falta nada, y decir "sin proxy" en rojo en un equipo que sale
    # directo a internet seria un aviso de algo que no es un problema.
    $hayProxy = $null -ne (Resolve-DownloadProxy -Uri ([Uri]"https://repo.maven.apache.org"))

    if ($hayProxy) {
        foreach ($d in @(Get-ChildItem (Join-Path $WorkspaceRoot "Maven") -Directory -ErrorAction SilentlyContinue)) {
            if (-not (Test-Path (Join-Path $d.FullName "bin\mvn.cmd"))) { continue }
            $filas += [PSCustomObject]@{
                Nombre = $d.Name; Que = 'proxy'; Donde = 'conf\settings.xml'
                Ok = (-not [string]::IsNullOrWhiteSpace((Get-MavenCorpProxy -MavenPath $d.FullName)))
            }
        }

        foreach ($d in @(Get-ChildItem (Join-Path $WorkspaceRoot "Gradle") -Directory -ErrorAction SilentlyContinue)) {
            $sh = @(Get-ChildItem -LiteralPath $d.FullName -Filter 'gradle*-shell.bat' -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notmatch '-java\d+-' })
            if ($sh.Count -eq 0) { continue }
            $filas += [PSCustomObject]@{
                Nombre = $d.Name; Que = 'proxy'; Donde = (Split-Path -Leaf $sh[0].FullName)
                Ok = ((Get-Content -LiteralPath $sh[0].FullName -Raw) -match 'GRADLE_OPTS')
            }
        }
    }

    return @($filas | ForEach-Object {
        $_ | Add-Member -NotePropertyName HayCa -NotePropertyValue $hayCa -PassThru
    })
}

function Update-GeneratedShells {
    <#
        Rehace los shells que llevan la CA o el proxy dentro: los de Node y
        Angular por NODE_EXTRA_CA_CERTS, y los de Gradle por GRADLE_OPTS.

        Hace falta porque en esos tres la configuracion no vive en un archivo
        aparte sino en el propio .bat, asi que la unica forma de aplicarla es
        volver a escribirlo.

        Devuelve una linea por shell rehecho.
    #>
    $resumen = @()

    foreach ($d in @(Get-ChildItem (Join-Path $WorkspaceRoot "Node") -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -notmatch '^node-(\d+)$') { continue }
        $exe = Join-Path $d.FullName "node.exe"
        if (-not (Test-Path $exe)) { continue }

        $v = (& cmd /c "`"$exe`" --version 2>&1") -replace '^v', ''
        if ([string]::IsNullOrWhiteSpace($v)) { continue }
        Write-NodeShell -NodePath $d.FullName -Version $v | Out-Null
        $resumen += "Shell rehecho: $($d.Name)"
    }

    # El Angular del kit guarda su Node al lado, en la misma carpeta Angular\.
    $angularRoot = Join-Path $WorkspaceRoot "Angular"
    $nodeDirs = @(Get-ChildItem -LiteralPath $angularRoot -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -match '^node-v(.+)-win-x64$' })

    foreach ($d in @(Get-ChildItem -LiteralPath $angularRoot -Directory -ErrorAction SilentlyContinue)) {
        # El -match va AQUI y no en un Where-Object: dentro de Where-Object,
        # $Matches se queda en el ambito hijo y el cuerpo del bucle leeria el de
        # la ultima comparacion que hubiera hecho antes -la de Node, dos lineas
        # mas arriba-, o nada.
        if ($d.Name -notmatch '^angular-v(\d+)$') { continue }
        $num = $Matches[1]

        # Con varias Node no se puede deducir con cual se instalo, y escribir el
        # shell con la equivocada seria peor que no tocarlo.
        if ($nodeDirs.Count -ne 1) { continue }

        Write-AngularShell -AngularPath $d.FullName -NodePath $nodeDirs[0].FullName `
                           -Version $num -NodeVersion ($nodeDirs[0].Name -replace '^node-v|-win-x64$', '') | Out-Null
        $resumen += "Shell rehecho: $($d.Name)"
    }

    foreach ($d in @(Get-ChildItem (Join-Path $WorkspaceRoot "Gradle") -Directory -ErrorAction SilentlyContinue)) {
        $jars = @(Get-ChildItem -Path (Join-Path $d.FullName "lib\gradle-launcher-*.jar") -ErrorAction SilentlyContinue)
        if ($jars.Count -eq 0 -or $jars[0].Name -notmatch 'gradle-launcher-([\d.]+)\.jar') { continue }
        $v = $Matches[1]

        $porDefecto = Join-Path $d.FullName "gradle$((Get-ToolLine -Version $v) -replace '\.','')-shell.bat"
        $jh = Get-ShellJavaHome -ShellBat $porDefecto
        Write-BuildToolShell -Tool Gradle -ToolPath $d.FullName -Version $v -JavaHome $jh | Out-Null
        Write-BuildToolShellsPorJdk -Tool Gradle -ToolPath $d.FullName -Version $v | Out-Null
        $resumen += "Shell rehecho: $($d.Name)"
    }

    return $resumen
}

function Sync-CorpNet {
    <#
        Aplica la CA y el proxy a todas las herramientas del kit que lo
        necesiten. Se llama despues de instalar cualquiera de ellas, por el mismo
        motivo que los shells de Maven: una recien instalada nace sin nada de
        esto y falla con un error de certificado o de red que no lo menciona.

        Devuelve una linea por cosa tocada; nada si no hacia falta.
    #>
    $resumen = @()

    $resumen += @(Sync-JdkCertificates)

    if (Test-Path -LiteralPath $CorpCaPem) {
        foreach ($d in @(Get-ChildItem (Join-Path $WorkspaceRoot "Git") -Directory -ErrorAction SilentlyContinue)) {
            if (-not (Test-Path (Join-Path $d.FullName "cmd\git.exe"))) { continue }
            if (Get-GitCorpCa -GitPath $d.FullName) { continue }
            if (Set-GitCorpCa -GitPath $d.FullName) { $resumen += "CA de la empresa puesta en: $($d.Name)" }
        }

        foreach ($d in @(Get-ChildItem (Join-Path $WorkspaceRoot "Python") -Directory -ErrorAction SilentlyContinue)) {
            if (-not (Test-Path (Join-Path $d.FullName "python.exe"))) { continue }
            if (Get-PipCorpCa -PythonPath $d.FullName) { continue }
            if (Set-PipCorpCa -PythonPath $d.FullName) { $resumen += "CA de la empresa puesta en: $($d.Name) (pip)" }
        }
    }

    # Maven y Gradle solo si hay proxy: sin el, no hay nada que escribir.
    foreach ($d in @(Get-ChildItem (Join-Path $WorkspaceRoot "Maven") -Directory -ErrorAction SilentlyContinue)) {
        if (-not (Test-Path (Join-Path $d.FullName "bin\mvn.cmd"))) { continue }
        if (Get-MavenCorpProxy -MavenPath $d.FullName) { continue }
        if (Set-MavenCorpProxy -MavenPath $d.FullName) { $resumen += "Proxy puesto en: $($d.Name)" }
    }

    return $resumen
}

function Sync-JdkCertificates {
    <#
        Reaplica la CA guardada a los JDK que no la tengan.

        Se llama al instalar un JDK, por el mismo motivo que los shells de Maven:
        un JDK nuevo -o uno reinstalado con -Force, que rehace el cacerts- nace
        sin la CA de la empresa y sus descargas fallan con un error de
        certificado que no menciona nada de esto.
    #>
    param([string]$Alias = 'criisdevkit-corp')

    if (-not (Test-Path -LiteralPath $CorpCaFile)) { return @() }

    $resumen = @()
    foreach ($l in @(Get-KitJdkLines)) {
        $jdk = Join-Path (Join-Path $WorkspaceRoot "Java") "jdk-$l"
        if ((Get-JdkTrustedAliases -JdkPath $jdk) -contains $Alias) { continue }

        $r = Import-JdkCertificate -JdkPath $jdk -CertPath $CorpCaFile -Alias $Alias
        if ($r.Ok) { $resumen += "jdk-$l" }
    }

    if ($resumen.Count -eq 0) { return @() }
    return @("CA de la empresa puesta en: $($resumen -join ', ')")
}
