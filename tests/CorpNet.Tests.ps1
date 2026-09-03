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

Describe "Get-CertSha256" {

    $tmp = New-CarpetaTemporal
    $cer = New-CertificadoDePrueba -Carpeta $tmp
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($cer)

    # El formato con dos puntos no es cosmetico: es el que imprime keytool, y se
    # compara directamente contra su salida en Get-JdkTrustedFingerprints.
    It "devuelve la huella en el formato de keytool" {
        $h = Get-CertSha256 -Cert $cert
        $h | Should Match '^[0-9A-F]{2}(:[0-9A-F]{2}){31}$'
        $h.Length | Should Be 95
    }

    It "es estable entre llamadas" {
        (Get-CertSha256 -Cert $cert) | Should Be (Get-CertSha256 -Cert $cert)
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

    It "Get-JdkTrustedFingerprints devuelve una lista vacia, no nulo" {
        @(Get-JdkTrustedFingerprints -JdkPath $vacio).Count | Should Be 0
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
