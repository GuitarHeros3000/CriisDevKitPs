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

La opcion **61** abre solo el telefono, sin compilar nada.

Desde una consola es lo mismo:

```powershell
.\bin\start\Start-AndroidApp.bat -Path C:\ruta\del\proyecto
.\bin\start\Start-AndroidApp.bat                      El de la ultima vez
.\bin\start\Start-AndroidApp.bat -Api 30              En un telefono con Android 11
.\bin\start\Start-AndroidApp.bat -SoloCompilar        Sin el telefono
```

El telefono es Android 8 (API 26) salvo que la app pida uno mas alto (su `minSdk`):
entonces, ese.

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
PATH).

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
