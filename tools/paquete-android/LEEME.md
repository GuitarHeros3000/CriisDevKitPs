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
    3  Quitar Android (y el Java que instalo)
```

**La primera vez**, opcion **1** y la carpeta del proyecto (la que tiene
`gradlew.bat`). Instala lo que ese proyecto necesite (el JDK, el SDK de Android, el
emulador y un telefono con Android 8), compila la app y la abre en el telefono. Pide
aceptar la licencia de Google: se escribe `SI`. Tarda unos minutos y descarga hasta
1,3 GB, mas lo que Gradle baje para el proyecto.

**Las siguientes veces**, opcion **1** e **Intro**: recuerda la carpeta, no instala
nada, compila y abre la version nueva en el telefono, que se queda abierto entre una
y otra. Cambiar el codigo, 1, Intro: menos de un minuto.

La opcion **2** abre solo el telefono. La **3** quita todo lo que se instalo.

## El telefono

- Recuerda lo que instalas y sus datos, como uno de verdad. Para cerrarlo, la **X**
  de su ventana: guarda donde se quedo y la siguiente vez arranca en segundos.
- Junto al telefono se abre una **ventana negra** con su registro. Los avisos que
  salen ahi (snapshot, opengl32sw, gRPC...) son normales. **No la cierres**: cierra
  el telefono de golpe, sin guardar.
- Abajo tiene los botones de Android: inicio, recientes y atras.

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

- **No descarga en la red de la empresa:** si el proxy pide usuario y clave, abre una
  consola (cmd) en esta carpeta y antes de `Android.bat` escribe:

  ```
  set HTTPS_PROXY=http://usuario:clave@proxy.empresa:8080
  ```

- **Windows pregunta por el firewall:** no deberia pasar. Si pasa, dale a Cancelar y
  avisa de que programa era.
- **Cualquier otra cosa:** copia el mensaje en rojo y mandaselo a quien te paso este
  paquete.
