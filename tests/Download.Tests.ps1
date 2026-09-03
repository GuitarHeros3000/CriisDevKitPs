#Requires -Version 5.1
<#
    Pruebas de lib\Download.ps1.

    Casi todas cubren un fallo que existio de verdad. Se anotan con el sintoma
    que producian, porque un test sin contexto se acaba borrando cuando estorba.
#>

. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

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
