#Requires -Version 5.1
<#
    Pruebas de lib\Android.ps1: leer el indice del SDK de Google, elegir que
    instalar, y dejarlo como lo dejaria sdkmanager.

    Sin red: un indice fabricado con la forma del de verdad (sus espacios de
    nombres, sus canales de desarrollo y beta, las -rc y las -ext), que es justo
    lo que hay que saber descartar. Lo de verdad se comprobo aparte contra el
    sdkmanager oficial y arrancando el emulador.
#>

$KitRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $KitRoot "lib\Common.ps1")
. (Join-Path $KitRoot "lib\Android.ps1")

$RaizTmp = Join-Path ([IO.Path]::GetTempPath()) ("android-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $RaizTmp -Force | Out-Null

function Archivo {
    param([string]$Url, [string]$Os, [string]$Sha = 'aaaa', [long]$Bytes = 1048576, [string]$ArchHost)
    $os_ = if ($Os) { "<host-os>$Os</host-os>" } else { '' }
    $ah = if ($ArchHost) { "<host-arch>$ArchHost</host-arch>" } else { '' }
    "<archive><complete><size>$Bytes</size><checksum type=`"sha1`">$Sha</checksum><url>$Url</url></complete>$os_$ah</archive>"
}
function Paquete {
    param([string]$Path, [string]$Rev, [string]$Canal = 'channel-0', [string]$Archivos, [string]$Tipo = 'generic:genericDetailsType', [string]$Lic = 'android-sdk-license')
    $p = $Rev.Split('.'); $r = "<major>$($p[0])</major>"
    if ($p.Count -gt 1) { $r += "<minor>$($p[1])</minor>" }; if ($p.Count -gt 2) { $r += "<micro>$($p[2])</micro>" }
    "<remotePackage path=`"$Path`"><type-details xsi:type=`"$Tipo`"/><revision>$r</revision><display-name>$Path</display-name><uses-license ref=`"$Lic`"/><channelRef ref=`"$Canal`"/><archives>$Archivos</archives></remotePackage>"
}

$IndiceXml = [xml]@"
<sdk:sdk-repository xmlns:sdk="http://schemas.android.com/sdk/android/repo/repository2/03" xmlns:common="http://schemas.android.com/repository/android/common/02" xmlns:generic="http://schemas.android.com/repository/android/generic/02" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<license id="android-sdk-license" type="text">Texto de la licencia</license>
<channel id="channel-0">stable</channel><channel id="channel-2">dev</channel>
$(Paquete 'platform-tools' '37.0.3' 'channel-2' ((Archivo 'pt-373-linux.zip' 'linux') + (Archivo 'pt-373-win.zip' 'windows')))
$(Paquete 'platform-tools' '37.0.1' 'channel-0' ((Archivo 'pt-371-linux.zip' 'linux') + (Archivo 'pt-371-win.zip' 'windows' 'b3fd')))
$(Paquete 'build-tools;37.0.0-rc2' '37.0.0' 'channel-0' (Archivo 'bt-rc.zip' 'windows'))
$(Paquete 'build-tools;37.0.0' '37.0.0' 'channel-0' (Archivo 'bt-37.zip' 'windows'))
$(Paquete 'build-tools;36.1.0' '36.1.0' 'channel-0' (Archivo 'bt-361.zip' 'windows'))
$(Paquete 'platforms;android-36' '1' 'channel-0' (Archivo 'p36.zip') 'sdk:platformDetailsType')
$(Paquete 'platforms;android-36.1' '1' 'channel-0' (Archivo 'p361.zip') 'sdk:platformDetailsType')
$(Paquete 'platforms;android-35-ext14' '1' 'channel-0' (Archivo 'p35e.zip') 'sdk:platformDetailsType')
$(Paquete 'platforms;android-37.0' '1' 'channel-0' (Archivo 'p370.zip') 'sdk:platformDetailsType')
$(Paquete 'platforms;android-37.2-beta3' '1' 'channel-0' (Archivo 'p372b.zip') 'sdk:platformDetailsType')
$(Paquete 'emulator' '37.2.13' 'channel-0' ((Archivo 'emu-arm.zip' 'windows' -ArchHost 'aarch64') + (Archivo 'emu-x64.zip' 'windows' -ArchHost 'x64')))
</sdk:sdk-repository>
"@

$ImagenesXml = [xml]@"
<sys-img:sdk-sys-img xmlns:sys-img="http://schemas.android.com/sdk/android/repo/sys-img2/05" xmlns:common="http://schemas.android.com/repository/android/common/02" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<license id="android-sdk-license" type="text">Texto de la licencia</license>
$(Paquete 'system-images;android-34;default;x86_64' '4' 'channel-0' (Archivo 'x86_64-34_r04.zip') 'sys-img:sysImgDetailsType')
$(Paquete 'system-images;android-34;default;x86' '4' 'channel-0' (Archivo 'x86-34_r04.zip') 'sys-img:sysImgDetailsType')
$(Paquete 'system-images;android-25;default;x86' '1' 'channel-0' (Archivo 'x86-25_r01.zip') 'sys-img:sysImgDetailsType')
$(Paquete 'system-images;android-37.0;default;x86_64' '6' 'channel-0' (Archivo 'x86_64-37.0_r06.zip') 'sys-img:sysImgDetailsType')
</sys-img:sdk-sys-img>
"@

$Paquetes = @(ConvertFrom-AndroidIndex -Xml $IndiceXml)
$Imagenes = @(ConvertFrom-AndroidIndex -Xml $ImagenesXml -Lista 'sys-img/android/sys-img2-3.xml')

Describe "ConvertFrom-AndroidIndex" {

    It "lee los paquetes con su archivo de Windows y su SHA-1" {
        $pt = @($Paquetes | Where-Object { $_.Path -eq 'platform-tools' -and $_.Version -eq '37.0.1' })[0]
        $pt.Url | Should Be 'https://dl.google.com/android/repository/pt-371-win.zip'
        $pt.Sha1 | Should Be 'b3fd'
        $pt.Estable | Should Be $true
    }

    It "lo que no es del canal estable queda marcado" {
        (@($Paquetes | Where-Object { $_.Version -eq '37.0.3' })[0]).Estable | Should Be $false
    }

    # El emulador publica un archivo por arquitectura del EQUIPO.
    It "del emulador coge el de x64" {
        (@($Paquetes | Where-Object { $_.Path -eq 'emulator' })[0]).Url | Should Match 'emu-x64\.zip$'
    }

    # Los archivos de un indice de imagenes van relativos a su carpeta.
    It "las imagenes se bajan de la carpeta de su indice" {
        (@($Imagenes | Where-Object { $_.Path -eq 'system-images;android-34;default;x86_64' })[0]).Url |
            Should Be 'https://dl.google.com/android/repository/sys-img/android/x86_64-34_r04.zip'
    }

    It "lee las licencias" {
        (Get-AndroidIndexLicenses -Xml $IndiceXml)['android-sdk-license'] | Should Be 'Texto de la licencia'
    }
}

Describe "Elegir que instalar" {

    It "de un paquete, la estable mas alta, no la de desarrollo" {
        (Select-AndroidPackage -Paquetes $Paquetes -Path 'platform-tools').Version | Should Be '37.0.1'
    }

    It "build-tools: la estable mas reciente, nunca una -rc" {
        (Select-AndroidBuildTools -Paquetes $Paquetes).Path | Should Be 'build-tools;37.0.0'
    }

    # AGP usa las suyas, no las mas recientes: si el kit no pone esas, AGP las
    # baja por su cuenta la primera vez (paso con AGP 9.5.1: 36.0.0 con la 37).
    It "build-tools pedidas: esas; si no estan en el indice, las mas recientes" {
        (Select-AndroidBuildTools -Paquetes $Paquetes -Version '36.1.0').Path | Should Be 'build-tools;36.1.0'
        (Select-AndroidBuildTools -Paquetes $Paquetes -Version '99.0.0').Path | Should Be 'build-tools;37.0.0'
        $AndroidBuildToolsAgp | Should Match '^\d+\.\d+\.\d+$'
    }

    # Las -ext, las beta y las menores (36.1) son para quien las pide por nombre.
    # Con Stop, como corre Setup-AndroidEnv: una -ext colada entre las
    # candidatas no sale elegida, pero al ordenarlas por numero da un error que
    # alli tumba la instalacion.
    It "plataforma por defecto: la estable mas alta, sin -ext, beta ni menores" {
        $ErrorActionPreference = 'Stop'
        (Select-AndroidPlatform -Paquetes $Paquetes).Path | Should Be 'platforms;android-37.0'
    }

    It "plataforma pedida: con su nombre de siempre o el de la 37 en adelante" {
        (Select-AndroidPlatform -Paquetes $Paquetes -Api 36).Path | Should Be 'platforms;android-36'
        (Select-AndroidPlatform -Paquetes $Paquetes -Api 37).Path | Should Be 'platforms;android-37.0'
        Select-AndroidPlatform -Paquetes $Paquetes -Api 99 | Should BeNullOrEmpty
    }

    It "imagen: x86_64 si la hay, x86 si no" {
        (Select-AndroidSystemImage -Paquetes $Imagenes -Api 34).Path | Should Be 'system-images;android-34;default;x86_64'
        (Select-AndroidSystemImage -Paquetes $Imagenes -Api 25).Path | Should Be 'system-images;android-25;default;x86'
        (Select-AndroidSystemImage -Paquetes $Imagenes -Api 37).Path | Should Be 'system-images;android-37.0;default;x86_64'
    }

    # Paso: se pedia sys-img/default/ y daba un 404.
    It "las imagenes default estan en sys-img/android/" {
        Get-AndroidSystemImageList -Tipo 'default' | Should Be 'sys-img/android/sys-img2-3.xml'
        Get-AndroidSystemImageList -Tipo 'google_apis' | Should Be 'sys-img/google_apis/sys-img2-3.xml'
    }

    It "cada paquete va a su carpeta del SDK" {
        Get-AndroidPackageFolder -Sdk 'C:\sdk' -Path 'system-images;android-34;default;x86_64' | Should Be 'C:\sdk\system-images\android-34\default\x86_64'
    }
}

Describe "El package.xml, como lo deja sdkmanager" {

    $p = @($Paquetes | Where-Object { $_.Path -eq 'platforms;android-36' })[0]
    $texto = ConvertTo-AndroidPackageXml -Paquete $p -LicenciaTexto 'Texto de la licencia'
    $doc = [xml]$texto

    It "es XML valido con el paquete como localPackage" {
        $lp = @($doc.DocumentElement.ChildNodes | Where-Object { $_.LocalName -eq 'localPackage' })[0]
        $lp.path | Should Be 'platforms;android-36'
        $lp.obsolete | Should Be 'false'
    }

    It "no lleva los archivos ni el canal del indice" {
        $texto | Should Not Match '<archives>|<channelRef'
    }

    # Los type-details dicen xsi:type="sdk:platformDetailsType": si el prefijo
    # no existe en este documento, quien lo lea no sabe que tipo es.
    It "el prefijo de su tipo existe, con el espacio de nombres del indice" {
        $doc.DocumentElement.GetNamespaceOfPrefix('sdk') | Should Be 'http://schemas.android.com/sdk/android/repo/repository2/03'
        $texto | Should Match 'xsi:type="sdk:platformDetailsType"'
    }

    It "lleva el texto de su licencia" {
        (@($doc.DocumentElement.ChildNodes | Where-Object { $_.LocalName -eq 'license' })[0]).InnerText | Should Be 'Texto de la licencia'
    }

    It "se lee de vuelta como instalado, con su version" {
        $sdk = Join-Path $RaizTmp 'sdk'
        $c = Get-AndroidPackageFolder -Sdk $sdk -Path $p.Path
        New-Item -ItemType Directory -Path $c -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $c 'package.xml'), $texto)
        $i = @(Get-InstalledAndroidPackages -Sdk $sdk | Where-Object { $_.Path -eq 'platforms;android-36' })[0]
        $i.Version | Should Be '1'
    }
}

Describe "Write-AndroidLicenses" {

    $sha = [Security.Cryptography.SHA256]::Create()
    $huella = (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('texto de prueba')) | ForEach-Object { $_.ToString('x2') }) -join '')
    $AndroidLicenseHashes['licencia-de-prueba'] = [PSCustomObject]@{ Aceptacion = 'abc123'; Texto = $huella }

    It "escribe la aceptacion como sdkmanager: un salto y el hash" {
        $sdk = Join-Path $RaizTmp ([Guid]::NewGuid().ToString('N').Substring(0, 6))
        $r = Write-AndroidLicenses -Sdk $sdk -Licencias @{ 'licencia-de-prueba' = 'texto de prueba' } -Ids @('licencia-de-prueba')
        $r.Escritas -join ',' | Should Be 'licencia-de-prueba'
        [IO.File]::ReadAllText((Join-Path $sdk 'licenses\licencia-de-prueba')) | Should Be "`r`nabc123"
    }

    It "dos veces no la duplica" {
        $sdk = Join-Path $RaizTmp ([Guid]::NewGuid().ToString('N').Substring(0, 6))
        1..2 | ForEach-Object { Write-AndroidLicenses -Sdk $sdk -Licencias @{ 'licencia-de-prueba' = 'texto de prueba' } -Ids @('licencia-de-prueba') | Out-Null }
        [IO.File]::ReadAllText((Join-Path $sdk 'licenses\licencia-de-prueba')) | Should Be "`r`nabc123"
    }

    # Si Google cambia el texto, el hash fijado ya no vale: mejor no escribir
    # nada que escribir una aceptacion de otra licencia.
    It "si el texto cambio, no escribe nada y lo dice" {
        $sdk = Join-Path $RaizTmp ([Guid]::NewGuid().ToString('N').Substring(0, 6))
        $r = Write-AndroidLicenses -Sdk $sdk -Licencias @{ 'licencia-de-prueba' = 'OTRO texto' } -Ids @('licencia-de-prueba')
        $r.Cambiadas -join ',' | Should Be 'licencia-de-prueba'
        Test-Path -LiteralPath (Join-Path $sdk 'licenses\licencia-de-prueba') | Should Be $false
    }

    It "una licencia que el kit no conoce tampoco se escribe" {
        $r = Write-AndroidLicenses -Sdk (Join-Path $RaizTmp 'x') -Licencias @{ 'otra' = 't' } -Ids @('otra')
        $r.Cambiadas -join ',' | Should Be 'otra'
    }

    It "las fijadas son las que escribe el sdkmanager oficial" {
        $AndroidLicenseHashes['android-sdk-license'].Aceptacion | Should Be '24333f8a63b6825ea9c5514f83c2829b004d1fee'
        foreach ($k in @('android-sdk-license', 'android-sdk-preview-license')) {
            $AndroidLicenseHashes[$k].Aceptacion | Should Match '^[0-9a-f]{40}$'
            $AndroidLicenseHashes[$k].Texto | Should Match '^[0-9a-f]{64}$'
        }
    }
}

Describe "El telefono virtual" {

    $avdHome = Join-Path $RaizTmp 'avd'
    New-AndroidAvd -Nombre 'kit-api34' -AvdHome $avdHome -ImagePath 'system-images;android-34;default;x86_64' | Out-Null
    $cfg = Get-Content -LiteralPath (Join-Path $avdHome 'kit-api34.avd\config.ini')

    It "apunta a su imagen, dentro del SDK" {
        $cfg -contains 'image.sysdir.1=system-images\android-34\default\x86_64\' | Should Be $true
        $cfg -contains 'abi.type=x86_64' | Should Be $true
    }

    # Lo que lo hace llevadero en un equipo justo.
    It "es ligero: poca RAM, pantalla pequena, sin audio y con arranque rapido" {
        $cfg -contains 'hw.ramSize=1536' | Should Be $true
        $cfg -contains 'hw.lcd.width=720' | Should Be $true
        $cfg -contains 'hw.audioOutput=no' | Should Be $true
        $cfg -contains 'fastboot.forceColdBoot=no' | Should Be $true
        $cfg -contains 'PlayStore.enabled=false' | Should Be $true
    }

    # Paso: sin barra de navegacion, Android 8.0 mostraba "System UI has
    # stopped" al abrir la app tras reanudar el telefono.
    It "tiene barra de navegacion en pantalla" {
        $cfg -contains 'hw.mainKeys=no' | Should Be $true
    }

    It "su .ini dice donde esta y de que version es" {
        $ini = Get-Content -LiteralPath (Join-Path $avdHome 'kit-api34.ini')
        $ini -contains "path=$(Join-Path $avdHome 'kit-api34.avd')" | Should Be $true
        $ini -contains 'target=android-34' | Should Be $true
        Get-AndroidAvds -AvdHome $avdHome | Should Be 'kit-api34'
    }
}

Describe "Lo demas" {

    It "del badging de un APK saca su paquete y la actividad con que arranca" {
        $t = "package: name='com.empresa.app' versionCode='1' versionName='1.0'`nsdkVersion:'26'`nlaunchable-activity: name='com.empresa.app.MainActivity'  label='App'"
        $i = ConvertFrom-AaptBadging -Texto $t
        $i.Paquete | Should Be 'com.empresa.app'
        $i.Actividad | Should Be 'com.empresa.app.MainActivity'
    }

    It "el JDK para Gradle: el mas alto de 17 o mas, o el que se pida" {
        $WorkspaceRoot = Join-Path $RaizTmp 'ws-jdk'
        foreach ($v in '8', '17', '21') { New-Item -ItemType Directory -Path (Join-Path $WorkspaceRoot "Java\jdk-$v\bin") -Force | Out-Null; [IO.File]::WriteAllText((Join-Path $WorkspaceRoot "Java\jdk-$v\bin\java.exe"), '') }
        Split-Path -Leaf (Get-KitJdkForAndroid) | Should Be 'jdk-21'
        Split-Path -Leaf (Get-KitJdkForAndroid -Mayor 8) | Should Be 'jdk-8'
        Get-KitJdkForAndroid -Mayor 11 | Should BeNullOrEmpty
    }

    It "el estado del hipervisor se lee sin admin y sin fallar" {
        $h = Get-HypervisorPlatformState
        ($h.Activada -is [bool]) | Should Be $true
        ($h.Hipervisor -is [bool]) | Should Be $true
    }

    It "el entorno pone el SDK, los telefonos fuera de la carpeta de trabajo y el JDK" {
        $e = Get-AndroidEnvironment -Sdk 'C:\kit\Android\sdk' -Jdk 'C:\kit\Java\jdk-21'
        $e.Variables['ANDROID_HOME'] | Should Be 'C:\kit\Android\sdk'
        $e.Variables['JAVA_HOME'] | Should Be 'C:\kit\Java\jdk-21'
        $e.Variables['ANDROID_AVD_HOME'] | Should Match ([regex]::Escape($env:LOCALAPPDATA))
        ($e.Rutas -join ';') | Should Match 'platform-tools;C:\\kit\\Android\\sdk\\emulator'
    }
}

Describe "Lo que pide cada version de AGP" {

    # Los valores salen de los JAR de AGP; aqui se comprueba que la tabla se
    # lee bien en sus bordes, que es donde se equivoca uno al escribirla.
    $casos = @(
        @{ Agp = '3.4.2';  BT = '28.0.3'; Jdk = 8 }
        @{ Agp = '4.1.3';  BT = '29.0.2'; Jdk = 8 }
        @{ Agp = '4.2.2';  BT = '30.0.2'; Jdk = 8 }
        @{ Agp = '7.0.4';  BT = '30.0.2'; Jdk = 11 }
        @{ Agp = '7.4.2';  BT = '30.0.3'; Jdk = 11 }
        @{ Agp = '8.0.2';  BT = '30.0.3'; Jdk = 17 }
        @{ Agp = '8.1.4';  BT = '33.0.1'; Jdk = 17 }
        @{ Agp = '8.7.3';  BT = '34.0.0'; Jdk = 17 }
        @{ Agp = '8.13.2'; BT = '35.0.0'; Jdk = 17 }
        @{ Agp = '9.5.1';  BT = '36.0.0'; Jdk = 17 }
    )
    foreach ($c in $casos) {
        It "AGP $($c.Agp): build-tools $($c.BT) y JDK $($c.Jdk)" {
            $r = Get-AgpRequirements -Agp $c.Agp
            "$($r.BuildTools) $($r.Jdk)" | Should Be "$($c.BT) $($c.Jdk)"
        }
    }

    It "antes de la 3.2 no se fija build-tools, y el JDK es el 8" {
        $r = Get-AgpRequirements -Agp '3.1.4'
        $r.BuildTools | Should BeNullOrEmpty
        $r.Jdk | Should Be 8
    }

    It "una version que no se entiende no pide nada" {
        Get-AgpRequirements -Agp 'libs.versions.agp' | Should BeNullOrEmpty
        Get-AgpRequirements -Agp '' | Should BeNullOrEmpty
    }

    It "las build-tools por defecto son las del AGP mas nuevo de la tabla" {
        $AndroidBuildToolsAgp | Should Be $AndroidAgpRequisitos[0].BuildTools
    }
}

Describe "android-shell.bat, ejecutado en cmd" {

    # Una ruta como las que rompen un .bat: espacios, &, parentesis y %.
    $base = Join-Path $RaizTmp 'Marks & Spencer (2) 100%'
    $java = Join-Path $base 'Java'
    foreach ($v in '8', '21') { New-Item -ItemType Directory -Path (Join-Path $java "jdk-$v\bin") -Force | Out-Null; [IO.File]::WriteAllText((Join-Path $java "jdk-$v\bin\java.exe"), '') }
    $shell = Write-AndroidShell -Sdk (Join-Path $base 'Android\sdk') -Jdk (Join-Path $java 'jdk-21') -OtrosJdk 8 -JavaRoot $java

    # Como en Shells.Tests: se copia a una ruta simple (lo que se prueba es lo
    # que hay DENTRO, no si cmd sabe invocar un archivo cuya ruta lleva & y %),
    # y se lee con expansion retardada, que no parte la linea por un &. El
    # "< nul" hace que el cmd /k del final se cierre en vez de esperar.
    $simple = Join-Path $RaizTmp 'run'
    New-Item -ItemType Directory -Path $simple -Force | Out-Null
    Copy-Item -LiteralPath $shell -Destination (Join-Path $simple 'android-shell.bat') -Force
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $shell) 'android-java8-shell.bat') -Destination $simple -Force
    Set-Content -LiteralPath (Join-Path $simple 'runner.cmd') -Encoding ASCII -Value @(
        '@echo off', 'call "%~1" %2 < nul', 'setlocal enabledelayedexpansion', 'echo JH=[!JAVA_HOME!]', 'echo PATH=[!PATH!]')

    function Invoke-Shell {
        param([string]$Argumento, [string]$Bat = 'android-shell.bat')
        $a = @('/c', (Join-Path $simple 'runner.cmd'), (Join-Path $simple $Bat))
        if ($Argumento) { $a += $Argumento }
        # El cmd /k pinta su prompt antes de cerrarse, y la primera linea del
        # runner sale pegada detras: se corta lo de delante.
        return @(((Invoke-NativeCommand -FilePath 'cmd.exe' -Arguments $a -Quiet).Output -split "`r?`n") -replace '^.*?(?=JH=\[|PATH=\[)', '')
    }

    # Paso: no lo hacia, y con doble clic se abria y se cerraba al instante.
    It "termina en cmd /k, como las demas consolas: con doble clic se queda abierta" {
        @(Get-Content -LiteralPath $shell)[-1] | Should Be 'cmd /k'
    }

    # Un doble clic no pasa argumentos: para el JDK 8, su propia consola.
    It "android-java8-shell.bat es la misma con el JDK 8" {
        $o = Invoke-Shell -Bat 'android-java8-shell.bat'
        ($o | Where-Object { $_ -like 'JH=*' }) | Should Be "JH=[$java\jdk-8]"
        Get-AndroidShellJdks -Carpeta (Split-Path -Parent $shell) | Should Be 8
    }

    It "sin argumento, el JDK de siempre, y su bin en el PATH" {
        $o = Invoke-Shell
        ($o | Where-Object { $_ -like 'JH=*' }) | Should Be "JH=[$java\jdk-21]"
        ($o | Where-Object { $_ -like 'PATH=*' }) | Should Match ([regex]::Escape("$java\jdk-21\bin;"))
        ($o -join "`n") | Should Match 'JDK: jdk-21'
    }

    # Un proyecto con AGP de antes de la 7 corre Gradle con el 8.
    It "con 8, el jdk-8 del kit, tambien en el PATH" {
        $o = Invoke-Shell -Argumento '8'
        ($o | Where-Object { $_ -like 'JH=*' }) | Should Be "JH=[$java\jdk-8]"
        ($o | Where-Object { $_ -like 'PATH=*' }) | Should Match ([regex]::Escape("$java\jdk-8\bin;"))
    }

    It "con uno que no hay, lo dice y deja el de siempre" {
        $o = Invoke-Shell -Argumento '11'
        ($o | Where-Object { $_ -like 'JH=*' }) | Should Be "JH=[$java\jdk-21]"
        ($o -join "`n") | Should Match 'No hay JDK 11 del kit'
    }
}

Describe "Sin avisos del firewall" {

    # Lo que los hacia saltar, medido: el daemon de Gradle escuchando en todas
    # las direcciones, y adb buscando telefonos por mDNS. Sin daemon y con
    # ADB_MDNS=0, un java.exe y un adb.exe que el firewall no conocia no
    # abrieron nada hacia fuera (solo adb en 127.0.0.1).
    It "adb no busca telefonos por la red" {
        (Get-AndroidEnvironment -Sdk 'C:\sdk').Variables['ADB_MDNS'] | Should Be '0'
    }

    It "Gradle va sin daemon, y con el mismo -Xmx en las dos partes (si no, abre otra JVM)" {
        $AndroidGradleOpts | Should Match '-Dorg\.gradle\.daemon=false'
        $cliente = [regex]::Match($AndroidGradleOpts, '(?:^|\s)-Xmx(\d+\w)').Groups[1].Value
        $build = [regex]::Match($AndroidGradleOpts, 'org\.gradle\.jvmargs=-Xmx(\d+\w)').Groups[1].Value
        $cliente | Should Not BeNullOrEmpty
        $cliente | Should Be $build
    }

    It "la consola lo lleva tal cual, sin anadirle otro GRADLE_OPTS que lo descuadre" {
        $s = Write-AndroidShell -Sdk (Join-Path $RaizTmp 'fw\Android\sdk') -Jdk 'C:\jdk' -JavaRoot (Join-Path $RaizTmp 'fw\Java')
        (Get-Content -LiteralPath $s) -contains "set `"GRADLE_OPTS=$AndroidGradleOpts`"" | Should Be $true
    }
}

Describe "La salida de Gradle, sin el ruido de los proyectos antiguos" {

    # Tal cual lo escribe AGP 3.4 con el SDK de ahora (recortado).
    $ruidoso = @(
        '> Configure project :app'
        'Mapping new ns http://schemas.android.com/sdk/android/repo/repository2/03 to old ns http://schemas.android.com/sdk/android/repo/repository2/01'
        "cvc-complex-type.2.4.a: Se ha encontrado contenido no valido a partir del elemento 'base-extension'. Se esperaba uno de '{layoutlib}'.:"
        "org.xml.sax.SAXParseException; lineNumber: 153; columnNumber: 23; cvc-complex-type.2.4.a: Se ha encontrado contenido no valido a partir del elemento 'base-extension'."
        '        at com.sun.org.apache.xerces.internal.util.ErrorHandlerWrapper.createSAXParseException(ErrorHandlerWrapper.java:204)'
        '        at java.lang.Thread.run(Thread.java:750)'
        ''
        'elemento inesperado (URI:"", local:"base-extension"). Los elementos esperados son <{}codename>,<{}layoutlib>,<{}api-level>'
        ''
        '> Task :app:compileDebugJavaWithJavac'
        'BUILD SUCCESSFUL in 4m 18s'
    )

    function Filtrar([string[]]$Lineas) {
        $e = @{ EnTraza = $false; Avisado = $false }
        return @($Lineas | ForEach-Object { Select-GradleLine -Linea $_ -Estado $e } | Where-Object { $null -ne $_ })
    }

    It "se queda lo que importa, con un aviso de una linea en lugar de la traza" {
        $v = Filtrar $ruidoso
        $v -contains '> Configure project :app' | Should Be $true
        $v -contains '> Task :app:compileDebugJavaWithJavac' | Should Be $true
        $v -contains 'BUILD SUCCESSFUL in 4m 18s' | Should Be $true
        @($v | Where-Object { $_ -match 'base-extension|Mapping new ns|^\s+at ' }).Count | Should Be 0
        @($v | Where-Object { $_ -match 'No afecta' }).Count | Should Be 1
    }

    # Lo que no se puede perder: si el build falla de verdad, su traza.
    It "la traza de un error de verdad se ensena entera" {
        $v = Filtrar @('* What went wrong:', 'java.lang.RuntimeException: algo de verdad', '        at com.ejemplo.Clase.metodo(Clase.java:10)', 'BUILD FAILED in 3s')
        $v -contains '        at com.ejemplo.Clase.metodo(Clase.java:10)' | Should Be $true
        @($v | Where-Object { $_ -match 'No afecta' }).Count | Should Be 0
        $v.Count | Should Be 4
    }
}

Describe "Start-AndroidApp: que falta y donde quedo la app" {

    $AndroidRoot = Join-Path $RaizTmp 'app-plan'
    $sdk = Join-Path $AndroidRoot 'sdk'
    $AndroidAvdHome = Join-Path $RaizTmp 'app-plan-avd'
    $WorkspaceRoot = Join-Path $RaizTmp 'app-plan-ws'
    New-Item -ItemType Directory -Path (Join-Path $WorkspaceRoot 'Java\jdk-8\bin') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $WorkspaceRoot 'Java\jdk-8\bin\java.exe'), '')
    function Instalado2 { param([string]$Path)
        $c = Get-AndroidPackageFolder -Sdk $sdk -Path $Path
        New-Item -ItemType Directory -Path $c -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $c 'package.xml'), "<ns2:repository xmlns:ns2=`"x`"><localPackage path=`"$Path`"><revision><major>1</major></revision></localPackage></ns2:repository>")
    }
    $viejo = [PSCustomObject]@{ Agp = '3.4.2'; CompileSdk = '28'; MinSdk = '21'; BuildTools = $null; Fuente = 'app\build.gradle' }

    It "un proyecto de AGP 3.4 en un equipo vacio: falta todo, y se pide con el JDK 8" {
        $p = Get-AndroidAppPlan -Info $viejo -Api '26' -Sdk $sdk
        $p.JdkMayor | Should Be 8
        $p.BuildTools | Should Be '28.0.3'
        ($p.Faltan -join '|') | Should Match 'platform-tools.*android-28.*28\.0\.3.*emulador.*API 26.*kit-api26'
        $p.SetupArgs['Jdk'] | Should Be 8
        $p.SetupArgs['Plataforma'] | Should Be '28'
        $p.SetupArgs['Api'] | Should Be '26'
        $p.SetupArgs['Emulador'] | Should Be $true
    }

    # La segunda vez no hay que instalar nada, ni leer el indice de Google.
    It "con todo puesto no falta nada" {
        foreach ($x in 'platform-tools', 'platforms;android-28', 'build-tools;28.0.3', 'emulator', 'system-images;android-26;default;x86_64') { Instalado2 $x }
        New-AndroidAvd -Nombre 'kit-api26' -AvdHome $AndroidAvdHome -ImagePath 'system-images;android-26;default;x86_64' | Out-Null
        $p = Get-AndroidAppPlan -Info $viejo -Api '26' -Sdk $sdk
        $p.Faltan.Count | Should Be 0
        Split-Path -Leaf $p.Jdk | Should Be 'jdk-8'
    }

    It "para solo compilar, el telefono no hace falta" {
        $p = Get-AndroidAppPlan -Info $viejo -Api '30' -SoloCompilar -Sdk $sdk
        $p.Faltan.Count | Should Be 0
        $p.SetupArgs.ContainsKey('Emulador') | Should Be $false
    }

    It "la app es la APK mas reciente del modulo, nunca la de las pruebas" {
        $mod = Join-Path $RaizTmp 'proy\app\build\outputs\apk'
        foreach ($f in 'debug\vieja.apk', 'debug\app-debug.apk', 'androidTest\debug\pruebas.apk') { New-Item -ItemType Directory -Path (Split-Path (Join-Path $mod $f)) -Force | Out-Null; [IO.File]::WriteAllText((Join-Path $mod $f), 'x') }
        (Get-Item (Join-Path $mod 'debug\vieja.apk')).LastWriteTime = (Get-Date).AddYears(-5)
        (Get-Item (Join-Path $mod 'androidTest\debug\pruebas.apk')).LastWriteTime = (Get-Date).AddMinutes(5)
        (Get-AndroidBuiltApk -Proyecto (Join-Path $RaizTmp 'proy') -Modulo 'app').Name | Should Be 'app-debug.apk'
    }

    It "se acuerda del proyecto, y olvida uno que ya no existe" {
        $f = Join-Path $RaizTmp 'ultimo.txt'
        Set-AndroidLastProject -Ruta $RaizTmp -Archivo $f
        Get-AndroidLastProject -Archivo $f | Should Be $RaizTmp
        Set-AndroidLastProject -Ruta (Join-Path $RaizTmp 'no-existe') -Archivo $f
        Get-AndroidLastProject -Archivo $f | Should BeNullOrEmpty
    }
}

Describe "Un cambio de proxy rehace la consola de Android" {

    # Como Use-CorpCert o Doctor -Fix tras cambiar la clave del proxy: si la
    # consola de Android se quedara con la vieja, Gradle daria un 407 solo ahi.
    $WorkspaceRoot = Join-Path $RaizTmp 'ws-proxy'
    $sdk = Join-Path $WorkspaceRoot 'Android\sdk'
    $jdk = Join-Path $WorkspaceRoot 'Java\jdk-21'
    Write-AndroidShell -Sdk $sdk -Jdk $jdk -OtrosJdk 8 -JavaRoot (Join-Path $WorkspaceRoot 'Java') | Out-Null
    Mock Get-GradleProxyLine { 'set "GRADLE_OPTS=-Dhttps.proxyHost=proxy.prueba -Dhttps.proxyPort=8080 %GRADLE_OPTS%"' }

    It "la vuelve a escribir con el proxy y su JDK, sin perder las consolas por JDK" {
        $r = @(Update-GeneratedShells)
        $r -contains 'Shell rehecho: Android' | Should Be $true
        $t = Get-Content -LiteralPath (Join-Path $WorkspaceRoot 'Android\android-shell.bat') -Raw
        $t | Should Match 'proxyHost=proxy\.prueba'
        $t | Should Match ([regex]::Escape("set `"JAVA_HOME=$jdk`""))
        Test-Path -LiteralPath (Join-Path $WorkspaceRoot 'Android\android-java8-shell.bat') | Should Be $true
    }
}

Describe "Doctor: la seccion de Android" {

    # Al ambito del script, como en Doctor.Tests: asi $script:JsonSections de
    # las funciones y el de las pruebas son el mismo.
    . (Join-Path $KitRoot "lib\Doctor.ps1")

    function Reset-Doctor { $script:JsonSections = @(); $script:ReportLines = @(); $script:Problems = 0; $script:Warnings = 0; $script:Fixes = @() }
    function Check { param([string]$Etiqueta) @(@($script:JsonSections | Where-Object { $_.titulo -eq 'Android' })[0].comprobaciones | Where-Object { $_.etiqueta.Trim() -eq $Etiqueta })[0] }
    function Instalado { param([string]$Sdk, [string]$Path)
        $c = Get-AndroidPackageFolder -Sdk $Sdk -Path $Path
        New-Item -ItemType Directory -Path $c -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $c 'package.xml'), "<ns2:repository xmlns:ns2=`"x`"><localPackage path=`"$Path`" obsolete=`"false`"><revision><major>1</major></revision></localPackage></ns2:repository>")
    }

    Mock Write-Host { }
    Mock Get-HypervisorPlatformState { [PSCustomObject]@{ Activada = $true; Hipervisor = $true } }
    Mock Test-AndroidEmulatorAccel { [PSCustomObject]@{ Ok = $true; Texto = 'WHPX is installed and usable.' } }
    Mock Get-KitJdkForAndroid { 'C:\kit\Java\jdk-21' }

    $AndroidRoot = Join-Path $RaizTmp 'doctor'
    $AndroidSdk = Join-Path $AndroidRoot 'sdk'
    $AndroidAvdHome = Join-Path $RaizTmp 'doctor-avd'

    It "sin SDK: lo dice, y si este equipo podria con el emulador" {
        Reset-Doctor
        $AndroidSdk = Join-Path $RaizTmp 'no-existe'
        Test-AndroidInstall
        (Check 'Instalado').estado | Should Be 'info'
        (Check 'Emulador posible').valor | Should Match '^si'
        $script:Problems + $script:Warnings | Should Be 0
    }

    foreach ($p in @('platform-tools', 'build-tools;36.0.0', 'platforms;android-34', 'emulator', 'system-images;android-34;default;x86_64')) { Instalado $AndroidSdk $p }
    New-Item -ItemType Directory -Path (Join-Path $AndroidSdk 'licenses') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $AndroidSdk 'licenses\android-sdk-license'), "`r`nabc")
    [IO.File]::WriteAllText((Join-Path $AndroidRoot 'android-shell.bat'), '@echo off')
    New-AndroidAvd -Nombre 'kit-api34' -AvdHome $AndroidAvdHome -ImagePath 'system-images;android-34;default;x86_64' | Out-Null
    New-AndroidAvd -Nombre 'kit-api26' -AvdHome $AndroidAvdHome -ImagePath 'system-images;android-26;default;x86_64' | Out-Null
    # Como lo deja el emulador tras arrancar: "clave = valor".
    $cfg = Join-Path $AndroidAvdHome 'kit-api34.avd\config.ini'
    Set-Content -LiteralPath $cfg -Value (@(Get-Content -LiteralPath $cfg) -replace '^([^=]+)=', '$1 = ') -Encoding ASCII

    It "con todo puesto, cada cosa en verde" {
        Reset-Doctor
        Mock Get-AndroidUserHome { $AndroidSdk }
        Test-AndroidInstall
        foreach ($e in @('platform-tools (adb)', 'build-tools', 'Plataformas', 'Licencia del SDK', 'JDK para Gradle', 'ANDROID_HOME', 'android-shell.bat', 'Emulador', 'aceleracion')) {
            "$e=$((Check $e).estado)" | Should Be "$e=ok"
        }
    }

    # Paso: el emulador reescribe el config.ini con espacios y el Doctor
    # dejo de encontrar la imagen de telefonos que estaban bien.
    It "un telefono que ya arranco una vez se sigue leyendo bien" {
        Reset-Doctor
        Mock Get-AndroidUserHome { $AndroidSdk }
        Test-AndroidInstall
        (Check 'kit-api34').estado | Should Be 'ok'
        (Check 'kit-api34').valor | Should Be 'android-34\default\x86_64'
    }

    It "un telefono sin su imagen es un fallo, con como arreglarlo" {
        Reset-Doctor
        Mock Get-AndroidUserHome { $AndroidSdk }
        Test-AndroidInstall
        (Check 'kit-api26').estado | Should Be 'fail'
        ((Check 'kit-api26').detalles -join ' ') | Should Match '-Api 26'
        $script:Problems | Should Be 1
    }

    It "sin ANDROID_HOME: aviso y reparacion local" {
        Reset-Doctor
        Mock Get-AndroidUserHome { $null }
        Test-AndroidInstall
        (Check 'ANDROID_HOME').estado | Should Be 'warn'
        @($script:Fixes | Where-Object { $_.Description -match 'ANDROID_HOME' }).Count | Should Be 1
    }

    # El de un Android Studio, por ejemplo: es una eleccion, no un error.
    It "ANDROID_HOME de otro SDK que existe: se dice, no se toca" {
        Reset-Doctor
        Mock Get-AndroidUserHome { $RaizTmp }
        Test-AndroidInstall
        (Check 'ANDROID_HOME').estado | Should Be 'info'
        @($script:Fixes | Where-Object { $_.Description -match 'ANDROID_HOME' }).Count | Should Be 0
    }

    It "sin la licencia aceptada es un fallo: Gradle no compilaria" {
        Reset-Doctor
        Mock Get-AndroidUserHome { $AndroidSdk }
        Remove-Item -LiteralPath (Join-Path $AndroidSdk 'licenses\android-sdk-license')
        Test-AndroidInstall
        (Check 'Licencia del SDK').estado | Should Be 'fail'
    }
}

Remove-Item -LiteralPath $RaizTmp -Recurse -Force -ErrorAction SilentlyContinue
