#Requires -Version 5.1
<#
    Pruebas de lib\Download.ps1.

    Casi todas cubren un fallo que existio de verdad. Se anotan con el sintoma
    que producian, porque un test sin contexto se acaba borrando cuando estorba.
#>

. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")
. (Join-Path $PSScriptRoot "Helpers.ps1")

# La cache de verdad vive en %LOCALAPPDATA%; aqui va a una carpeta temporal,
# que se retira al final del archivo.
$RaizDescargas = Join-Path ([IO.Path]::GetTempPath()) ("descargas-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $RaizDescargas -Force | Out-Null
$KitDownloadCache = Join-Path $RaizDescargas 'cache'

# Un proxy puesto en el entorno de quien ejecuta las pruebas no pinta nada
# contra 127.0.0.1, y podria desviar las peticiones.
$ProxyGuardado = @{ H = $env:HTTPS_PROXY; P = $env:HTTP_PROXY; A = $env:ALL_PROXY; N = $env:CRIISDEVKIT_NOCACHE }
$env:HTTPS_PROXY = $null; $env:HTTP_PROXY = $null; $env:ALL_PROXY = $null; $env:CRIISDEVKIT_NOCACHE = $null

function New-Contenido {
    param([int]$Bytes = 300000, [int]$Semilla = 7)
    $b = New-Object byte[] $Bytes
    (New-Object Random $Semilla).NextBytes($b)
    return ,$b
}

function Get-Sha256Bytes {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
}

function New-Destino {
    $d = Join-Path $RaizDescargas ([Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return (Join-Path $d 'archivo.zip')
}

Describe "Invoke-Download: cortes y reanudacion" {

    # Sin cache: aqui se cuentan peticiones, y la cache las ahorraria.
    $env:CRIISDEVKIT_NOCACHE = '1'
    Mock Write-Log { }
    Mock Start-Sleep { }
    $datos = New-Contenido
    $sha = Get-Sha256Bytes $datos

    It "descarga entera, verifica el hash y no deja restos" {
        $srv = Start-ServidorDePrueba -Contenido $datos
        try {
            $out = New-Destino
            Invoke-Download -Uri $srv.Url -OutFile $out -Sha256 $sha | Should Be $true
            Get-FileSha256 -FilePath $out | Should Be $sha
            Test-Path -LiteralPath "$out.part" | Should Be $false
            Test-Path -LiteralPath "$out.part.json" | Should Be $false
        }
        finally { & $srv.Parar }
    }

    # LA prueba del punto: antes un corte tiraba lo bajado y empezaba de cero.
    It "si la conexion se corta, sigue desde donde iba" {
        $srv = Start-ServidorDePrueba -Contenido $datos -Cortes 1 -CortarTras 120000
        try {
            $out = New-Destino
            Invoke-Download -Uri $srv.Url -OutFile $out -Sha256 $sha | Should Be $true
            Get-FileSha256 -FilePath $out | Should Be $sha

            $p = @($srv.Control.Peticiones)
            $p.Count | Should Be 2
            $p[1] | Should Match 'Range: bytes=120000-'
            $p[1] | Should Match 'If-Range: "v1"'
        }
        finally { & $srv.Parar }
    }

    # El caso traicionero: el servidor (o un proxy) cierra sin error y el flujo
    # simplemente se acaba. Sin comprobar la longitud, se daba por descargado
    # un archivo al que le faltaba el final.
    It "si el servidor cierra antes de tiempo sin dar error, tambien se sigue" {
        $srv = Start-ServidorDePrueba -Contenido $datos -Cortes 1 -CortarTras 120000 -CierreLimpio
        try {
            $out = New-Destino
            Invoke-Download -Uri $srv.Url -OutFile $out | Should Be $true
            (Get-Item -LiteralPath $out).Length | Should Be $datos.Length
            Get-FileSha256 -FilePath $out | Should Be $sha
        }
        finally { & $srv.Parar }
    }

    It "varios cortes seguidos que avanzan no agotan los reintentos" {
        $srv = Start-ServidorDePrueba -Contenido $datos -Cortes 4 -CortarTras 50000
        try {
            $out = New-Destino
            Invoke-Download -Uri $srv.Url -OutFile $out -Sha256 $sha -Retries 1 | Should Be $true
            Get-FileSha256 -FilePath $out | Should Be $sha
        }
        finally { & $srv.Parar }
    }

    It "un servidor que no entiende Range: empieza de cero y sale bien" {
        $srv = Start-ServidorDePrueba -Contenido $datos -Cortes 1 -CortarTras 120000 -SinRange
        try {
            $out = New-Destino
            Invoke-Download -Uri $srv.Url -OutFile $out -Sha256 $sha | Should Be $true
            Get-FileSha256 -FilePath $out | Should Be $sha
        }
        finally { & $srv.Parar }
    }

    # El fallo que destapo cambiar de motor: la WebException llega envuelta, y
    # sin desenvolverla un 404 no tenia codigo y se reintentaba como transitorio.
    It "un 404 no se reintenta" {
        $srv = Start-ServidorDePrueba -Contenido $datos -Estado 404
        try {
            Invoke-Download -Uri $srv.Url -OutFile (New-Destino) | Should Be $false
            @($srv.Control.Peticiones).Count | Should Be 1
        }
        finally { & $srv.Parar }
    }

    It "y su pista sigue siendo la del 404" {
        $srv = Start-ServidorDePrueba -Contenido $datos -Estado 404
        try {
            Invoke-Download -Uri $srv.Url -OutFile (New-Destino) | Out-Null
            Assert-MockCalled Write-Log -Scope It -ParameterFilter { $Message -match '404' -and $Message -match 'no existe' }
        }
        finally { & $srv.Parar }
    }

    It "con el hash equivocado no publica nada ni deja el .part" {
        $srv = Start-ServidorDePrueba -Contenido $datos
        try {
            $out = New-Destino
            Invoke-Download -Uri $srv.Url -OutFile $out -Sha256 ('0' * 64) | Should Be $false
            Test-Path -LiteralPath $out | Should Be $false
            Test-Path -LiteralPath "$out.part" | Should Be $false
            Test-Path -LiteralPath "$out.part.json" | Should Be $false
        }
        finally { & $srv.Parar }
    }
}

Describe "Invoke-Download: lo que dejo una ejecucion anterior" {

    $env:CRIISDEVKIT_NOCACHE = '1'
    Mock Write-Log { }
    Mock Start-Sleep { }
    $datos = New-Contenido
    $sha = Get-Sha256Bytes $datos

    function New-Previa {
        <# -Ajena: el trozo es de OTRO archivo, como si hubiera cambiado en el servidor. #>
        param([string]$Out, [string]$Url, [string]$Validador, [int]$Bytes = 100000, [switch]$Ajena)
        $origen = if ($Ajena) { New-Object byte[] $Bytes } else { $datos }
        [IO.File]::WriteAllBytes("$Out.part", $origen[0..($Bytes - 1)])
        if ($Url) { (@{ url = $Url; validador = $Validador } | ConvertTo-Json) | Set-Content -LiteralPath "$Out.part.json" }
    }

    It "sigue desde lo que habia si es de la misma URL y del mismo archivo" {
        $srv = Start-ServidorDePrueba -Contenido $datos
        try {
            $out = New-Destino
            New-Previa -Out $out -Url $srv.Url -Validador '"v1"'
            Invoke-Download -Uri $srv.Url -OutFile $out -Sha256 $sha | Should Be $true
            Get-FileSha256 -FilePath $out | Should Be $sha
            @($srv.Control.Peticiones)[0] | Should Match 'Range: bytes=100000-'
        }
        finally { & $srv.Parar }
    }

    # Si el archivo cambio en el servidor, If-Range hace que mande el nuevo
    # entero (200) en vez del trozo: pegar dos versiones daria un archivo roto.
    It "si el archivo cambio en el servidor, empieza de cero" {
        $srv = Start-ServidorDePrueba -Contenido $datos -ETag '"v2"'
        try {
            $out = New-Destino
            New-Previa -Out $out -Url $srv.Url -Validador '"v1"' -Ajena
            Invoke-Download -Uri $srv.Url -OutFile $out -Sha256 $sha | Should Be $true
            Get-FileSha256 -FilePath $out | Should Be $sha
        }
        finally { & $srv.Parar }
    }

    It "un .part sin saber de donde salio se tira, no se continua" {
        $srv = Start-ServidorDePrueba -Contenido $datos
        try {
            $out = New-Destino
            New-Previa -Out $out
            Invoke-Download -Uri $srv.Url -OutFile $out -Sha256 $sha | Should Be $true
            @($srv.Control.Peticiones)[0] | Should Not Match 'Range:'
        }
        finally { & $srv.Parar }
    }

    It "un .part de otra URL se tira" {
        $srv = Start-ServidorDePrueba -Contenido $datos
        try {
            $out = New-Destino
            New-Previa -Out $out -Url 'http://otro.sitio/archivo.zip' -Validador '"v1"'
            Invoke-Download -Uri $srv.Url -OutFile $out -Sha256 $sha | Should Be $true
            @($srv.Control.Peticiones)[0] | Should Not Match 'Range:'
        }
        finally { & $srv.Parar }
    }

    It "si lo que habia ya no cabe (416), empieza de cero" {
        $corto = $datos[0..49999]
        $srv = Start-ServidorDePrueba -Contenido $corto
        try {
            $out = New-Destino
            New-Previa -Out $out -Url $srv.Url -Validador '"v1"'
            Invoke-Download -Uri $srv.Url -OutFile $out -Sha256 (Get-Sha256Bytes $corto) | Should Be $true
            (Get-Item -LiteralPath $out).Length | Should Be 50000
        }
        finally { & $srv.Parar }
    }

    It "si se rinde, guarda lo bajado para la proxima vez" {
        # Cortes sin avanzar nada: se agotan los reintentos.
        $srv = Start-ServidorDePrueba -Contenido $datos -Cortes 99 -CortarTras 0
        try {
            $out = New-Destino
            New-Previa -Out $out -Url $srv.Url -Validador '"v1"'
            Invoke-Download -Uri $srv.Url -OutFile $out -Retries 1 | Should Be $false
            (Get-Item -LiteralPath "$out.part").Length | Should Be 100000
            Test-Path -LiteralPath "$out.part.json" | Should Be $true
        }
        finally { & $srv.Parar }
    }
}

Describe "Invoke-Download a traves de un proxy con usuario y clave" {

    # Lo que mas importa no romper al cambiar de motor: en la empresa todo pasa
    # por un proxy que pide credenciales. Antes iba con Invoke-WebRequest -Proxy
    # -ProxyCredential; ahora con un WebProxy montado a partir de lo mismo.
    $env:CRIISDEVKIT_NOCACHE = '1'
    Mock Write-Log { }
    Mock Start-Sleep { }
    $datos = New-Contenido -Bytes 20000 -Semilla 21
    $sha = Get-Sha256Bytes $datos
    $destinoFalso = 'http://descargas.ejemplo.test/runtime/archivo.zip'

    function Set-ProxyDePrueba {
        param([string]$Proxy)
        $env:HTTP_PROXY = $Proxy; $env:HTTPS_PROXY = $Proxy
    }

    It "pasa por el proxy y le manda las credenciales de la URL" {
        $srv = Start-ServidorDePrueba -Contenido $datos -ProxyBasic 'ACME\jperez:cl@ve:1'
        try {
            # Clave con @ y : escapados, y cuenta de dominio con %5C, como lo
            # documenta el kit.
            Set-ProxyDePrueba "http://ACME%5Cjperez:cl%40ve%3A1@$($srv.Proxy)"
            $out = New-Destino
            Invoke-Download -Uri $destinoFalso -OutFile $out -Sha256 $sha | Should Be $true
            Get-FileSha256 -FilePath $out | Should Be $sha

            # La peticion llego al proxy con la URL entera, que es como se le
            # pide algo a un proxy, y no directamente al destino.
            (@($srv.Control.Peticiones) -join "`n") | Should Match "GET $([regex]::Escape($destinoFalso)) HTTP"
        }
        finally { Set-ProxyDePrueba $null; & $srv.Parar }
    }

    It "con la clave equivocada falla sin reintentar y dice que la rechazo" {
        $srv = Start-ServidorDePrueba -Contenido $datos -ProxyBasic 'ACME\jperez:buena'
        try {
            Set-ProxyDePrueba "http://ACME%5Cjperez:mala@$($srv.Proxy)"
            Invoke-Download -Uri $destinoFalso -OutFile (New-Destino) | Should Be $false
            Assert-MockCalled Write-Log -Scope It -ParameterFilter { $Message -match 'rechazo tus credenciales' }
            Assert-MockCalled Start-Sleep -Scope It -Times 0
        }
        finally { Set-ProxyDePrueba $null; & $srv.Parar }
    }

    # La clave viaja en la URL del proxy: no puede acabar en lo que se imprime.
    It "la clave no sale en ningun mensaje" {
        $srv = Start-ServidorDePrueba -Contenido $datos -ProxyBasic 'u:otra'
        try {
            Set-ProxyDePrueba "http://u:SuperSecreta99@$($srv.Proxy)"
            Invoke-Download -Uri $destinoFalso -OutFile (New-Destino) | Out-Null
            Assert-MockCalled Write-Log -Scope It -Times 0 -ParameterFilter { $Message -match 'SuperSecreta99' }
            Assert-MockCalled Write-Log -Scope It -ParameterFilter { $Message -match 'Proxy detectado' }
        }
        finally { Set-ProxyDePrueba $null; & $srv.Parar }
    }

    It "un corte a traves del proxy tambien se reanuda" {
        $srv = Start-ServidorDePrueba -Contenido $datos -ProxyBasic 'u:c' -Cortes 1 -CortarTras 8000
        try {
            Set-ProxyDePrueba "http://u:c@$($srv.Proxy)"
            $out = New-Destino
            Invoke-Download -Uri $destinoFalso -OutFile $out -Sha256 $sha | Should Be $true
            (@($srv.Control.Peticiones) -join "`n") | Should Match 'Range: bytes=8000-'
        }
        finally { Set-ProxyDePrueba $null; & $srv.Parar }
    }
}

Describe "Cache de descargas" {

    $env:CRIISDEVKIT_NOCACHE = $null
    Mock Write-Log { }

    # Cada prueba con su propio contenido: si compartieran, la cache de una
    # serviria a la siguiente y se contarian peticiones que no hubo.
    It "lo bajado con hash se saca de la cache la segunda vez, sin red" {
        $datos = New-Contenido -Bytes 50000 -Semilla 11; $sha = Get-Sha256Bytes $datos
        $srv = Start-ServidorDePrueba -Contenido $datos
        try {
            Invoke-Download -Uri $srv.Url -OutFile (New-Destino) -Sha256 $sha | Should Be $true
            $out = New-Destino
            Invoke-Download -Uri $srv.Url -OutFile $out -Sha256 $sha | Should Be $true
            Get-FileSha256 -FilePath $out | Should Be $sha
            @($srv.Control.Peticiones).Count | Should Be 1
        }
        finally { & $srv.Parar }
    }

    It "sin hash no entra nada: no habria como saber que es lo mismo" {
        $otros = New-Contenido -Bytes 1234
        $srv = Start-ServidorDePrueba -Contenido $otros
        try {
            Invoke-Download -Uri $srv.Url -OutFile (New-Destino) | Should Be $true
            Invoke-Download -Uri $srv.Url -OutFile (New-Destino) | Should Be $true
            @($srv.Control.Peticiones).Count | Should Be 2
        }
        finally { & $srv.Parar }
    }

    # El nombre en la cache es el hash, pero se vuelve a comprobar al sacarlo.
    It "una copia tocada en la cache no pasa por buena" {
        $datos = New-Contenido -Bytes 50000 -Semilla 12; $sha = Get-Sha256Bytes $datos
        $srv = Start-ServidorDePrueba -Contenido $datos
        try {
            Invoke-Download -Uri $srv.Url -OutFile (New-Destino) -Sha256 $sha | Out-Null
            $enCache = @(Get-ChildItem -LiteralPath $KitDownloadCache -Filter "$sha-*")[0]
            [IO.File]::WriteAllBytes($enCache.FullName, [byte[]](1, 2, 3))

            $out = New-Destino
            Invoke-Download -Uri $srv.Url -OutFile $out -Sha256 $sha | Should Be $true
            Get-FileSha256 -FilePath $out | Should Be $sha
            @($srv.Control.Peticiones).Count | Should Be 2
        }
        finally { & $srv.Parar }
    }

    It "con CRIISDEVKIT_NOCACHE no se usa" {
        $datos = New-Contenido -Bytes 50000 -Semilla 13; $sha = Get-Sha256Bytes $datos
        $srv = Start-ServidorDePrueba -Contenido $datos
        try {
            Invoke-Download -Uri $srv.Url -OutFile (New-Destino) -Sha256 $sha | Out-Null
            $antes = @($srv.Control.Peticiones).Count
            $env:CRIISDEVKIT_NOCACHE = '1'
            Invoke-Download -Uri $srv.Url -OutFile (New-Destino) -Sha256 $sha | Should Be $true
            @($srv.Control.Peticiones).Count | Should Be ($antes + 1)
        }
        finally { $env:CRIISDEVKIT_NOCACHE = $null; & $srv.Parar }
    }

    It "Limit-DownloadCache tira primero lo que lleva mas sin usarse" {
        $c = Join-Path $RaizDescargas 'cache-limite'
        New-Item -ItemType Directory -Path $c -Force | Out-Null
        foreach ($i in 1..3) {
            $f = Join-Path $c "h$i-a.zip"
            [IO.File]::WriteAllBytes($f, (New-Object byte[] 1000))
            (Get-Item -LiteralPath $f).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-10 + $i)
        }
        Limit-DownloadCache -Carpeta $c -Maximo 2000
        (@(Get-ChildItem -LiteralPath $c).Name | Sort-Object) -join ',' | Should Be 'h2-a.zip,h3-a.zip'
    }
}

Remove-Item -LiteralPath $RaizDescargas -Recurse -Force -ErrorAction SilentlyContinue
$env:HTTPS_PROXY = $ProxyGuardado.H; $env:HTTP_PROXY = $ProxyGuardado.P; $env:ALL_PROXY = $ProxyGuardado.A; $env:CRIISDEVKIT_NOCACHE = $ProxyGuardado.N

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
