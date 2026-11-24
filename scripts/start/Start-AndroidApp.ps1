#Requires -Version 5.1
<#
.SYNOPSIS
    Start-AndroidApp.ps1 - Compila una app de Android y la abre en el telefono virtual.
.DESCRIPTION
    Todo de una vez, desde la carpeta del proyecto:

      1. Lee el proyecto: con que version del plugin de Android (AGP) se
         compila, y de ahi que JDK, plataforma y build-tools pide.
      2. Si en este equipo falta algo de eso, o el emulador y su telefono, lo
         instala (Setup-AndroidEnv). Solo la primera vez: las siguientes no
         descarga nada, ni lee nada de internet.
      3. Compila (gradlew assembleDebug), sin el ruido que sueltan los
         proyectos antiguos y sin daemon de Gradle, que es lo que hacia saltar
         el aviso del firewall.
      4. Arranca el telefono, o reutiliza el que ya este abierto, instala la
         app y la abre.

    Se acuerda del proyecto: la siguiente vez basta con ejecutarlo sin nada.
    El ciclo de trabajo es cambiar el codigo y volver a ejecutar esto.
.PARAMETER Path
    La carpeta del proyecto (la que tiene gradlew.bat). Por defecto, la de la
    ultima vez.
.PARAMETER Api
    La version de Android del telefono. Por defecto 26 (Android 8), o la
    minima de la app si pide una mas alta.
.PARAMETER SoloCompilar
    Compila y dice donde esta la app, sin el telefono.
.PARAMETER Depurar
    La abre parada, esperando al depurador de VS Code, y prepara VS Code: un
    espacio de trabajo con el que entiende el proyecto de Android (autocompleta
    y no marca en rojo lo que compila) y depura con F5. Lo abre solo. No escribe
    nada dentro del proyecto: va a la carpeta Android\vscode.
.PARAMETER Puerto
    El puerto por el que se conecta el depurador. Por defecto 5005.
.PARAMETER Certificado
    El certificado raiz de la empresa (.cer o .crt, el que da IT), para cuando
    la red abre el HTTPS y el kit no lo encuentra solo. Normalmente no hace
    falta: si Gradle falla por eso, el kit lo busca, lo pone y lo reintenta.
.EXAMPLE
    .\Start-AndroidApp.ps1 -Path C:\proyectos\mi-app
.EXAMPLE
    .\Start-AndroidApp.ps1
#>

param(
    [string]$Path,

    [string]$Api,

    [switch]$SoloCompilar,

    [switch]$Depurar,

    [int]$Puerto = 5005,

    [string]$Certificado
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Common.ps1")
# El SDK de Android y lo que lee el proyecto (ver sus cabeceras: no los carga Common).
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Android.ps1")
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Project.ps1")

Write-Log "========================================" "INFO"
Write-Log "  Compilar y probar una app de Android" "INFO"
Write-Log "========================================" "INFO"

if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Get-AndroidLastProject }
if ([string]::IsNullOrWhiteSpace($Path)) {
    Write-Log "Dime la carpeta del proyecto:  .\bin\start\Start-AndroidApp.bat -Path C:\ruta\del\proyecto" "ERROR"
    exit 1
}
$Path = $Path.Trim().Trim('"')
if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Write-Log "No existe la carpeta: $Path" "ERROR"; exit 1 }
$Path = (Resolve-Path -LiteralPath $Path).ProviderPath

if ($Depurar -and $SoloCompilar) { Write-Log "-Depurar necesita el telefono: no va con -SoloCompilar." "ERROR"; exit 1 }

$info = Get-AndroidProjectInfo -Ruta $Path
if (-not $info) {
    Write-Log "No parece un proyecto de Android: no encuentro un build.gradle con el plugin com.android.application." "ERROR"
    Write-Log "  Es la carpeta que tiene gradlew.bat y settings.gradle." "WARN"
    exit 1
}

# Android 8 (API 26) es el minimo con el que se trabaja; si la app pide uno
# mas alto, el telefono tiene que ser ese o no la podria instalar.
if (-not $Api) { $Api = if ($info.MinSdk -and [int]$info.MinSdk -gt 26) { $info.MinSdk } else { '26' } }

$plan = Get-AndroidAppPlan -Info $info -Api $Api -SoloCompilar:$SoloCompilar
Write-Host ""
Write-Host "  Proyecto : $Path" -ForegroundColor White
Write-Host ("  Pide     : {0}JDK {1}, android-{2}{3}" -f $(if ($info.Agp) { "AGP $($info.Agp), " } else { '' }), $plan.JdkMayor, $(if ($info.CompileSdk) { $info.CompileSdk } else { '(la mas reciente)' }), $(if ($plan.BuildTools) { ", build-tools $($plan.BuildTools)" } else { '' })) -ForegroundColor Gray
if (-not $SoloCompilar) { Write-Host "  Telefono : Android API $Api (kit-api$Api)" -ForegroundColor Gray }
Write-Host ""

# --------------------------------------------------------------------------
# 1. Lo que falte, solo la primera vez
# --------------------------------------------------------------------------

if ($plan.Faltan.Count -gt 0) {
    Write-Log "Primera vez con esto: falta $($plan.Faltan -join ', ')." "INFO"
    Write-Log "  Se instala ahora; las siguientes veces ya no." "INFO"
    $global:LASTEXITCODE = 0
    $a = $plan.SetupArgs
    & (Resolve-KitScript -Nombre 'Setup-AndroidEnv.ps1') @a
    if ($LASTEXITCODE -ne 0) { Write-Log "No se pudo instalar lo que falta (arriba esta por que)." "ERROR"; exit 1 }
    $plan = Get-AndroidAppPlan -Info $info -Api $Api -SoloCompilar:$SoloCompilar
}
if (-not $plan.Jdk) { Write-Log "Sigue faltando el JDK $($plan.JdkMayor); sin el no se compila." "ERROR"; exit 1 }

# --------------------------------------------------------------------------
# 2. Compilar
# --------------------------------------------------------------------------

Write-Host ""
Write-Log "Compilando (gradlew assembleDebug, con el JDK $($plan.JdkMayor))..."
if (-not (Test-Path -LiteralPath (Join-Path $Path 'build')) -and -not (Test-Path -LiteralPath (Join-Path $Path 'app\build'))) {
    Write-Log "  La primera vez Gradle baja su version y las librerias del proyecto: unos minutos, a ratos sin escribir nada." "INFO"
}
if ($Certificado) {
    $ca = Sync-AndroidCorpCa -Jdk $plan.Jdk -Certificado $Certificado
    if ($ca.Estado -ne 'puesta') { Write-Log "No se pudo poner el certificado: $($ca.Detalle)" "ERROR"; exit 1 }
    Write-Log "Certificado de la empresa puesto en el JDK: $($ca.Detalle)" "SUCCESS"
}
# Los package.xml de un kit de antes llevaban un campo que un AGP antiguo no
# conoce, y por el que suelta trazas largas: tambien al abrir el proyecto en VS Code.
Repair-AndroidPackageXml -Sdk $AndroidSdk | Out-Null
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Invoke-AndroidBuild -Proyecto $Path -Jdk $plan.Jdk
if (-not $r) { Write-Log "El proyecto no trae gradlew.bat, y es lo que fija su version de Gradle." "ERROR"; exit 1 }

# La red de la empresa abre el HTTPS con su propio certificado: Windows lo
# conoce y el Java del proyecto no. Paso en el primer equipo del trabajo: el
# wrapper de Gradle no podia ni bajar Gradle. Se pone y se vuelve a intentar.
if (-not $r.Ok -and $r.Certificado) {
    Write-Host ""
    Write-Log "Buscando el certificado de la empresa para el Java del proyecto..."
    $ca = Sync-AndroidCorpCa -Jdk $plan.Jdk
    if ($ca.Estado -eq 'puesta') {
        Write-Log "Puesto: $($ca.Detalle)" "SUCCESS"
        Write-Log "Compilando otra vez..."
        $r = Invoke-AndroidBuild -Proyecto $Path -Jdk $plan.Jdk
        if (-not $r.Ok -and $r.Certificado) {
            Write-Log "Sigue sin fiarse del HTTPS: el certificado que se encontro no es el que hace falta." "ERROR"
            Write-Log "  Pide a IT el certificado RAIZ de la empresa (.cer) y:  Start-AndroidApp.bat -Certificado C:\ruta\empresa.cer" "WARN"
            exit 1
        }
    }
    else {
        Write-Log "No se pudo encontrar solo ($($ca.Detalle))." "ERROR"
        Write-Log "  Pide a IT el certificado raiz de la empresa (.cer) y:  Start-AndroidApp.bat -Certificado C:\ruta\empresa.cer" "WARN"
        exit 1
    }
}
if (-not $r.Ok) {
    Write-Log "No compilo (codigo $($r.Codigo)). Arriba, tras 'What went wrong', esta el motivo." "ERROR"
    exit 1
}
Set-AndroidLastProject -Ruta $Path

$modulo = Split-Path -Parent $info.Fuente
$apk = Get-AndroidBuiltApk -Proyecto $Path -Modulo $modulo
if (-not $apk) { Write-Log "Compilo, pero no encuentro la app (.apk) en $modulo\build\outputs\apk." "ERROR"; exit 1 }
Write-Log ("Compilada en {0:N0} s: {1}" -f $sw.Elapsed.TotalSeconds, $apk.FullName) "SUCCESS"

if ($SoloCompilar) { exit 0 }

# --------------------------------------------------------------------------
# 3. Al telefono
# --------------------------------------------------------------------------

if ($plan.Faltan.Count -gt 0) {
    Write-Log "El telefono no esta listo ($($plan.Faltan -join ', ')): la app esta compilada, pero no se puede abrir." "WARN"
    exit 1
}
Write-Host ""

$vs = $null
if ($Depurar) {
    # Que VS Code entienda el proyecto y pueda depurarlo, sin escribir nada
    # dentro de el: todo va a Android\vscode (ver Write-AndroidVsCodeWorkspace).
    Write-Log "Preparando VS Code: las clases de Android y de las librerias del proyecto..."
    $cp = Get-AndroidClasspath -Proyecto $Path -Jdk $plan.Jdk -Modulo $modulo
    if (-not $cp.Ok) {
        # Depurar si se podra; entender el proyecto, solo a medias: su codigo y android.jar.
        Write-Log "  No se pudo sacar la lista ($($cp.Detalle)). VS Code podra depurar, pero no conocera las librerias." "WARN"
        $codigo = Join-Path $Path $(if ($modulo) { "$modulo\src\main\java" } else { 'src\main\java' })
        $androidJar = Join-Path $AndroidSdk "platforms\android-$($info.CompileSdk)\android.jar"
        $cp = [PSCustomObject]@{ Fuentes = @($codigo | Where-Object { Test-Path -LiteralPath $_ }); Jars = @($androidJar | Where-Object { Test-Path -LiteralPath $_ }); Java = $null }
    }
    $vs = Write-AndroidVsCodeWorkspace -Proyecto $Path -Modulo $modulo -Jdk $plan.Jdk -Puerto $Puerto -Fuentes $cp.Fuentes -Jars $cp.Jars -Java $cp.Java
    Write-Log ("VS Code: {0} carpetas de codigo y {1} librerias, en {2}" -f $vs.Fuentes, $vs.Jars, $vs.Archivo) "SUCCESS"
    # Se abre ya, para que vaya cargando mientras arranca el telefono.
    if (Open-AndroidVsCodeWorkspace -Archivo $vs.Archivo) { Write-Log "Abriendo VS Code con el proyecto..." "SUCCESS" }
    else { Write-Log "  No encuentro VS Code: abrelo y File > Open Workspace from File > $($vs.Archivo)" "WARN" }
}

$global:LASTEXITCODE = 0
& (Resolve-KitScript -Nombre 'Start-AndroidEmulator.ps1') -Avd "kit-api$Api" -Apk $apk.FullName -Depurar:$Depurar -Puerto $Puerto
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ""
if ($Depurar) {
    Write-Host "Lista para depurar. La app esta parada en el telefono hasta que VS Code se conecte:" -ForegroundColor Cyan
    Write-Host "  1. En VS Code, el espacio de trabajo del proyecto (se abre solo; si no, File > Open Workspace from File):" -ForegroundColor White
    Write-Host "       $($vs.Archivo)" -ForegroundColor White
    Write-Host "  2. Espera a que abajo diga ""Java: Ready"" y abre tus archivos desde la carpeta $(Split-Path -Leaf $Path)." -ForegroundColor White
    Write-Host "  3. Pon un punto de interrupcion: clic a la izquierda del numero de linea." -ForegroundColor White
    Write-Host "  4. F5, con ""$AndroidDepurarNombre""." -ForegroundColor White
    Write-Host "Para depurar otra version, vuelve a esta opcion: compila, instala y la deja esperando otra vez." -ForegroundColor Gray
    Write-Host "Si anades una libreria al proyecto, tambien: es cuando VS Code se entera." -ForegroundColor Gray
    exit 0
}
Write-Host "Para probar otra version: cambia el codigo y vuelve a ejecutar esto (Menu.bat, opcion 60)." -ForegroundColor Cyan
Write-Host "El telefono se queda abierto, asi que la proxima vez solo compila e instala." -ForegroundColor Gray
exit 0
