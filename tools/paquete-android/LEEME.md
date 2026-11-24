# CriisDevKit - Android

Compila una app de Android (Java o Kotlin) y la abre en un telefono virtual, sin
permisos de administrador y sin Android Studio.

## Antes de empezar

1. **Descomprime esta carpeta fuera de OneDrive**, en una ruta corta. Por ejemplo:
   `C:\Users\<tu usuario>\Dev\CriisDevKit-Android`. Lo que instala va junto a esta
   carpeta (son unos 2 GB), y OneDrive intentaria subirlo.
2. **Comprueba que tu equipo puede con el emulador.** En PowerShell:

   ```powershell
   (Get-CimInstance Win32_OptionalFeature -Filter "Name='HypervisorPlatform'").InstallState
   ```

   Tiene que salir `1`. Si sale otra cosa, el telefono virtual no arrancara: hay que
   pedir a IT que active la "Plataforma del hipervisor de Windows". Compilar si se
   puede igual.

## Uso

Doble clic en **`Android.bat`**:

```
    1  Compilar y probar una app
    2  Abrir el telefono
    3  Ver el registro de la app
    4  Depurar la app en VS Code

    5  Quitar Android (y el Java que instalo)
```

**La primera vez**, opcion **1** y la carpeta del proyecto (la que tiene
`gradlew.bat`). Instala lo que ese proyecto necesite (el JDK, el SDK de Android, el
emulador y un telefono con Android 8), compila la app y la abre en el telefono. Pide
aceptar la licencia de Google: se escribe `SI`. Tarda unos minutos y descarga hasta
1,3 GB, mas lo que Gradle baje para el proyecto.

**Las siguientes veces**, opcion **1** e **Intro**: recuerda la carpeta, no instala
nada, compila y abre la version nueva en el telefono, que se queda abierto entre una
y otra. Cambiar el codigo, 1, Intro: menos de un minuto.

La opcion **2** abre solo el telefono. La **5** quita todo lo que se instalo.

## Ver lo que hace la app, y depurarla

**Opcion 3, el registro:** lo que escribe tu app (sus `Log.d`, `Log.e`... y sus
errores) en directo, en color y sin el resto de Android. La sigue aunque se cierre y
se vuelva a abrir. Ctrl+C para volver al menu.

**Opcion 4, VS Code:** compila, instala y abre la app **parada**, esperando al
depurador, y abre VS Code con el proyecto preparado para que lo **entienda**:
autocompleta las clases de Android y de tus librerias, y no marca en rojo lo que
compila bien. En VS Code:

1. Espera a que abajo diga **"Java: Ready"** (la primera vez, un poco mas).
2. Abre tus archivos desde la carpeta de tu proyecto; la otra, "clases para VS Code
   (kit)", es del kit.
3. Pon un punto de interrupcion: clic a la izquierda del numero de linea.
4. **F5**, con "Android: depurar la app (kit)".

La app sigue y se para en tu punto: ves las variables y avanzas paso a paso. Hace
falta la extension "Extension Pack for Java" de VS Code.

Lo que abre es un **espacio de trabajo** (`.code-workspace`) que el kit deja en
`Android\vscode`, junto a esta carpeta: **no escribe nada dentro de tu proyecto**. Si
VS Code no se abre solo: File > Open Workspace from File, y ese archivo. Si anades una
libreria al proyecto, vuelve a pasar por la opcion 4 para que VS Code la conozca. Lo
que no da es el disenador de pantallas (layouts): eso sigue siendo de Android Studio.

## El telefono

- Recuerda lo que instalas y sus datos, como uno de verdad. Para cerrarlo, la **X**
  de su ventana: guarda donde se quedo y la siguiente vez arranca en segundos.
- Junto al telefono se abre una **ventana negra** con su registro. Los avisos que
  salen ahi son normales (ver "Los avisos de la ventana negra", abajo). **No la cierres**: cierra
  el telefono de golpe, sin guardar.
- Abajo tiene los botones de Android: inicio, recientes y atras.
- **Si no lo tocas, la pantalla se apaga**, como en un telefono. El boton de encendido
  (el primero de la barra lateral) la vuelve a encender.
- Si al arrancar sale un aviso **"Detected ADB"**, dale a **OK**: el paquete usa su
  propio adb y no le afecta.

## Los avisos de la ventana negra

Ninguno es un error; el telefono arranca igual.

| Aviso | Que es |
|---|---|
| `unsupported Vulkan API level` | El driver de graficos del equipo es antiguo para lo que pide el emulador, y dibuja con el procesador. Funciona, algo mas lento. Lo arreglaria actualizar el driver (IT). |
| `Failed to load snapshot 'default_boot'` y `does not have the requested snapshot` | Es la primera vez: todavia no hay donde se quedo. Si lo cierras con la X, la siguiente arranca en segundos y no sale. |
| `Failed to process .ini file` | Un archivo de ajustes que aun no existe; se crea solo. |
| `Failed to load opengl32sw` | Busca una pieza de graficos que no trae, y usa la de Windows. |
| `Host EGL config ... was not added` | Lista formatos de imagen de la tarjeta grafica que no usa. |
| `FeatureControl is requesting a non existing feature`, `gRPC`, `IPv6` | Mensajes internos del emulador. |

## Donde queda cada cosa

| | |
|---|---|
| SDK de Android y emulador | `Android\`, junto a esta carpeta |
| El JDK que pide el proyecto | `Java\`, junto a esta carpeta |
| Los telefonos virtuales | `%LOCALAPPDATA%\CriisDevKit\android-avd` |
| La version de Gradle del proyecto | `%USERPROFILE%\.gradle` (la baja el propio proyecto) |

Tus programas de siempre no cambian: si ya tienes Java instalado, `java` sigue
siendo el tuyo.

## Si algo falla

- **"PKIX path building failed" o "certificado de la empresa":** la red abre el HTTPS
  con un certificado propio que el Java del proyecto no conoce. El paquete lo busca, lo
  pone y vuelve a compilar solo. Si no lo encuentra, o sigue fallando, pide a IT el
  certificado **raiz** de la empresa (un `.cer`; el de un sitio no sirve) y, en una
  consola en esta carpeta:

  ```
  bin\start\Start-AndroidApp.bat -Path C:\ruta\del\proyecto -Certificado C:\ruta\empresa.cer
  ```

- **No descarga en la red de la empresa:** si el proxy pide usuario y clave, abre una
  consola (cmd) en esta carpeta y antes de `Android.bat` escribe:

  ```
  set HTTPS_PROXY=http://usuario:clave@proxy.empresa:8080
  ```

- **Windows pregunta por el firewall:** no deberia pasar. Si pasa, dale a Cancelar y
  avisa de que programa era.
- **Cualquier otra cosa:** copia el mensaje en rojo y mandaselo a quien te paso este
  paquete.
