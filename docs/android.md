# Android

Compilar una app de Android (Java o Kotlin) y abrirla en un telefono virtual ligero,
de una vez, sin permisos de administrador y sin Android Studio. Todo dentro del
equipo: ni servicios externos ni dispositivos conectados.

> Parte de la documentacion de **CriisDevKit**. Vuelta al [README](../README.md).

## Antes de nada: el emulador necesita una casilla de Windows

El emulador solo va rapido si Windows le deja usar la virtualizacion del procesador,
y eso es la **"Plataforma del hipervisor de Windows"**. Activarla pide admin (una
casilla en *Caracteristicas de Windows* y reiniciar), pero comprobar si ya esta
activada no lo pide:

```powershell
(Get-CimInstance Win32_OptionalFeature -Filter "Name='HypervisorPlatform'").InstallState
```

`1` es activada. Si sale otra cosa, el emulador no arranca y eso es lo que hay que
pedir a IT; compilar si se puede igual, porque no necesita nada de esto. El kit lo
comprueba **antes** de bajar el emulador (mas de 1 GB), y `Doctor` lo dice aunque no
este instalado.

Y el kit, **fuera de OneDrive**: instala todo junto a su carpeta, y el SDK con el
emulador son unos 2 GB que OneDrive intentaria subir.

## Como se usa: una sola opcion

```
Menu.bat  ->  60  Compilar y probar una app  ->  la carpeta del proyecto
```

La carpeta del proyecto es la que tiene `gradlew.bat`. Con eso, el kit:

1. **Lee el proyecto**: con que version del plugin de Android (AGP) se compila, y
   de ahi que JDK, plataforma y build-tools pide.
2. **Instala lo que falte**, solo la primera vez: el JDK que toque, el SDK, el
   emulador y un telefono virtual. Pregunta por la licencia de Google (se contesta
   `SI`). Son hasta 1,3 GB y unos minutos.
3. **Compila** (`gradlew assembleDebug`). La primera vez Gradle baja tambien su
   version y las librerias del proyecto.
4. **Abre la app en el telefono**: lo arranca, o usa el que ya este abierto, la
   instala y la abre.

Las siguientes veces la carpeta ya sale por defecto: **Intro**, y en menos de un
minuto la version nueva esta abierta en el telefono, que se queda abierto entre una
y otra. El ciclo de trabajo es ese: cambiar el codigo, opcion 60, Intro.

La opcion **61** abre solo el telefono, sin compilar nada. La **62** y la **63**, mas
abajo: ver lo que escribe la app, y depurarla en VS Code.

Desde una consola es lo mismo:

```powershell
.\bin\start\Start-AndroidApp.bat -Path C:\ruta\del\proyecto
.\bin\start\Start-AndroidApp.bat                      El de la ultima vez
.\bin\start\Start-AndroidApp.bat -Api 30              En un telefono con Android 11
.\bin\start\Start-AndroidApp.bat -SoloCompilar        Sin el telefono
```

El telefono es Android 8 (API 26) salvo que la app pida uno mas alto (su `minSdk`):
entonces, ese.

## Ver lo que escribe la app (62)

```powershell
.\bin\start\Start-AndroidLog.bat                         La app del ultimo proyecto
.\bin\start\Start-AndroidLog.bat -Paquete com.empresa.app
```

El registro de Android (logcat) mezcla lo de todas las apps y el sistema, cientos de
lineas por segundo. Esto ensena solo lo de tu app: sus `Log.d`, `Log.e`... y sus
errores, `FATAL EXCEPTION` incluido, en color segun la gravedad. Empieza por lo ultimo
que escribio, por si lo que buscas acaba de pasar, y despues sigue en directo.

La sigue aunque se cierre y se vuelva a abrir, que cambia de proceso: se entera por
los avisos del propio sistema y lo dice (`--- la app se cerro`, `--- la app arranca`).
Con varios telefonos abiertos mira el del kit que tenga la app. Ctrl+C para salir.

## Depurar en VS Code (63)

```powershell
.\bin\start\Start-AndroidApp.bat -Depurar
```

Compila e instala como la 60, pero abre la app **parada**, esperando al depurador,
para poder parar incluso en lo primero que hace. Y prepara VS Code para que
**entienda el proyecto**: autocompleta las clases de Android y de las librerias, no
marca en rojo lo que compila bien, y depura con F5. Lo abre solo:

1. Espera a que abajo diga "Java: Ready". La primera vez tarda algo mas: indexa las
   librerias.
2. Abre tus archivos desde la carpeta del proyecto (la otra, "clases para VS Code
   (kit)", es del kit).
3. Pon un punto de interrupcion: clic a la izquierda del numero de linea.
4. **F5**, con "Android: depurar la app (kit)".

Hace falta la extension "Extension Pack for Java" (trae la de Java y la del
depurador).

### Que prepara, y por que asi

La extension de Java de VS Code importa los proyectos por Gradle, y no entiende el
plugin de Android: sin las clases de Android, sin autocompletar y con rojo en lo que
compila bien. Lo que si sabe leer es un proyecto de Eclipse con su lista de clases, y
eso es lo que deja la 63, todo en `Android\vscode`, **nada dentro del proyecto**:

| | |
|---|---|
| `<proyecto>.code-workspace` | lo que se abre en VS Code: la carpeta del proyecto, la del kit, los ajustes y la configuracion para depurar |
| `<proyecto>-<hash>\` | un proyecto "sombra": `.project` y `.classpath` de Eclipse que enlazan las carpetas de codigo y declaran `android.jar` y las librerias |

La lista se la pregunta al propio Gradle con un script de inicio (`-I`) que anade una
tarea solo para esa ejecucion: las carpetas de codigo, las que genera la compilacion
(R, BuildConfig, las de ButterKnife y demas procesadores de anotaciones) y los jar de
las librerias, ya sacados de sus `.aar`. Con el proyecto de 2019: 4 carpetas y 46 jar,
en unos segundos.

Lo que se probo antes de llegar aqui, para no repetirlo:

- **Darle a VS Code el JDK del proyecto** (`java.import.gradle.java.home`): Gradle
  carga (`CONFIGURE SUCCESSFUL`), pero la extension de Java sigue sin entender el
  plugin de Android.
- **Pasarle la lista con `java.project.referencedLibraries`**: solo vale para
  carpetas sin `build.gradle`; con el, la extension trata cada archivo como suelto
  ("non-project file", solo errores de sintaxis).
- **El proyecto sombra**: comprobado primero hablando con el servidor de la extension
  de Java 1.58 sin VS Code, y despues en VS Code. 0 errores; autocompleta `Toast`,
  `R.id` (los 227 ids de la app) y la libreria de soporte; encuentra
  `AppCompatActivity`.

Lo que no da: el disenador de layouts ni la ayuda en los XML de Android, que siguen
siendo de Android Studio. Si anades un recurso, la 60 lo compila y VS Code lo ve; si
anades una **libreria**, vuelve a pasar por la 63, que es cuando se rehace la lista.
Con Kotlin no ayuda: la extension de Java no lee Kotlin.

### La depuracion

Android habla el mismo protocolo de depuracion que Java (JDWP), y el kit deja un
puente desde `localhost:5005` hasta la app (`adb forward`, que solo escucha en el
propio equipo: sin avisos del firewall).

Comprobado con un proyecto real de 2019 en Android 8, con `jdb` y con el depurador de
VS Code: se para en la linea, ensena la pila de llamadas, avanza paso a paso y lee las
variables. Dos detalles que salieron al probarlo y el kit ya resuelve:

- **La app se queda marcada para esperar al depurador**, y las siguientes veces que se
  abriera, a mano o con la 60, se quedaria en "Waiting For Debugger". El kit borra la
  marca en cuanto la app esta esperando, y otra vez antes de cada apertura normal.
- **Si el ultimo dialogo abierto era de Android** (el de los permisos de la primera
  vez), pedir que se abra la app solo lo traia al frente, sin arrancarla. Se abre con
  la pila limpia.

Android espera al depurador solo un momento despues de que se conecta (segundo y
medio): los puntos de interrupcion tienen que estar puestos antes de pulsar F5. VS Code
los manda todos al conectarse.

### Las trazas del plugin de Android de antes de 2021

Ese plugin no conoce el campo `base-extension` de los `package.xml` del SDK de ahora y
suelta una traza de cien lineas por cada paquete que lo lleva: en la compilacion (el
kit las oculta) y en VS Code. El kit ya no lo escribe cuando vale `true` (lo que se
supone cuando falta) y lo quita de los que escribio antes: con el AGP 3.4.2, de cuatro
trazas y 360 lineas a ninguna. El emulador no lee esos archivos.
## Sin avisos del firewall

Antes, cada compilacion hacia saltar el aviso de Windows para `java.exe`, y el
emulador el de `adb.exe`. Medido, no supuesto:

| | Que abria | Aviso |
|---|---|---|
| Gradle con daemon | un puerto TCP en **todas** las direcciones del equipo | si |
| adb | mDNS, para buscar telefonos por la red: UDP en todas | si |
| Gradle **sin** daemon | ningun puerto | no |
| adb con `ADB_MDNS=0` | solo `127.0.0.1` | no |

El kit va ahora siempre de la segunda forma, tanto `Start-AndroidApp` como
`android-shell.bat`. Comprobado con un `java.exe` y un `adb.exe` que el firewall no
conocia, con Gradle 5 y con Gradle 9: ningun aviso, ni ninguna regla nueva en su
registro.

Sin daemon, cada compilacion arranca Java de nuevo (unos segundos mas), pero a cambio
la memoria se libera al terminar, que en un equipo justo es justo lo que hace falta.

## La red de la empresa abre el HTTPS

En muchas empresas el proxy abre las conexiones HTTPS y las vuelve a firmar con un
certificado propio. Windows lo conoce (IT lo instala), y por eso las descargas del kit
funcionan. Pero cada JDK trae su propio almacen de certificados, sin el de la empresa,
y Gradle corre sobre Java: el wrapper no puede ni bajar Gradle.

```
javax.net.ssl.SSLHandshakeException: PKIX path building failed
```

`Start-AndroidApp` lo arregla solo cuando pasa: busca la raiz de la empresa mirando
quien firma los sitios de los que baja Gradle (services.gradle.org, dl.google.com...),
y si Java no la conoce, la guarda y la mete en el JDK del proyecto (con `keytool`, sin
admin), y vuelve a compilar. Los JDK que se instalen despues ya la llevan. En una red
que no abre el HTTPS no hace nada.

Si no la encuentra, el certificado raiz lo da IT (un `.cer`):

```powershell
.\bin\start\Start-AndroidApp.bat -Path C:\ruta\del\proyecto -Certificado C:\ruta\empresa.cer
```

Paso en el primer equipo del trabajo, y de paso salio que con el **JDK 8** nunca habria
funcionado: su almacen esta en `jre\lib\security\cacerts`, no en `lib\security\cacerts`
como en los de ahora, y el kit solo miraba lo segundo. Comprobado aqui sobre un JDK 8
de verdad: detecta la raiz, la guarda y la pone (misma huella). Lo que no se puede
probar aqui es una red que abra el HTTPS: eso esta en los [pendientes](pendientes.md).

La segunda vez en ese equipo puso el certificado **del sitio** (`CN=gradle.org`,
firmado por el proxy) en vez del de la CA, y la segunda compilacion fallo igual: la
cadena se armaba sin los intermedios que manda el servidor. Ya no; y el kit nunca
pone un certificado que no sea de una CA. Uno mal puesto se sustituye solo la
siguiente vez. Si aun asi sigue fallando, lo dice y pide el `.cer` de IT. Los
detalles, en [red corporativa](red-corporativa.md#como-decide-si-tu-red-intercepta).
Comprobado ya alli: puso la raiz del proxy y compilo a la segunda.

## Lo que instala la primera vez

| | Para que | Peso |
|---|---|---|
| `platform-tools` | `adb`, para hablar con el telefono | 8 MB |
| `build-tools` | las que usa el plugin de Android del proyecto | 56-58 MB |
| `platforms;android-N` | la plataforma con la que se compila (el `compileSdk`) | 64-72 MB |
| `emulator` | el emulador | 434 MB |
| una imagen de Android | el sistema del telefono: 452 MB la de Android 8, 687 MB la de 14 | |
| un JDK | el que pida el proyecto (8, 11, 17 o mas) | 100-200 MB |

Cada telefono virtual es una version de Android distinta, y se pueden tener varios:
el segundo solo baja su imagen.

## Varias versiones a la vez

Todo convive en el mismo SDK, y lo que ya esta no se vuelve a bajar:

| | Donde | Como se elige |
|---|---|---|
| Plataformas | `sdk\platforms\android-28`, `android-34`... | el `compileSdk` de cada proyecto; Gradle coge la suya |
| Build-tools | `sdk\build-tools\28.0.3`, `36.0.0`... | las de su AGP; Gradle coge las suyas |
| Telefonos | `kit-api26`, `kit-api34`..., uno por imagen | `-Api 26` |
| JDK | `Java\jdk-8`, `jdk-21`... | `Start-AndroidApp` lo elige solo |

Lo unico que no elige Gradle solo es el **JDK**, y es lo que mas importa: lo decide
la version de AGP del proyecto, no el `sourceCompatibility` (ese es el del bytecode).

| AGP | JDK | Build-tools que usa |
|---|---|---|
| 3.2 a 4.1 | 8 | 28.0.3 (4.0 y 4.1: 29.0.2) |
| 4.2 | 8 | 30.0.2 |
| 7.x | 11 | 30.0.2 (7.1 en adelante: 30.0.3) |
| 8.0 a 8.7 | 17 | 30.0.3, 33.0.1 o 34.0.0 |
| 8.8 a 8.13 | 17 | 35.0.0 |
| 9.x | 17 | 36.0.0 |

Las build-tools estan sacadas de los propios JAR de AGP, de la ultima version de
cada rama. Con un JDK equivocado no hay nada que hacer: un proyecto de AGP 3.4 con
Gradle 5.1.1 **no arranca** con el JDK 21 (falla Groovy antes de leer el proyecto).

### Proyectos antiguos: errores de XML que no lo son

Un AGP de antes de 2020 se queja al leer los paquetes del SDK de ahora:

```
elemento inesperado (URI:"", local:"base-extension")
```

con una traza de un centenar de lineas detras. El indice actual de Google anade
campos que ese AGP no conocia, en **todas** las plataformas e imagenes, incluso la
28; el `sdkmanager` de hoy los escribe igual. El AGP viejo lo avisa, ignora el campo
y sigue: el proyecto compila. `Start-AndroidApp` oculta ese ruido y lo dice en una
linea; las trazas de un error de verdad se ven enteras.

## El telefono

```powershell
.\bin\start\Start-AndroidEmulator.bat
.\bin\start\Start-AndroidEmulator.bat -Api 26 -Apk app\build\outputs\apk\debug\app-debug.apk
```

Arranca el telefono, espera a que Android termine de arrancar y, con `-Apk`, instala
la app y la abre. Si el emulador ya estaba abierto lo reutiliza.

- **`-EnFrio`**: arranca Android de cero, pero conserva las apps y sus datos.
- **`-Borrar`**: deja el telefono como recien comprado.

### Por que es ligero

El telefono virtual que crea el kit esta pensado para un equipo justo de recursos:
1,5 GB de RAM y 2 nucleos, pantalla de 720x1280 (la grafica es lo que mas carga), sin
audio, sin camaras y sin Play Store, y con la barra de navegacion en pantalla (sin
ella, Android 8 mostraba "System UI has stopped"). Y arranque rapido: la segunda vez
reanuda donde se quedo en vez de arrancar Android entero.

Medido en un portatil de casa:

| | |
|---|---|
| Primer arranque, Android 14 | 72 s |
| Primer arranque, Android 8 | 40 s |
| Arranques siguientes (reanuda) | 6-12 s |
| Memoria del emulador en marcha | 1,8 GB |
| Instalar y abrir la app con el emulador abierto | 3 s |

### Lo que recuerda

Un telefono virtual es como uno de verdad: lo que instalas, los datos de la app y la
sesion iniciada **se quedan** de una vez para otra (comprobado: una app instalada
antes de cerrarlo seguia ahi al abrirlo horas despues). Se guardan en
`%LOCALAPPDATA%\CriisDevKit\android-avd`, fuera de la carpeta de trabajo: escriben
gigas mientras funcionan.

## A mano, desde la consola

Lo de arriba es lo recomendado. Para quien prefiera hacer cada paso:

```powershell
.\bin\env\Setup-Project.bat -Path C:\ruta\del\proyecto   Lo que pide el proyecto, sin el telefono
.\bin\setup\Setup-AndroidEnv.bat -Emulador -Api 26       El SDK y un telefono, sin proyecto
```

`Setup-AndroidEnv` tambien acepta `-Plataforma 35`, `-BuildTools 35.0.0`, `-Jdk 8`,
`-Tipo google_apis` (imagen con los servicios de Google, para Maps, Firebase o el
inicio de sesion de Google; pesa bastante mas), `-WhatIf` (que bajaria y cuanto
pesa) y **`-Quitar`** (retira el SDK, los telefonos, `ANDROID_HOME` y sus rutas del
PATH). Antes de borrar cierra lo que se ejecute desde esas carpetas, buscado por la
ruta del `.exe`: adb se queda de servidor aunque se cierre el telefono, y en el equipo
del trabajo el borrado se paraba en `adb.exe` a medias. Un `adb.exe` de Android Studio
no se toca. Si algo no se deja borrar, sigue con lo demas y dice que.

Para compilar a mano, doble clic en `..\Android\android-shell.bat` (o en
`android-java8-shell.bat`, la que crea `Setup-Project` para un proyecto de los de
antes), y en esa consola:

```
cd /d C:\ruta\del\proyecto
gradlew assembleDebug
```

La consola trae `ANDROID_HOME`, `JAVA_HOME`, `adb` y el emulador, y **Gradle
limitado**: 1,5 GB de memoria y 2 procesos, sin daemon. Compilar Kotlin se come
facilmente mas de 2 GB, y en un equipo justo eso deja todo lo demas parado. El limite
manda aunque el `gradle.properties` del proyecto pida mas, y solo vale ahi: no cambia
la configuracion de Gradle de nadie.

El kit deja tambien `ANDROID_HOME` de usuario, para que Gradle encuentre el SDK desde
cualquier terminal o desde VS Code. Si ya apuntaba a otro SDK (el de un Android
Studio, por ejemplo) no lo cambia; con `-Force` si.

## Repartirlo a tu equipo, sin el resto del kit

```powershell
.\tools\Build-PaqueteAndroid.ps1
```

Deja `dist\CriisDevKit Android <version>.zip` con lo justo para lo de esta pagina:
un menu (`Android.bat`) con tres opciones (compilar y probar una app, abrir el
telefono, y quitar todo, Java incluido), un `LEEME.md` para quien lo recibe, y los
comandos de Android.

De la libreria va **solo lo que esos comandos usan**: el generador sigue las llamadas
desde los scripts que van dentro, con el analizador de PowerShell, y copia unas 107
funciones de las 265 del kit (unas 4.000 lineas de 25.000). Los demas runtimes,
Doctor, Use-Env, Export e Import, Visual C++, Update-Kit, las pruebas y esta
documentacion no van. Se recalcula cada vez: si el kit cambia, el paquete sigue
llevando justo lo necesario.

Antes de dar el zip por bueno lo comprueba: que se lee, que no le falta ninguna
funcion, que no manda a ningun comando que no lleve, y que arranca. Y la suite lo
vigila (`PaqueteAndroid.Tests.ps1`).

Lo que va es legible: PowerShell no se compila. Una version nueva es un zip nuevo
(el paquete no trae `Update-Kit`), y si algo falla, quien lo usa no tiene `Doctor`:
que mande el mensaje de error.

## La licencia

Instalar el SDK supone aceptar la licencia de Google. El kit la pregunta (o
`-AceptarLicencias`) y deja la aceptacion donde la busca Gradle, igual que lo haria
`sdkmanager`.

Esa aceptacion es un hash que no sale de ninguna cuenta evidente sobre el texto, asi
que el kit lo tiene **fijado**, sacado del `sdkmanager` oficial, junto con la huella
del texto al que corresponde. Si Google cambia el texto, el kit lo nota y **no**
escribe una aceptacion que ya no vale: avisa, y entonces hay que aceptarla desde
Android Studio o actualizar el kit.

## Por que sin sdkmanager

`sdkmanager` es lo que usa Android Studio para bajar el SDK. Son 148 MB de Java que
solo hacen falta para descargar, y **no sabe pasar por un proxy que pide usuario y
clave**, que es justo el de la empresa.

El kit ya descarga con proxy, reanudando y con cache, asi que lee el mismo indice que
lee `sdkmanager`, baja cada paquete contra el SHA-1 que publica Google y deja junto a
el el `package.xml` que dejaria `sdkmanager`, que es por donde Gradle y el emulador
saben que esta instalado. Comprobado contra el `sdkmanager` oficial: lista como
instalado lo que pone el kit, con su version y su nombre.

### Las build-tools, y lo que baja Gradle por su cuenta

El plugin de Android para Gradle (AGP) usa **sus** build-tools, que no son las mas
recientes: AGP 9.5.1 usa las 36.0.0 aunque esten publicadas las 37. El kit instala
las del AGP del proyecto; si no lo sabe, las del AGP estable, y si hicieran falta
otras, Gradle las baja solo, porque la licencia ya esta aceptada. Esa descarga sale
por Gradle, no por el kit, pero con el mismo proxy: `Start-AndroidApp` y
`android-shell.bat` se lo pasan en `GRADLE_OPTS`, y esta comprobado que eso llega al
proceso de Gradle que descarga.

## Doctor

`Doctor` tiene una seccion de Android: que paquetes hay, la licencia, el JDK,
`ANDROID_HOME`, la casilla del hipervisor, lo que dice el propio emulador de su
aceleracion (`emulator -accel-check`) y si cada telefono virtual conserva su imagen.
Con `-Fix` repara lo que es local: `ANDROID_HOME` y el `android-shell.bat`.

## Flutter y React Native

Los dos compilan para Android con este mismo SDK: basta con que `ANDROID_HOME` apunte
a el, y el emulador sirve igual. Lo que el kit **no** trae todavia es lo suyo propio:
el SDK de Flutter, o lo que pida un proyecto de React Native ademas de Node.

## Lo comprobado y lo que falta

Probado de punta a punta en un equipo con Windows 11 Home: una app en Java con
Gradle 9.9 y AGP 9.5.1, abierta en Android 14 y en Android 8; y un proyecto real de
2019 (AGP 3.4.2, Gradle 5.1.1, compileSdk 28, la support library) con el JDK 8, en
el mismo SDK, desde un kit recien copiado con `Start-AndroidApp` y nada mas.

Falta verlo en la red del trabajo; esta en los [pendientes](pendientes.md).
