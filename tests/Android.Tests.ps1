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
. (Join-Path $PSScriptRoot "Helpers.ps1")

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

    # Un AGP de antes de 2021 no conoce base-extension y suelta una traza de cien
    # lineas por paquete (comprobado con el 3.4.2: 360 lineas; sin el campo,
    # ninguna). true es lo que se supone cuando falta; false si dice algo.
    $conBase = [xml]@"
<sdk:sdk-repository xmlns:sdk="http://schemas.android.com/sdk/android/repo/repository2/03" xmlns:common="http://schemas.android.com/repository/android/common/02" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<channel id="channel-0">stable</channel>
<remotePackage path="platforms;android-28"><type-details xsi:type="sdk:platformDetailsType"><api-level>28</api-level><codename/><base-extension>true</base-extension><layoutlib api="15"/></type-details><revision><major>6</major></revision><display-name>p28</display-name><channelRef ref="channel-0"/><archives>$(Archivo 'p28.zip')</archives></remotePackage>
<remotePackage path="platforms;android-35-ext14"><type-details xsi:type="sdk:platformDetailsType"><api-level>35</api-level><base-extension>false</base-extension><extension-level>14</extension-level></type-details><revision><major>1</major></revision><display-name>p35e</display-name><channelRef ref="channel-0"/><archives>$(Archivo 'p35e.zip')</archives></remotePackage>
</sdk:sdk-repository>
"@
    $pb = @(ConvertFrom-AndroidIndex -Xml $conBase)

    It "sin base-extension cuando vale true, y lo demas de su tipo igual" {
        $t = ConvertTo-AndroidPackageXml -Paquete @($pb | Where-Object { $_.Path -eq 'platforms;android-28' })[0]
        $t | Should Not Match 'base-extension'
        $t | Should Match '<api-level>28</api-level>'
        $t | Should Match '<layoutlib api="15"'
    }

    It "con false se queda: es una plataforma de extension" {
        $t = ConvertTo-AndroidPackageXml -Paquete @($pb | Where-Object { $_.Path -eq 'platforms;android-35-ext14' })[0]
        $t | Should Match '<base-extension>false</base-extension>'
        $t | Should Match '<extension-level>14</extension-level>'
    }

    # Los que dejo un kit de antes, como los del equipo del trabajo.
    It "Repair-AndroidPackageXml lo quita de los ya escritos y no toca lo demas" {
        $sdk = Join-Path $RaizTmp 'sdk-reparar'
        $img = Join-Path $sdk 'system-images\android-26\default\x86_64'
        $bt = Join-Path $sdk 'build-tools\28.0.3'
        New-Item -ItemType Directory -Path $img, $bt -Force | Out-Null
        $viejo = "<ns2:repository><localPackage path=`"system-images;android-26;default;x86_64`"><type-details>`r`n  <api-level>26</api-level>`r`n  <base-extension>true</base-extension>`r`n  <abi>x86_64</abi>`r`n</type-details></localPackage></ns2:repository>"
        $otro = '<ns2:repository><localPackage path="build-tools;28.0.3"/></ns2:repository>'
        [IO.File]::WriteAllText((Join-Path $img 'package.xml'), $viejo)
        [IO.File]::WriteAllText((Join-Path $bt 'package.xml'), $otro)
        Repair-AndroidPackageXml -Sdk $sdk | Should Be 1
        [IO.File]::ReadAllText((Join-Path $img 'package.xml')) | Should Be ($viejo -replace "`r`n  <base-extension>true</base-extension>", '')
        [IO.File]::ReadAllText((Join-Path $bt 'package.xml')) | Should Be $otro
        Repair-AndroidPackageXml -Sdk $sdk | Should Be 0
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

Describe "La red de la empresa abre el HTTPS" {

    # Tal cual salio en el primer equipo del trabajo: el wrapper de Gradle,
    # con el JDK 8 del kit, no podia ni bajar Gradle.
    $pkix = @(
        'Downloading https://services.gradle.org/distributions/gradle-5.1.1-all.zip'
        'Exception in thread "main" javax.net.ssl.SSLHandshakeException: PKIX path building failed: sun.security.provider.certpath.SunCertPathBuilderException: unable to find valid certification path to requested target'
        '        at sun.security.ssl.Alert.createSSLException(Alert.java:131)'
        '        at org.gradle.wrapper.GradleWrapperMain.main(GradleWrapperMain.java:61)'
        'Caused by: sun.security.validator.ValidatorException: PKIX path building failed: sun.security.provider.certpath.SunCertPathBuilderException: unable to find valid certification path to requested target'
        '        at sun.security.validator.PKIXValidator.doBuild(PKIXValidator.java:456)'
        '        ... 23 more'
        'Caused by: sun.security.provider.certpath.SunCertPathBuilderException: unable to find valid certification path to requested target'
        '        ... 29 more'
    )

    It "se reconoce, y la traza se queda en una linea" {
        $e = @{ EnTraza = $false; Avisado = $false; Certificado = $false }
        $v = @($pkix | ForEach-Object { Select-GradleLine -Linea $_ -Estado $e } | Where-Object { $null -ne $_ })
        $e.Certificado | Should Be $true
        $v.Count | Should Be 2
        $v[0] | Should Match 'Downloading'
        $v[1] | Should Match 'certificado de la empresa'
    }

    It "Invoke-AndroidBuild lo devuelve, para que Start-AndroidApp lo arregle y reintente" {
        $p = Join-Path $RaizTmp 'pkix-proy'
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $p 'gradlew.bat'), "@echo off`r`necho $($pkix[1])`r`nexit /b 1`r`n")
        Mock Write-Host { }
        $r = Invoke-AndroidBuild -Proyecto $p -Jdk 'C:\no-hace-falta' -Sdk 'C:\no-hace-falta'
        $r.Ok | Should Be $false
        $r.Certificado | Should Be $true
    }

    Context "poner la CA de la empresa en el JDK" {

        $CorpCaFile = Join-Path $RaizTmp 'ca\corp-ca.cer'
        $CorpCaPem = Join-Path $RaizTmp 'ca\corp-ca.pem'
        $raiz = @(Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.RawData.Length -gt 0 })[0]
        Mock Import-JdkCertificate { [PSCustomObject]@{ Ok = $true; Salida = @() } }
        Mock Sync-JdkCertificates { @() }

        It "sin interceptacion no toca nada" {
            Mock Find-CorpCa { [PSCustomObject]@{ Interceptado = $false; Motivo = 'las raices son publicas'; Cert = $null } }
            (Sync-AndroidCorpCa -Jdk 'C:\jdk').Estado | Should Be 'sin-interceptacion'
            Test-Path -LiteralPath $CorpCaFile | Should Be $false
            Assert-MockCalled Import-JdkCertificate -Times 0 -Scope It
        }

        # Los sitios de Gradle y no otros: la empresa puede no abrir algunos.
        It "con interceptacion la guarda, la pone en el JDK, mirando los sitios de Gradle" {
            Mock Find-CorpCa { [PSCustomObject]@{ Interceptado = $true; Motivo = 'llega firmado por una raiz que Java no conoce'; Cert = $raiz; Subject = $raiz.Subject } }
            (Sync-AndroidCorpCa -Jdk 'C:\jdk').Estado | Should Be 'puesta'
            Test-Path -LiteralPath $CorpCaFile | Should Be $true
            Assert-MockCalled Find-CorpCa -Times 1 -Scope It -ParameterFilter { $Hosts -contains 'services.gradle.org' }
            Assert-MockCalled Import-JdkCertificate -Times 1 -Scope It -ParameterFilter { $JdkPath -eq 'C:\jdk' }
        }

        # Contra el JDK que falla, no contra el mas nuevo del kit: el del
        # proyecto puede ser un 8 que ya no trae raices que los nuevos si.
        It "compara con el JDK del proyecto" {
            Remove-Item -LiteralPath $CorpCaFile -Force -ErrorAction SilentlyContinue
            Mock Find-CorpCa { [PSCustomObject]@{ Interceptado = $false; Motivo = 'x'; Cert = $null } }
            Sync-AndroidCorpCa -Jdk 'C:\jdk8' | Out-Null
            Assert-MockCalled Find-CorpCa -Times 1 -Scope It -ParameterFilter { $JdkPath -eq 'C:\jdk8' }
        }

        # Paso en el primer equipo del trabajo: se puso el certificado del
        # sitio (CN=gradle.org) y se volvio a compilar para nada.
        $cadena = New-CadenaDePrueba

        It "si solo se ve el certificado del sitio, no pone nada" {
            Remove-Item -LiteralPath $CorpCaFile -Force -ErrorAction SilentlyContinue
            Mock Find-CorpCa { [PSCustomObject]@{ Interceptado = $true; Motivo = 'no se ve la CA que lo firma'; Cert = $null } }
            $r = Sync-AndroidCorpCa -Jdk 'C:\jdk'
            $r.Estado | Should Be 'no-se-pudo'
            $r.Detalle | Should Match 'no se ve la CA'
            Test-Path -LiteralPath $CorpCaFile | Should Be $false
            Assert-MockCalled Import-JdkCertificate -Times 0 -Scope It
        }

        It "con -Certificado de un sitio, se niega: hace falta el raiz" {
            $f = Join-Path $RaizTmp 'sitio.cer'
            [IO.File]::WriteAllBytes($f, $cadena.Sitio.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
            Mock Find-CorpCa { throw 'no deberia buscar' }
            $r = Sync-AndroidCorpCa -Jdk 'C:\jdk' -Certificado $f
            $r.Estado | Should Be 'no-se-pudo'
            $r.Detalle | Should Match 'RAIZ'
            Assert-MockCalled Import-JdkCertificate -Times 0 -Scope It
        }

        # Es lo que quedo guardado en ese equipo: la siguiente vez tiene que
        # buscar la buena, no reponer la mala en cada JDK.
        It "una guardada que no es de una CA se ignora y se busca otra vez" {
            New-Item -ItemType Directory -Path (Split-Path -Parent $CorpCaFile) -Force | Out-Null
            [IO.File]::WriteAllBytes($CorpCaFile, $cadena.Sitio.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
            Mock Get-JdkTrustedAliases { @('otra') }
            Mock Find-CorpCa { [PSCustomObject]@{ Interceptado = $true; Motivo = 'raiz que Java no conoce'; Cert = $cadena.Raiz; Subject = $cadena.Raiz.Subject } }
            (Sync-AndroidCorpCa -Jdk 'C:\jdk').Estado | Should Be 'puesta'
            Assert-MockCalled Find-CorpCa -Times 1 -Scope It
            (New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CorpCaFile)).Thumbprint | Should Be $cadena.Raiz.Thumbprint
        }

        It "si ya hay una guardada y este JDK no la tiene, la pone sin volver a buscar" {
            Mock Get-JdkTrustedAliases { @('otra') }
            Mock Find-CorpCa { throw 'no deberia buscar' }
            (Sync-AndroidCorpCa -Jdk 'C:\jdk8').Estado | Should Be 'puesta'
            Assert-MockCalled Find-CorpCa -Times 0 -Scope It
        }

        It "con -Certificado, el que se le da" {
            $f = Join-Path $RaizTmp 'empresa.cer'
            [IO.File]::WriteAllBytes($f, $raiz.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
            Mock Find-CorpCa { throw 'no deberia buscar' }
            $r = Sync-AndroidCorpCa -Jdk 'C:\jdk' -Certificado $f
            $r.Estado | Should Be 'puesta'
            $r.Detalle | Should Match 'se indico'
        }
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

Describe "El registro de la app" {

    # Tal cual las escribe "adb logcat -v threadtime" en Android 8.
    It "una linea del registro, por partes" {
        $l = ConvertFrom-LogcatLine -Linea '11-19 05:05:17.532  1976  1976 E AndroidRuntime: FATAL EXCEPTION: main'
        "$($l.Hora)|$($l.Pid)|$($l.Nivel)|$($l.Etiqueta)|$($l.Mensaje)" | Should Be '05:05:17|1976|E|AndroidRuntime|FATAL EXCEPTION: main'
    }

    It "con etiquetas raras y dos puntos en el mensaje" {
        $l = ConvertFrom-LogcatLine -Linea '11-19 06:36:01.004  3263  3290 D Mi App : url: http://servidor:8080/x'
        $l.Etiqueta | Should Be 'Mi App'
        $l.Mensaje | Should Be 'url: http://servidor:8080/x'
    }

    It "lo que no es una linea de registro se descarta" {
        ConvertFrom-LogcatLine -Linea '--------- beginning of main' | Should BeNullOrEmpty
        ConvertFrom-LogcatLine -Linea '' | Should BeNullOrEmpty
    }

    # Asi la sigue aunque se cierre y se abra: cambia de proceso, y logcat
    # --pid solo sirve para uno.
    It "se entera de cuando la app arranca y muere, en Android 8 y en los de ahora" {
        $a = Get-LogcatAppProcess -Mensaje 'Start proc 3263:com.empresa.app/u0a80 for activity com.empresa.app/.Main' -Paquete 'com.empresa.app'
        "$($a.Evento) $($a.Pid)" | Should Be 'arranca 3263'
        $b = Get-LogcatAppProcess -Mensaje 'Start proc 4410:com.empresa.app/u0a80 for pre-top-activity {com.empresa.app/com.empresa.app.Main}' -Paquete 'com.empresa.app'
        "$($b.Evento) $($b.Pid)" | Should Be 'arranca 4410'
        $c = Get-LogcatAppProcess -Mensaje 'Process com.empresa.app (pid 3263) has died: fore TOP' -Paquete 'com.empresa.app'
        "$($c.Evento) $($c.Pid)" | Should Be 'muere 3263'
    }

    # Paso: al forzar el cierre, Android 8 no dice "has died" sino esto, y el
    # registro no avisaba de que la app se habia cerrado.
    It "tambien cuando la cierran (Forzar detencion o el sistema)" {
        $d = Get-LogcatAppProcess -Mensaje 'Killing 3404:com.empresa.app/u0a65 (adj 0): stop com.empresa.app' -Paquete 'com.empresa.app'
        "$($d.Evento) $($d.Pid)" | Should Be 'muere 3404'
    }

    It "cuentan sus subprocesos, pero no otra app que empiece igual" {
        (Get-LogcatAppProcess -Mensaje 'Start proc 5000:com.empresa.app:sync/u0a80 for service' -Paquete 'com.empresa.app').Pid | Should Be 5000
        Get-LogcatAppProcess -Mensaje 'Start proc 5001:com.empresa.appotra/u0a81 for activity' -Paquete 'com.empresa.app' | Should BeNullOrEmpty
        Get-LogcatAppProcess -Mensaje 'Displayed com.empresa.app/.Main: +480ms' -Paquete 'com.empresa.app' | Should BeNullOrEmpty
    }
}

Describe "VS Code: que entienda el proyecto y lo depure" {

    # La lista de lo que usa el plugin de Android, como la escribe la tarea del
    # script de inicio. Solo cuenta lo que existe: el proyecto de 2019 no tiene
    # carpetas de aidl ni de renderscript, y enlazarlas daria error.
    $cpDir = Join-Path $RaizTmp 'clases'
    $srcDir = Join-Path $cpDir 'app\src\main\java'
    $genDir = Join-Path $cpDir 'app\build\generated\source\r'
    $jar1 = Join-Path $cpDir 'android.jar'
    $jar2 = Join-Path $cpDir 'classes.jar'
    New-Item -ItemType Directory -Path $srcDir, $genDir -Force | Out-Null
    foreach ($j in $jar1, $jar2) { [IO.File]::WriteAllText($j, 'x') }

    It "ConvertFrom-AndroidClasspath: lo que existe, sin repetir y en orden" {
        $r = ConvertFrom-AndroidClasspath -Lineas @(
            'Mapping new ns http://schemas.android.com/sdk/android/repo/repository2/03 to old ns 01',
            "KIT-JAR $jar1", "KIT-JAR $jar2", "KIT-JAR $jar1", "KIT-JAR $(Join-Path $cpDir 'no-existe.jar')",
            "KIT-SRC $srcDir", "KIT-SRC $(Join-Path $cpDir 'aidl')", "KIT-SRC $genDir",
            'KIT-JAVA 1.8')
        $r.Jars -join '|' | Should Be "$jar1|$jar2"
        $r.Fuentes -join '|' | Should Be "$srcDir|$genDir"
        $r.Java | Should Be '1.8'
        $r.Error | Should BeNullOrEmpty
    }

    # Un gradlew.bat de mentira que escribe lo que escribiria la tarea, y guarda
    # con que argumentos se le llamo.
    $proy = Join-Path $RaizTmp 'cp-proy'
    New-Item -ItemType Directory -Path $proy -Force | Out-Null
    $args_ = Join-Path $RaizTmp 'cp-args.txt'

    It "Get-AndroidClasspath: le pasa a Gradle su script de inicio y la tarea del modulo, y lee la respuesta" {
        [IO.File]::WriteAllText((Join-Path $proy 'gradlew.bat'), "@echo off`r`necho %*> `"$args_`"`r`nif exist `"%3`" echo init-existe>> `"$args_`"`r`necho KIT-JAR $jar1`r`necho KIT-SRC $srcDir`r`necho KIT-JAVA 1.8`r`nexit /b 0`r`n")
        $r = Get-AndroidClasspath -Proyecto $proy -Jdk 'C:\no-hace-falta' -Sdk 'C:\no-hace-falta' -Modulo 'app'
        $r.Ok | Should Be $true
        $r.Jars | Should Be $jar1
        $r.Fuentes | Should Be $srcDir
        $r.Java | Should Be '1.8'
        $llamada = [IO.File]::ReadAllText($args_)
        $llamada | Should Match '^-q -I \S+\.gradle :app:criisdevkitClasspath'
        $llamada | Should Match 'init-existe'
        # Y no se deja el script de inicio por ahi.
        $init = [regex]::Match($llamada, '-I (\S+\.gradle)').Groups[1].Value
        Test-Path -LiteralPath $init | Should Be $false
    }

    # Con un AGP sin la API de variantes de siempre, o un proyecto raro: Gradle
    # dice que no hay tal tarea. Se cuenta por que y no se rompe nada.
    It "Get-AndroidClasspath: si Gradle falla, Ok en falso y el motivo" {
        [IO.File]::WriteAllText((Join-Path $proy 'gradlew.bat'), "@echo off`r`necho Task 'criisdevkitClasspath' not found in project ':app'.`r`nexit /b 1`r`n")
        $r = Get-AndroidClasspath -Proyecto $proy -Jdk 'C:\no-hace-falta' -Sdk 'C:\no-hace-falta'
        $r.Ok | Should Be $false
        $r.Detalle | Should Match 'not found'
    }

    It "el script de inicio es Groovy que cualquier Gradle lee, y ASCII como el resto" {
        $AndroidClasspathScript | Should Match "tasks\.create\('criisdevkitClasspath'\)"
        $AndroidClasspathScript | Should Match 'applicationVariants'
        $AndroidClasspathScript | Should Not Match '[^\x00-\x7F]'
    }

    # Un proyecto con & en la ruta: va a XML y tiene que ir escapado.
    $raizP = Join-Path $RaizTmp 'P&R'
    $p1 = Join-Path $raizP 'mi-app'
    $ws = Join-Path $RaizTmp 'vscode'
    New-Item -ItemType Directory -Path (Join-Path $p1 'app\src\main\java'), (Join-Path $p1 'app\build\gen') -Force | Out-Null
    $fuentes = @((Join-Path $p1 'app\src\main\java'), (Join-Path $p1 'app\build\gen'))

    It "deja el proyecto sombra: enlaza cada carpeta de codigo y declara cada jar" {
        $r = Write-AndroidVsCodeWorkspace -Proyecto $p1 -Jdk 'C:\jdk-8' -Fuentes $fuentes -Jars @($jar1, $jar2) -Java '1.8' -Destino $ws
        $r.Fuentes | Should Be 2
        $r.Jars | Should Be 2
        $proj = [xml](Get-Content -LiteralPath (Join-Path $r.Sombra '.project') -Raw)
        $proj.projectDescription.name | Should Be 'mi-app (kit)'
        $proj.projectDescription.natures.nature | Should Be 'org.eclipse.jdt.core.javanature'
        $links = @($proj.projectDescription.linkedResources.link)
        @($links | ForEach-Object { $_.name }) -join '|' | Should Be 'app_src_main_java|app_build_gen'
        $links[0].location | Should Be (($fuentes[0]) -replace '\\', '/')
        $cp = [xml](Get-Content -LiteralPath (Join-Path $r.Sombra '.classpath') -Raw)
        @($cp.classpath.classpathentry | Where-Object { $_.kind -eq 'src' } | ForEach-Object { $_.path }) -join '|' | Should Be 'app_src_main_java|app_build_gen'
        @($cp.classpath.classpathentry | Where-Object { $_.kind -eq 'lib' }).Count | Should Be 2
        @($cp.classpath.classpathentry | Where-Object { $_.kind -eq 'con' }).path | Should Be 'org.eclipse.jdt.launching.JRE_CONTAINER'
        @(Get-Content -LiteralPath (Join-Path $r.Sombra '.settings\org.eclipse.jdt.core.prefs')) -contains 'org.eclipse.jdt.core.compiler.source=1.8' | Should Be $true
    }

    It "y el espacio de trabajo: las dos carpetas, sin importar por Gradle, y como depurar" {
        $r = Write-AndroidVsCodeWorkspace -Proyecto $p1 -Jdk 'C:\jdk-8' -Puerto 5006 -Fuentes $fuentes -Jars @($jar1) -Destino $ws
        $r.Archivo | Should Be (Join-Path $ws 'mi-app.code-workspace')
        $j = Get-Content -LiteralPath $r.Archivo -Raw | ConvertFrom-Json
        @($j.folders)[0].path | Should Be ($p1 -replace '\\', '/')
        @($j.folders)[1].path | Should Be ($r.Sombra -replace '\\', '/')
        $j.settings.'java.import.gradle.enabled' | Should Be $false
        $j.settings.'java.gradle.buildServer.enabled' | Should Be 'off'
        $c = @($j.launch.configurations)[0]
        "$($c.type) $($c.request) $($c.hostName) $($c.port)" | Should Be 'java attach localhost 5006'
        $c.name | Should Be $AndroidDepurarNombre
        $c.projectName | Should Be 'mi-app (kit)'
    }

    # Lo que pidio el usuario: nada del kit dentro de su repositorio.
    It "no escribe nada dentro del proyecto" {
        $antes = @(Get-ChildItem -LiteralPath $p1 -Recurse -Force | ForEach-Object { $_.FullName })
        Write-AndroidVsCodeWorkspace -Proyecto $p1 -Jdk 'C:\jdk-8' -Fuentes $fuentes -Jars @($jar1) -Destino $ws | Out-Null
        @(Get-ChildItem -LiteralPath $p1 -Recurse -Force | ForEach-Object { $_.FullName }) -join '|' | Should Be ($antes -join '|')
    }

    It "otro proyecto con el mismo nombre de carpeta no pisa el espacio de trabajo del primero" {
        $p2 = Join-Path $RaizTmp 'otra\mi-app'
        New-Item -ItemType Directory -Path $p2 -Force | Out-Null
        $r2 = Write-AndroidVsCodeWorkspace -Proyecto $p2 -Jdk 'C:\jdk-8' -Destino $ws
        $r2.Archivo | Should Match 'mi-app-[0-9a-f]{6}\.code-workspace$'
        $r2.Sombra | Should Not Be (Write-AndroidVsCodeWorkspace -Proyecto $p1 -Jdk 'C:\jdk-8' -Destino $ws).Sombra
        (Write-AndroidVsCodeWorkspace -Proyecto $p1 -Jdk 'C:\jdk-8' -Destino $ws).Archivo | Should Be (Join-Path $ws 'mi-app.code-workspace')
    }

    It "la version de Java del codigo: la que dice Gradle, y 1.8 si no dice" {
        $r = Write-AndroidVsCodeWorkspace -Proyecto $p1 -Jdk 'C:\jdk-17' -Java '17' -Destino $ws
        @(Get-Content -LiteralPath (Join-Path $r.Sombra '.settings\org.eclipse.jdt.core.prefs')) -contains 'org.eclipse.jdt.core.compiler.compliance=17' | Should Be $true
        $r = Write-AndroidVsCodeWorkspace -Proyecto $p1 -Jdk 'C:\jdk-8' -Destino $ws
        @(Get-Content -LiteralPath (Join-Path $r.Sombra '.settings\org.eclipse.jdt.core.prefs')) -contains 'org.eclipse.jdt.core.compiler.compliance=1.8' | Should Be $true
    }

    # En Pester 3.4 un Mock dentro de un It dura hasta el final de su bloque:
    # cada caso en su Context, o el Test-Path falso de uno tapa el otro.
    Context "Open-AndroidVsCodeWorkspace sin VS Code" {
        It "dice que no y no lanza nada" {
            Mock Get-Command { $null }
            Mock Test-Path { $false } -ParameterFilter { $LiteralPath -match 'code\.cmd$' }
            Mock Start-Process { }
            Open-AndroidVsCodeWorkspace -Archivo 'C:\x.code-workspace' | Should Be $false
            Assert-MockCalled Start-Process -Times 0 -Scope It
        }
    }

    Context "Open-AndroidVsCodeWorkspace con VS Code" {
        $code = Join-Path $RaizTmp 'code.cmd'
        [IO.File]::WriteAllText($code, '@echo off')
        It "le pasa el espacio de trabajo entre comillas" {
            Mock Get-Command { [PSCustomObject]@{ Source = $code } }
            Mock Start-Process { }
            Open-AndroidVsCodeWorkspace -Archivo 'C:\con espacio\x.code-workspace' | Should Be $true
            Assert-MockCalled Start-Process -Times 1 -Scope It -ParameterFilter { $FilePath -eq $code -and "$ArgumentList" -eq '"C:\con espacio\x.code-workspace"' }
        }
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

Describe "Quitar: cerrar lo que corre desde las carpetas" {

    # Paso en el equipo del trabajo: adb seguia de servidor tras cerrar el
    # telefono, y borrar el SDK se paro en adb.exe a medias. Aqui hace de adb
    # un ping copiado dentro: un .exe en marcha, que es lo que bloquea.
    $sdk = Join-Path $RaizTmp 'quitar\Android\sdk'
    $pt = Join-Path $sdk 'platform-tools'
    New-Item -ItemType Directory -Path $pt -Force | Out-Null
    Copy-Item (Join-Path $env:SystemRoot 'System32\PING.EXE') (Join-Path $pt 'ping.exe')
    $p = Start-Process -FilePath (Join-Path $pt 'ping.exe') -ArgumentList '-n', '60', '127.0.0.1' -WindowStyle Hidden -PassThru

    try {
        It "lo encuentra por la ruta de su .exe" {
            @(Get-ProcessUnder -Carpetas @($sdk) | ForEach-Object { $_.Id }) -contains $p.Id | Should Be $true
        }

        # "...\Android\sd" no es la carpeta de "...\Android\sdk\platform-tools".
        It "no confunde una carpeta con otra que empieza igual" {
            @(Get-ProcessUnder -Carpetas @($sdk.Substring(0, $sdk.Length - 1)) | ForEach-Object { $_.Id }) -contains $p.Id | Should Be $false
        }

        It "con el en marcha no se puede borrar; cerrado, si" {
            { Remove-Item -LiteralPath $sdk -Recurse -Force -ErrorAction Stop } | Should Throw
            Stop-ProcessUnder -Carpetas @(Join-Path $RaizTmp 'no-existe'), $sdk | Should Be 'ping.exe'
            $p.HasExited | Should Be $true
            Remove-Item -LiteralPath $sdk -Recurse -Force -ErrorAction Stop
            Test-Path -LiteralPath $sdk | Should Be $false
        }

        It "sin nada en marcha no cierra nada" {
            @(Stop-ProcessUnder -Carpetas @($RaizTmp)).Count | Should Be 0
        }
    }
    finally { if (-not $p.HasExited) { $p.Kill() } }
}

Remove-Item -LiteralPath $RaizTmp -Recurse -Force -ErrorAction SilentlyContinue
