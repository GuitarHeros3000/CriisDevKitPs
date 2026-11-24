#Requires -Version 5.1
<#
    lib\CorpNet.ps1: la CA de la empresa y el proxy en cada herramienta.

    Estas 635 lineas eran las UNICAS de la libreria sin una sola prueba, y son
    justo las que escriben dentro de la configuracion del usuario: el gitconfig
    del Git portable, el pip.ini de cada Python, el settings.xml de Maven y el
    cacerts de cada JDK. Si algo se tuerce ahi, le rompes el git o el pip a
    alguien en una maquina corporativa donde no puede pedir ayuda.

    QUE NO SE PRUEBA AQUI, y no se disimula: nada que necesite keytool, git.exe
    o salir a la red. De esas funciones se cubre lo que si se puede -que se
    nieguen a hacer nada cuando falta la herramienta, en vez de reventar- y el
    resto sigue dependiendo de probarlo en una maquina corporativa de verdad
    (ver docs\pendientes.md).

    Ninguna prueba toca el CorpCaFile ni el CorpCaPem reales: todo pasa por
    carpetas temporales que se crean y se borran aqui.
#>

$KitRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $KitRoot "lib\Common.ps1")
. (Join-Path $PSScriptRoot "Helpers.ps1")

# Un certificado autofirmado de verdad, generado una vez y fijado aqui. Hace
# falta uno real porque Write-CorpCaPem lo carga con X509Certificate2 y lee su
# RawData; un archivo con bytes inventados no pasaria de ahi. Se deja constante
# en vez de generarlo en cada ejecucion para que la prueba no dependa de poder
# escribir en el almacen de certificados del usuario.
$CertB64 = (
    'MIICFzCCAYCgAwIBAgIQJ/qaO2PZcLxLo5QOtc90+DANBgkqhkiG9w0BAQsFADAgMR4wHAYDVQQD' +
    'DBVDcmlpc0RldktpdCBQcnVlYmEgQ0EwIBcNMjYwOTAzMTkwMTEwWhgPMjA1NjA5MDMxOTExMTBa' +
    'MCAxHjAcBgNVBAMMFUNyaWlzRGV2S2l0IFBydWViYSBDQTCBnzANBgkqhkiG9w0BAQEFAAOBjQAw' +
    'gYkCgYEAms96y8z1b/XAwF6xCunBLSuENwvM0pQ/r/fHR6Cxqd1JlBj624V8VpH/uiOVKY8Dw/MR' +
    '4W4/tBegSr665wWWC9f/gYVW1qgGe9mJEey5QAvPDgObkr0+xOcG44tHAewdSFxGOkj5fHW8O3gm' +
    'ayAMV30V01Os2w0eJs/qTY0F6rkCAwEAAaNQME4wDgYDVR0PAQH/BAQDAgWgMB0GA1UdJQQWMBQG' +
    'CCsGAQUFBwMCBggrBgEFBQcDATAdBgNVHQ4EFgQU9M+wvgtMSGrBOytsvCw2kto1noswDQYJKoZI' +
    'hvcNAQELBQADgYEAQ6vKDvM5HVcds1fDd34Ldmbxa8MSfLketdqsZwh1s4k3ALJEIoXmb64oPRcZ' +
    'XuIGAi7ottC2mZZe4leSqXKmehnewol9h1Nmwt+73NUPcJDG+VG7i4zhi/2BzaozKWv4IHNatprc' +
    'SatRxjtkfFQxHAaNfQ5znDq0d/uKCi036xY='
)

# Una sola raiz para todo el archivo, que se retira al final del todo. Antes cada
# prueba limpiaba lo suyo DENTRO de su It, y bastaba con que una fallara para
# dejarse la carpeta puesta. Se vio contando lo que quedaba en %TEMP% despues de
# las corridas de mutacion, que es cuando las pruebas fallan a proposito: justo
# el caso en el que la limpieza tiene que funcionar igual.
$RaizTmp = Join-Path ([IO.Path]::GetTempPath()) ("corpnet-{0}" -f [guid]::NewGuid())
New-Item -ItemType Directory -Path $RaizTmp -Force | Out-Null

function New-CarpetaTemporal {
    $d = Join-Path $RaizTmp ([guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return $d
}

function New-CertificadoDePrueba {
    param([string]$Carpeta)
    $ruta = Join-Path $Carpeta "corp-ca.cer"
    [IO.File]::WriteAllBytes($ruta, [Convert]::FromBase64String($CertB64))
    return $ruta
}

# El settings.xml que trae Maven, recortado a lo que importa aqui.
$SettingsBase = @'
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0">
  <localRepository>${user.home}/.m2/repository</localRepository>
  <servers>
    <server>
      <id>interno</id>
      <username>jperez</username>
    </server>
  </servers>
</settings>
'@

function New-MavenDePrueba {
    param([string]$Carpeta)
    $conf = Join-Path $Carpeta "conf"
    New-Item -ItemType Directory -Path $conf -Force | Out-Null
    # Sin BOM y sin salto anadido, como lo trae Maven: es lo que permite
    # comprobar despues que quitar el bloque lo deja byte a byte igual.
    [IO.File]::WriteAllText((Join-Path $conf "settings.xml"), $SettingsBase, (New-Object System.Text.UTF8Encoding($false)))
    return $Carpeta
}

Describe "Write-TextoSinBom" {

    $tmp = New-CarpetaTemporal

    # Existe porque Set-Content -Encoding UTF8 antepone SIEMPRE un BOM y anade un
    # salto. En el settings.xml de Maven eso importa: quitar el bloque del kit
    # tiene que devolverlo EXACTAMENTE como estaba.
    It "no antepone BOM" {
        $f = Join-Path $tmp "a.txt"
        Write-TextoSinBom -Ruta $f -Texto "hola"
        $b = [IO.File]::ReadAllBytes($f)
        @($b[0], $b[1], $b[2]) -join ',' | Should Not Be '239,187,191'
    }

    It "no anade un salto al final" {
        $f = Join-Path $tmp "b.txt"
        Write-TextoSinBom -Ruta $f -Texto "hola"
        [IO.File]::ReadAllBytes($f).Length | Should Be 4
    }

    It "escribe el texto tal cual, saltos incluidos" {
        $f = Join-Path $tmp "c.txt"
        Write-TextoSinBom -Ruta $f -Texto "uno`r`ndos"
        [IO.File]::ReadAllText($f) | Should Be "uno`r`ndos"
    }

    It "admite texto vacio sin quejarse" {
        $f = Join-Path $tmp "d.txt"
        Write-TextoSinBom -Ruta $f -Texto ""
        [IO.File]::ReadAllBytes($f).Length | Should Be 0
    }

}

Describe "Write-CorpCaPem" {

    $tmp = New-CarpetaTemporal
    $cer = New-CertificadoDePrueba -Carpeta $tmp
    $pem = Join-Path $tmp "corp-ca.pem"

    It "devuelve nulo si no hay .cer del que partir" {
        Write-CorpCaPem -Origen (Join-Path $tmp "no-existe.cer") -Destino $pem | Should BeNullOrEmpty
    }

    It "escribe un PEM con sus dos lineas de guiones" {
        Write-CorpCaPem -Origen $cer -Destino $pem | Should Be $pem

        $lineas = @(Get-Content -LiteralPath $pem)
        $lineas[0]  | Should Be '-----BEGIN CERTIFICATE-----'
        $lineas[-1] | Should Be '-----END CERTIFICATE-----'
    }

    # Hay lectores -algunos de OpenSSL- que no aceptan una sola linea larga.
    It "parte el base64 en lineas de 64" {
        Write-CorpCaPem -Origen $cer -Destino $pem | Out-Null

        $cuerpo = @(Get-Content -LiteralPath $pem | Where-Object { $_ -notmatch '^-----' })
        $cuerpo.Count | Should BeGreaterThan 1

        # Todas de 64 menos la ultima, que es el resto.
        foreach ($l in $cuerpo[0..($cuerpo.Count - 2)]) { $l.Length | Should Be 64 }
        $cuerpo[-1].Length | Should BeLessThan 65
    }

    It "el PEM contiene el mismo certificado que el .cer" {
        Write-CorpCaPem -Origen $cer -Destino $pem | Out-Null

        $cuerpo = ((Get-Content -LiteralPath $pem | Where-Object { $_ -notmatch '^-----' }) -join '')
        $cuerpo | Should Be ([Convert]::ToBase64String([IO.File]::ReadAllBytes($cer)))
    }

}

Describe "La cadena de un sitio y su CA" {

    # Paso en el primer equipo del trabajo: la cadena se rehacia solo con el
    # certificado del sitio, el intermedio del proxy no estaba en Windows, y se
    # puso como "la CA de la empresa" el del sitio (CN=gradle.org). No sirvio.
    $c = New-CadenaDePrueba

    It "solo con el del sitio, la cadena se queda en el" {
        $cadena = @(Get-CertChain -Cert $c.Sitio)
        $cadena.Count | Should Be 1
        $cadena[0].Thumbprint | Should Be $c.Sitio.Thumbprint
    }

    It "con los que manda el servidor, llega hasta la raiz" {
        $cadena = @(Get-CertChain -Cert $c.Sitio -Extra @($c.Intermedia, $c.Raiz))
        @($cadena | ForEach-Object { $_.Thumbprint }) -join ',' |
            Should Be (@($c.Sitio, $c.Intermedia, $c.Raiz | ForEach-Object { $_.Thumbprint }) -join ',')
    }

    It "el del sitio no es de una CA; la intermedia y la raiz si" {
        Test-CertEsAutoridad -Cert $c.Sitio | Should Be $false
        Test-CertEsAutoridad -Cert $c.Intermedia | Should Be $true
        Test-CertEsAutoridad -Cert $c.Raiz | Should Be $true
    }

    It "una raiz antigua sin Basic Constraints cuenta como CA por ser autofirmada" {
        $antigua = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(, [Convert]::FromBase64String($CertB64))
        @($antigua.Extensions | Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension] }).Count | Should Be 0
        Test-CertEsAutoridad -Cert $antigua | Should Be $true
    }

    # Por eso se compara por clave: Java la acepta de ancla con cualquiera de
    # sus versiones.
    It "Get-CertKeyId: igual para dos versiones de la misma CA, distinto entre CA" {
        $c.Cruzada.Thumbprint | Should Not Be $c.Intermedia.Thumbprint
        Get-CertKeyId -Cert $c.Cruzada | Should Be (Get-CertKeyId -Cert $c.Intermedia)
        Get-CertKeyId -Cert $c.Raiz | Should Not Be (Get-CertKeyId -Cert $c.Intermedia)
    }
}

Describe "Get-PemCertificates" {

    # Lo que escribe keytool -list -rfc, en espanol, con dos entradas.
    $c = New-CadenaDePrueba
    function Pem($Cert) {
        $b64 = [Convert]::ToBase64String($Cert.RawData)
        "-----BEGIN CERTIFICATE-----`n" + (($b64 -split '(.{64})' | Where-Object { $_ }) -join "`n") + "`n-----END CERTIFICATE-----"
    }
    $salida = "Tipo de Almacen de Claves: JKS`nSu almacen de claves contiene 2 entradas`n`n" +
              "Nombre de Alias: uno`nFecha de Creacion: 19/11/2026`nTipo de Entrada: trustedCertEntry`n`n$(Pem $c.Raiz)`n`n`n" +
              "Nombre de Alias: dos`nTipo de Entrada: trustedCertEntry`n`n$(Pem $c.Intermedia)`n"

    It "saca cada certificado, sin lo que hay alrededor" {
        $certs = @(Get-PemCertificates -Texto $salida)
        $certs.Count | Should Be 2
        $certs[0].Thumbprint | Should Be $c.Raiz.Thumbprint
        $certs[1].Thumbprint | Should Be $c.Intermedia.Thumbprint
    }

    It "se salta un bloque roto y sigue con los demas" {
        $roto = "-----BEGIN CERTIFICATE-----`nMIIBroto==`n-----END CERTIFICATE-----`n" + $salida
        @(Get-PemCertificates -Texto $roto).Count | Should Be 2
    }

    It "sin bloques, una lista vacia" {
        @(Get-PemCertificates -Texto 'keytool error: java.io.IOException').Count | Should Be 0
        @(Get-PemCertificates -Texto '').Count | Should Be 0
    }
}

Describe "Find-CorpCa" {

    $c = New-CadenaDePrueba
    $cadena = @($c.Sitio, $c.Intermedia, $c.Raiz)
    $hosts = @('uno.prueba', 'dos.prueba')
    function Raiz($Cadena) { [PSCustomObject]@{ Subject = $Cadena[-1].Subject; Thumbprint = $Cadena[-1].Thumbprint; Cert = $Cadena[-1]; EsAutoridad = (Test-CertEsAutoridad -Cert $Cadena[-1]); Cadena = $Cadena } }

    # Paso en casa, con un JDK 8: Windows llega hasta GlobalSign Root CA, que
    # ese JDK no trae, pero Java valida por GTS Root R4, el eslabon de antes.
    It "una red normal: Java conoce la clave de uno de los que firman, aunque no la de la cima" {
        Mock Get-JdkTrustedKeys { @('otra', (Get-CertKeyId -Cert $c.Cruzada)) }
        Mock Get-TlsChainRoot { Raiz $cadena }
        (Find-CorpCa -Hosts $hosts -JdkPath 'C:\jdk').Interceptado | Should Be $false
    }

    It "interceptado: devuelve la cima de la cadena, que es la CA" {
        Mock Get-JdkTrustedKeys { @('otra') }
        Mock Get-TlsChainRoot { Raiz $cadena }
        $r = Find-CorpCa -Hosts $hosts -JdkPath 'C:\jdk'
        $r.Interceptado | Should Be $true
        $r.Cert.Thumbprint | Should Be $c.Raiz.Thumbprint
    }

    # Un proxy puede usar la misma clave en todos los sitios: con la del sitio
    # puesta por error, se daba por arreglado y no se arreglaba nunca.
    It "el del sitio no cuenta aunque Java tenga su clave" {
        Mock Get-JdkTrustedKeys { @(Get-CertKeyId -Cert $c.Sitio) }
        Mock Get-TlsChainRoot { Raiz $cadena }
        (Find-CorpCa -Hosts $hosts -JdkPath 'C:\jdk').Interceptado | Should Be $true
    }

    It "si solo se ve el del sitio, interceptado pero sin nada que poner" {
        Mock Get-JdkTrustedKeys { @('otra') }
        Mock Get-TlsChainRoot { Raiz @($c.Sitio) }
        $r = Find-CorpCa -Hosts $hosts -JdkPath 'C:\jdk'
        $r.Interceptado | Should Be $true
        $r.Cert | Should BeNullOrEmpty
        $r.Motivo | Should Match 'no se ve la CA'
    }

    It "si un sitio solo ensena el suyo y otro la cadena entera, se queda con la CA" {
        Mock Get-JdkTrustedKeys { @('otra') }
        Mock Get-TlsChainRoot { Raiz @($c.Sitio) } -ParameterFilter { $HostName -eq 'uno.prueba' }
        Mock Get-TlsChainRoot { Raiz $cadena } -ParameterFilter { $HostName -eq 'dos.prueba' }
        (Find-CorpCa -Hosts $hosts -JdkPath 'C:\jdk').Cert.Thumbprint | Should Be $c.Raiz.Thumbprint
    }
}

Describe "Get-JdkCacertsPath" {

    # Paso: solo se miraba lib\security\cacerts, y en el JDK 8 esta en
    # jre\lib\security\cacerts. Con el JDK 8 de un proyecto de Android de 2019,
    # la CA de la empresa no se podia poner ("no hay cacerts").
    $tmp = New-CarpetaTemporal

    It "el de un JDK de ahora: lib\security\cacerts" {
        $j = Join-Path $tmp 'jdk-21'
        New-Item -ItemType Directory -Path (Join-Path $j 'lib\security') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $j 'lib\security\cacerts'), 'x')
        Get-JdkCacertsPath -JdkPath $j | Should Be (Join-Path $j 'lib\security\cacerts')
    }

    It "el del JDK 8: jre\lib\security\cacerts" {
        $j = Join-Path $tmp 'jdk-8'
        New-Item -ItemType Directory -Path (Join-Path $j 'jre\lib\security') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $j 'jre\lib\security\cacerts'), 'x')
        Get-JdkCacertsPath -JdkPath $j | Should Be (Join-Path $j 'jre\lib\security\cacerts')
    }
}

Describe "Set-MavenCorpProxy y Get-MavenCorpProxy" {

    # Maven NO lee HTTP_PROXY: hay que escribirselo en el settings.xml o no sale
    # a la red. Y ese archivo puede tener credenciales del usuario dentro, asi
    # que el kit escribe entre marcas propias y no toca nada mas.
    Mock Resolve-DownloadProxy { return 'http://proxy.empresa:8080' }

    It "mete el bloque justo despues de <settings>" {
        $mvn = New-MavenDePrueba -Carpeta (New-CarpetaTemporal)
        Set-MavenCorpProxy -MavenPath $mvn | Should Be $true

        $txt = Get-Content -LiteralPath (Join-Path $mvn "conf\settings.xml") -Raw
        $txt | Should Match '<settings[^>]*>\s*<!-- criisdevkit:proxy -->'
        $txt | Should Match '<host>proxy\.empresa</host>'
        $txt | Should Match '<port>8080</port>'

    }

    It "Get- lo lee de vuelta" {
        $mvn = New-MavenDePrueba -Carpeta (New-CarpetaTemporal)
        Set-MavenCorpProxy -MavenPath $mvn | Out-Null

        Get-MavenCorpProxy -MavenPath $mvn | Should Be 'proxy.empresa:8080'

    }

    It "no toca lo que ya habia en el archivo" {
        $mvn = New-MavenDePrueba -Carpeta (New-CarpetaTemporal)
        Set-MavenCorpProxy -MavenPath $mvn | Out-Null

        $txt = Get-Content -LiteralPath (Join-Path $mvn "conf\settings.xml") -Raw
        $txt | Should Match '<id>interno</id>'
        $txt | Should Match '<username>jperez</username>'

    }

    # LA prueba de esta seccion: quitar tiene que dejar el archivo EXACTAMENTE
    # como estaba. Es un archivo del usuario, no del kit.
    It "quitarlo deja el archivo byte a byte como estaba" {
        $mvn = New-MavenDePrueba -Carpeta (New-CarpetaTemporal)
        $cfg = Join-Path $mvn "conf\settings.xml"
        $antes = [IO.File]::ReadAllBytes($cfg)

        Set-MavenCorpProxy -MavenPath $mvn | Out-Null
        Set-MavenCorpProxy -MavenPath $mvn -Quitar | Should Be $true

        $despues = [IO.File]::ReadAllBytes($cfg)
        $despues.Length | Should Be $antes.Length
        (@(Compare-Object $antes $despues)).Count | Should Be 0

    }

    # Cada ciclo de poner y quitar dejaba una linea en blanco de mas, y el
    # settings.xml crecia unos bytes cada vez. De ahi el \r?\n? del patron.
    It "poner y quitar diez veces no engorda el archivo" {
        $mvn = New-MavenDePrueba -Carpeta (New-CarpetaTemporal)
        $cfg = Join-Path $mvn "conf\settings.xml"
        $antes = (Get-Item $cfg).Length

        for ($i = 0; $i -lt 10; $i++) {
            Set-MavenCorpProxy -MavenPath $mvn | Out-Null
            Set-MavenCorpProxy -MavenPath $mvn -Quitar | Out-Null
        }

        (Get-Item $cfg).Length | Should Be $antes

    }

    It "ponerlo dos veces no duplica el bloque" {
        $mvn = New-MavenDePrueba -Carpeta (New-CarpetaTemporal)
        Set-MavenCorpProxy -MavenPath $mvn | Out-Null
        Set-MavenCorpProxy -MavenPath $mvn | Out-Null

        $txt = Get-Content -LiteralPath (Join-Path $mvn "conf\settings.xml") -Raw
        ([regex]::Matches($txt, '<id>criisdevkit</id>')).Count | Should Be 1

    }

    It "sin settings.xml no hace nada y lo dice" {
        $vacio = New-CarpetaTemporal
        Set-MavenCorpProxy -MavenPath $vacio | Should Be $false
        Get-MavenCorpProxy -MavenPath $vacio | Should BeNullOrEmpty
    }

    It "sin bloque puesto, Get- devuelve nulo" {
        $mvn = New-MavenDePrueba -Carpeta (New-CarpetaTemporal)
        Get-MavenCorpProxy -MavenPath $mvn | Should BeNullOrEmpty
    }

    # Paso de verdad: con una clave como "a&b" el settings.xml quedaba invalido
    # y Maven no arrancaba, mientras la funcion devolvia $true. Con "a$1b" era
    # peor: Regex.Replace leia el $1 y la clave salia cambiada por "<settings>".
    Context "con usuario y clave que llevan caracteres especiales" {

        $claves = @('a&b', 'a<b>c', 'a$1b', 'a$&b', "comi'lla""s", 'normal123')

        It "la lista de claves no esta vacia" {
            $claves.Count | Should Not Be 0
        }

        foreach ($clave in $claves) {
            It "con la clave [$clave] el XML sigue siendo valido y la clave llega igual" {
                $script:proxyDePrueba = "http://ACME%5Cjperez:$([Uri]::EscapeDataString($clave))@proxy.empresa:8080"
                Mock Resolve-DownloadProxy { return $script:proxyDePrueba }

                $mvn = New-MavenDePrueba -Carpeta (New-CarpetaTemporal)
                Set-MavenCorpProxy -MavenPath $mvn | Should Be $true

                [xml]$doc = Get-Content -LiteralPath (Join-Path $mvn "conf\settings.xml") -Raw
                $doc.settings.proxies.proxy.password | Should BeExactly $clave
                $doc.settings.proxies.proxy.username | Should BeExactly 'ACME\jperez'
            }
        }
    }

    It "un settings.xml que ya venia roto no se toca" {
        $mvn = New-CarpetaTemporal
        New-Item -ItemType Directory -Path (Join-Path $mvn "conf") -Force | Out-Null
        $cfg = Join-Path $mvn "conf\settings.xml"
        [IO.File]::WriteAllText($cfg, "<settings>`n  <servers>`n</settings>")
        $antes = [IO.File]::ReadAllBytes($cfg)

        Set-MavenCorpProxy -MavenPath $mvn 3>$null | Should Be $false
        (@(Compare-Object $antes ([IO.File]::ReadAllBytes($cfg)))).Count | Should Be 0
    }

    Context "sin proxy configurado" {
        Mock Resolve-DownloadProxy { return $null }

        It "no escribe nada: sin proxy no hay bloque que poner" {
            $mvn = New-MavenDePrueba -Carpeta (New-CarpetaTemporal)
            $cfg = Join-Path $mvn "conf\settings.xml"
            $antes = [IO.File]::ReadAllBytes($cfg)

            Set-MavenCorpProxy -MavenPath $mvn | Should Be $false
            (@(Compare-Object $antes ([IO.File]::ReadAllBytes($cfg)))).Count | Should Be 0

        }
    }
}

Describe "Set-PipCorpCa y Get-PipCorpCa" {

    Mock Resolve-DownloadProxy { return $null }

    It "escribe el pip.ini con el cert" {
        $py = New-CarpetaTemporal
        $pem = Join-Path $py "corp-ca.pem"
        Set-Content -LiteralPath $pem -Value "-----BEGIN CERTIFICATE-----" -Encoding ASCII

        Set-PipCorpCa -PythonPath $py -PemPath $pem | Should Be $true
        Get-PipCorpCa -PythonPath $py | Should Be $pem

    }

    It "sin PEM no escribe nada" {
        $py = New-CarpetaTemporal
        Set-PipCorpCa -PythonPath $py -PemPath (Join-Path $py "no-existe.pem") | Should Be $false
        Test-Path -LiteralPath (Join-Path $py "pip.ini") | Should Be $false
    }

    It "-Quitar borra el pip.ini" {
        $py = New-CarpetaTemporal
        $pem = Join-Path $py "corp-ca.pem"
        Set-Content -LiteralPath $pem -Value "x" -Encoding ASCII
        Set-PipCorpCa -PythonPath $py -PemPath $pem | Out-Null

        Set-PipCorpCa -PythonPath $py -Quitar | Should Be $true
        Test-Path -LiteralPath (Join-Path $py "pip.ini") | Should Be $false
        Get-PipCorpCa -PythonPath $py | Should BeNullOrEmpty

    }

    It "sin pip.ini, Get- devuelve nulo en vez de fallar" {
        $py = New-CarpetaTemporal
        Get-PipCorpCa -PythonPath $py | Should BeNullOrEmpty
    }

    Context "con proxy" {
        Mock Resolve-DownloadProxy { return 'http://proxy.empresa:8080' }

        # La clave del proxy va al pip.ini y no a la linea de comandos: un
        # argumento --proxy queda visible para cualquier proceso del equipo.
        It "anade la linea proxy" {
            $py = New-CarpetaTemporal
            $pem = Join-Path $py "corp-ca.pem"
            Set-Content -LiteralPath $pem -Value "x" -Encoding ASCII

            Set-PipCorpCa -PythonPath $py -PemPath $pem | Out-Null
            (Get-Content -LiteralPath (Join-Path $py "pip.ini") -Raw) | Should Match 'proxy = http://proxy\.empresa:8080'

        }
    }
}

Describe "Se niegan a actuar cuando falta la herramienta" {

    # keytool y git.exe no estan en esta maquina, y ese es justo el caso: una
    # instalacion a medias o una carpeta equivocada. Lo que NO puede pasar es
    # que revienten o que digan que si.
    $vacio = New-CarpetaTemporal

    It "Import-JdkCertificate avisa de que no hay keytool" {
        $r = Import-JdkCertificate -JdkPath $vacio -CertPath "x.cer"
        $r.Ok | Should Be $false
        ($r.Salida -join ' ') | Should Match 'keytool'
    }

    It "Remove-JdkCertificate devuelve falso" {
        Remove-JdkCertificate -JdkPath $vacio | Should Be $false
    }

    It "Get-JdkTrustedAliases devuelve una lista vacia, no nulo" {
        @(Get-JdkTrustedAliases -JdkPath $vacio).Count | Should Be 0
    }

    It "Get-JdkTrustedKeys devuelve una lista vacia, no nulo" {
        @(Get-JdkTrustedKeys -JdkPath $vacio).Count | Should Be 0
    }

    It "Set-GitCorpCa devuelve falso sin git.exe" {
        Set-GitCorpCa -GitPath $vacio | Should Be $false
    }

    It "Get-GitCorpCa devuelve nulo sin git.exe" {
        Get-GitCorpCa -GitPath $vacio | Should BeNullOrEmpty
    }

}

# La unica limpieza, fuera de todo Describe: se ejecuta aunque alguna prueba
# haya fallado, que es justo cuando importa no dejar basura.
Remove-Item -LiteralPath $RaizTmp -Recurse -Force -ErrorAction SilentlyContinue
