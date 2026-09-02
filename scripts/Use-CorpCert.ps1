#Requires -Version 5.1
<#
.SYNOPSIS
    Use-CorpCert.ps1 - Mete la CA de tu empresa en los JDK del kit.
.DESCRIPTION
    Muchas redes corporativas abren el HTTPS para inspeccionarlo: el trafico
    llega firmado por una CA de la empresa y no por la del sitio real. Windows
    lo acepta porque IT metio esa CA en el almacen del sistema, y por eso el
    navegador y PowerShell funcionan.

    Java NO usa ese almacen. Tiene el suyo -lib\security\cacerts- y ahi no esta.
    Por eso el kit descarga el JDK sin problema y luego el primer 'mvn install'
    falla con PKIX path building failed, que no menciona ni el proxy ni la
    empresa. Maven, Gradle y cualquier herramienta Java van por ese mismo sitio,
    asi que arreglar el cacerts las arregla todas.

    Esto no pide admin: el cacerts esta dentro de la carpeta del JDK, que la
    puso el propio usuario.

    La CA se guarda ademas en %LOCALAPPDATA%\AssassinSkipAdm para poder
    reaplicarla sola cuando instales otro JDK.
.PARAMETER Cert
    Archivo .cer o .crt de la CA. Si se omite, se intenta deducir mirando quien
    firma varios dominios publicos sin relacion entre si.
.PARAMETER Remove
    Retira la CA de los JDK y olvida la copia guardada.
.PARAMETER Force
    No pregunta antes de escribir.
.PARAMETER WhatIf
    Ensena que haria y no toca nada.
.EXAMPLE
    .\Use-CorpCert.ps1 -WhatIf
.EXAMPLE
    .\Use-CorpCert.ps1 -Cert C:\temp\ca-empresa.cer
.EXAMPLE
    .\Use-CorpCert.ps1 -Remove
#>

param(
    [string]$Cert,

    [switch]$Remove,

    [switch]$Force,

    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

$Alias = 'assassinskipadm-corp'

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  La CA de tu empresa, dentro de los JDK" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

$lineas = @(Get-KitJdkLines)
if ($lineas.Count -eq 0) {
    Write-Log "El kit no tiene ningun JDK instalado." "ERROR"
    Write-Log "  Instala uno con:  .\Setup-JavaEnv.bat" "WARN"
    exit 1
}

# --------------------------------------------------------------------------
# Quitar
# --------------------------------------------------------------------------

if ($Remove) {
    $conCa = @($lineas | Where-Object {
        (Get-JdkTrustedAliases -JdkPath (Join-Path (Join-Path $WorkspaceRoot "Java") "jdk-$_")) -contains $Alias
    })

    if ($conCa.Count -eq 0 -and -not (Test-Path -LiteralPath $CorpCaFile)) {
        Write-Log "No hay ninguna CA del kit que quitar." "SUCCESS"
        Write-Host ""
        exit 0
    }

    Write-Host "Se retirara de:  $(if ($conCa.Count) { 'jdk-' + ($conCa -join ', jdk-') } else { '(ningun JDK)' })"
    if (Test-Path -LiteralPath $CorpCaFile) { Write-Host "Y se olvidara:   $CorpCaFile" }
    Write-Host ""

    if ($WhatIf) { Write-Host "-WhatIf: no se ha tocado nada." -ForegroundColor Cyan; Write-Host ""; exit 0 }
    if (-not $Force) {
        if ((Read-Host "Continuo? (escribe SI)") -ne 'SI') {
            Write-Host "Cancelado." -ForegroundColor Yellow
            exit 0
        }
    }

    foreach ($l in $conCa) {
        $jdk = Join-Path (Join-Path $WorkspaceRoot "Java") "jdk-$l"
        if (Remove-JdkCertificate -JdkPath $jdk -Alias $Alias) { Write-Log "Retirada de jdk-$l" "SUCCESS" }
        else { Write-Log "No se pudo retirar de jdk-$l" "ERROR" }
    }
    Remove-Item -LiteralPath $CorpCaFile -Force -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host "Hecho. Los JDK vuelven a confiar solo en las CA publicas." -ForegroundColor Green
    Write-Host ""
    exit 0
}

# --------------------------------------------------------------------------
# Que certificado
# --------------------------------------------------------------------------

$certPath = $null

if ($Cert) {
    if (-not (Test-Path -LiteralPath $Cert)) {
        Write-Log "No existe el archivo: $Cert" "ERROR"
        exit 1
    }
    try {
        $x = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($Cert)
    }
    catch {
        Write-Log "Ese archivo no es un certificado que se pueda leer." "ERROR"
        Write-Log "  Pide a IT el certificado RAIZ en formato .cer o .crt." "WARN"
        exit 1
    }
    $certPath = (Resolve-Path -LiteralPath $Cert).Path
    Write-Log "Certificado indicado a mano:" "SUCCESS"
}
else {
    Write-Log "Mirando quien firma varios dominios publicos..."
    $hallazgo = Find-CorpCa

    if (-not $hallazgo.Interceptado) {
        Write-Log "No se ha detectado interceptacion TLS: $($hallazgo.Motivo)" "SUCCESS"
        Write-Host ""
        Write-Host "Tu red no esta abriendo el HTTPS, o al menos no en los dominios que usa" -ForegroundColor Gray
        Write-Host "el kit. Los JDK no necesitan ninguna CA extra." -ForegroundColor Gray
        Write-Host ""
        Write-Host "Si aun asi te falla un 'mvn install' con PKIX path building failed," -ForegroundColor Gray
        Write-Host "pide a IT el certificado raiz e indicalo a mano:" -ForegroundColor Gray
        Write-Host "  .\Use-CorpCert.bat -Cert C:\ruta\ca-empresa.cer" -ForegroundColor White
        Write-Host ""
        exit 0
    }

    Write-Log "Interceptacion TLS detectada: $($hallazgo.Motivo)" "WARN"
    $x = $hallazgo.Cert

    # Se exporta a un archivo porque keytool importa de archivo, no de memoria.
    $tmp = Join-Path $env:TEMP "assassinskipadm-corp-ca.cer"
    [IO.File]::WriteAllBytes($tmp, $x.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
    $certPath = $tmp
}

Write-Host ""
Write-Host ("  Emisor    : {0}" -f $x.Subject) -ForegroundColor White
Write-Host ("  Huella    : {0}" -f $x.Thumbprint) -ForegroundColor Gray
Write-Host ("  Valido    : {0:yyyy-MM-dd}  ->  {1:yyyy-MM-dd}" -f $x.NotBefore, $x.NotAfter) -ForegroundColor Gray
if ($x.NotAfter -lt (Get-Date)) {
    Write-Log "Ese certificado esta CADUCADO; Java lo rechazara igual." "ERROR"
    exit 1
}
Write-Host ""

# --------------------------------------------------------------------------
# Aplicar
# --------------------------------------------------------------------------

$faltan = @()
foreach ($l in $lineas) {
    $jdk = Join-Path (Join-Path $WorkspaceRoot "Java") "jdk-$l"
    $tiene = (Get-JdkTrustedAliases -JdkPath $jdk) -contains $Alias
    Write-Host ("  jdk-{0,-4} {1}" -f $l, $(if ($tiene) { "ya la tiene (se reemplaza)" } else { "se le anade" }))
    $faltan += $l
}

Write-Host ""
Write-Host "Se escribe en el cacerts de cada JDK, dentro de la carpeta del kit." -ForegroundColor DarkGray
Write-Host "No hace falta admin, y se deshace con:  .\Use-CorpCert.bat -Remove" -ForegroundColor DarkGray
Write-Host ""

if ($WhatIf) { Write-Host "-WhatIf: no se ha tocado nada." -ForegroundColor Cyan; Write-Host ""; exit 0 }
if (-not $Force) {
    if ((Read-Host "Continuo? (escribe SI)") -ne 'SI') {
        Write-Host "Cancelado. No se ha tocado nada." -ForegroundColor Yellow
        exit 0
    }
    Write-Host ""
}

# Se guarda ANTES de importar: si algo falla a mitad, la copia ya esta y
# Sync-JdkCertificates puede terminar el trabajo en la siguiente ejecucion.
$destino = Split-Path -Parent $CorpCaFile
if (-not (Test-Path -LiteralPath $destino)) { New-Item -ItemType Directory -Path $destino -Force | Out-Null }
Copy-Item -LiteralPath $certPath -Destination $CorpCaFile -Force
Write-Log "Guardada en $CorpCaFile" "INFO"
Write-Log "  Desde aqui se reaplica sola cuando instales otro JDK." "INFO"

$fallos = 0
foreach ($l in $faltan) {
    $jdk = Join-Path (Join-Path $WorkspaceRoot "Java") "jdk-$l"
    $r = Import-JdkCertificate -JdkPath $jdk -CertPath $CorpCaFile -Alias $Alias
    if ($r.Ok) {
        Write-Log "jdk-$l al dia" "SUCCESS"
    }
    else {
        Write-Log "No se pudo con jdk-$l" "ERROR"
        $r.Salida | Select-Object -Last 2 | ForEach-Object { Write-Log "  $_" "WARN" }
        $fallos++
    }
}

Write-Host ""
if ($fallos -gt 0) { exit 1 }

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  LISTO" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Maven, Gradle y cualquier herramienta Java del kit ya confian en la" -ForegroundColor Green
Write-Host "CA de tu empresa: van todas por el cacerts que acabas de arreglar." -ForegroundColor Green
Write-Host ""
Write-Host "Comprueba con:  .\Doctor-Env.bat" -ForegroundColor Gray
Write-Host ""
