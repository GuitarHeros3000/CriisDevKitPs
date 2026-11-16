# Runtime de Visual C++

Las DLL que pide un programa ajeno, junto a el y sin permisos de administrador.
Cubre Visual C++ **2012**, **2013** y **2015-2022**.

> Parte de la documentacion de **CriisDevKit**. Vuelta al [README](../README.md).

## El problema

Un programa hecho en C++ con Visual Studio no arranca en un equipo que no tenga su
runtime, y Windows lo dice asi:

```
No se puede iniciar el programa porque falta mfc110.dll en el equipo.
```

La solucion oficial es instalar el *Microsoft Visual C++ Redistributable*, que pide
administrador. Este comando es la otra salida, la que no lo pide.

## Antes: por que no arranca

```powershell
.\bin\kit\Doctor-App.bat -Path "C:\SYS\BR\UTILERIAPUENTEBR.EXE"
.\bin\kit\Doctor-App.bat -Path "C:\SYS\BR"                      Cada .exe de la carpeta
```

Windows solo nombra **la primera** DLL que no encuentra. Se copia esa, y sale la
siguiente; y si la copiada era de la arquitectura equivocada, sale un `0xc000007b` que
ya no nombra nada. `Doctor-App` lee el `.exe` sin ejecutarlo, sigue la cadena (lo que
pide el programa y lo que piden sus DLL) buscando cada una donde la buscaria Windows,
y dice **todo lo que falta de una vez**, y de donde sale cada cosa:

```
  [X]  mfc110.dll                   FALTA
         -> Es de Visual C++ 2012. Sin admin:  .\bin\kit\Install-VCRuntime.bat -App "..."
  [X]  PROPIA.dll                   OTRA ARQUITECTURA
         -> La que encuentra es de x64 y el programa es de x86: no la puede cargar (0xc000007b).
  [X]  msvcr110d.dll                FALTA
         -> Es de DEPURACION de Visual C++: el programa se compilo en Debug. [...]
  [!]  opcional.dll                 FALTA (la carga mas tarde)
```

- Busca en el orden de Windows: la carpeta del programa, la de sistema **de su
  arquitectura** (`SysWOW64` para uno de 32 bits), la de Windows y el `PATH`.
- Lo que vive dentro de la carpeta de Windows no se recorre: son las de Windows.
- Las `api-ms-win-*` no son archivos sino nombres que Windows 10 y 11 resuelven por
  dentro, y no se buscan.
- Las de **carga diferida** que faltan salen como aviso (`[!]`), no como fallo: no
  impiden arrancar. VS Code, por ejemplo, tiene una que encuentra el solo al arrancar.
- Un programa .NET lo dice: lo que necesita es el runtime de .NET, no DLL sueltas.
- Solo lee. Sale con 1 si a algun programa le falta algo para arrancar.

Tambien desde el menu, opcion **52**.

## Uso

```powershell
.\bin\kit\Install-VCRuntime.bat -App "C:\SYS\BR\UTILERIAPUENTEBR.EXE"
```

```
  Programa: C:\SYS\BR\UTILERIAPUENTEBR.EXE
    Es de 32 bits (x86)
    Pide: Visual C++ 2012

  --- Visual C++ 2012 ---
  Visual C++ 2012 x86 extraido en ...\VCRuntime\vc-2012\x86
  Necesita 2: mfc110.dll, msvcr110.dll

    copiada            mfc110.dll
    copiada            msvcr110.dll

  Listo: el programa ya encuentra Visual C++ 2012 en su carpeta, sin instalar nada.
```

No hace falta saber que version pide: **la lee del propio `.exe`**, igual que la
lista de DLL. Si el programa importa tambien `msvcp110.dll`, aparece ahi; si no, no
se copia. Si pide dos versiones a la vez (un `.exe` de 2015 que carga una DLL de
2012), se ocupa de las dos.

Tambien desde el menu, opcion **51**. La ruta se puede pegar con comillas, como la
deja "Copiar como ruta" del Explorador. Otras formas:

```powershell
.\bin\kit\Install-VCRuntime.bat -Version 2015-2022            Solo descargar y extraer (x86 y x64)
.\bin\kit\Install-VCRuntime.bat -Version 2013 -Arch x86       Solo una arquitectura
.\bin\kit\Install-VCRuntime.bat -App <exe> -Version 2012      Forzar una version
.\bin\kit\Install-VCRuntime.bat -App <exe> -Force             Sustituir lo que haya junto al programa
```

**Sin `-App` no se copia nada junto a ningun programa**, solo se descargan las DLL, y
el comando lo dice en amarillo al terminar. Antes acababa todo en verde y parecia que
el programa ya estaba servido.

`-Version` admite `2012`, `2013` y `2015-2022`. `2015`, `2017`, `2019` y `2022` son el
mismo: desde 2015 Microsoft mantiene **un solo runtime** compatible hacia atras.

## Que hace

**1. Saca las DLL del redistribuible oficial sin ejecutarlo.** Lo descarga de
Microsoft (URL y SHA-256 fijados), lo abre como bundle WiX Burn, comprueba cada pieza
contra el hash que declara el propio bundle y lee sus MSI como bases de datos. Quedan
en `..\VCRuntime\vc-<version>\<arquitectura>`, y antes de darlas por buenas se
comprueba que **todas llevan firma valida de Microsoft**.

No se usa el instalador, ni `msiexec`, ni nada que se ejecute: por eso funciona
aunque una directiva de empresa bloquee los instaladores.

**2. Con `-App`, copia junto al programa exactamente lo que pide.** Lee el `.exe`
para saber de cuantos bits es y que DLL importa, y sigue la cadena: un programa MFC
importa `mfc110.dll`, pero `mfc110.dll` importa a su vez `msvcr110.dll`, y copiar solo
la primera da el mismo error con otro nombre. `msvcp110.dll` solo se copia si alguien
la pide.

## El paquete de ARM dentro del de x64

El redistribuible **x64** de 2015-2022 no trae solo DLL de x64: lleva un tercer MSI
para Windows en ARM, con los **mismos nombres** (`vcruntime140.dll`, `msvcp140.dll`...)
en ARM64. Sacandolos todos a la misma carpeta, las de ARM pisaban a las buenas, y un
programa de 64 bits habria fallado con `0xc000007b`.

Por eso cada MSI se extrae aparte, y **solo se usa uno si todas sus DLL son de la
arquitectura pedida**. No se rescatan DLL sueltas: el de ARM lleva tambien tres de x64,
que son las de la emulacion en ARM y no las del runtime de x64.

```
  vc_runtimeAdditional_x64.msi: 14 DLL de x64
  vc_runtimeMinimum_x64.msi: 12 DLL de x64
  VC_Runtime_arm64.msi: es de arm64 y x64, no se usa
```

## Por que junto al programa

La carpeta del programa es **el primer sitio donde Windows busca sus DLL**, antes que
System32. Desde Visual C++ 2010 el runtime ya no pasa por WinSxS, y Microsoft admite
este despliegue "local" sin manifiestos ni registro. No se toca el sistema, el PATH
ni el registro.

## La trampa de System32

La receta que circula para esto es "copia las DLL de `C:\Windows\System32` de un
equipo que funcione". En un Windows de 64 bits **eso da las de 64 bits**: las de 32
estan en `C:\Windows\SysWOW64`, al reves de lo que sugieren los nombres. Un programa
de 32 bits no puede cargarlas, y el error claro de antes se convierte en un
`0xc000007b` que no explica nada.

El kit no pregunta la arquitectura: **la lee del programa**, que es la que manda (no
la del equipo). Y si ya hay junto al programa una DLL de la arquitectura equivocada,
lo dice con todas las letras.

## Que no pisa

Sin `-Force` no se sustituye nada de lo que ya este junto al programa:

| Estado | Que significa |
|---|---|
| `copiada` | no estaba y se ha puesto |
| `ya estaba` | habia una identica a la del kit |
| `otra arquitectura` | habia una que este programa **no puede cargar** (la trampa de System32) |
| `distinta` | habia otra version de la misma arquitectura |
| `reemplazada` | habia otra y `-Force` la ha sustituido |
| `sin permiso` | no se puede escribir en la carpeta del programa |

Una DLL `distinta` no se toca porque puede ser de **otro programa de la misma
carpeta**: quitarla arreglaria uno y romperia el otro.

Si la carpeta del programa pide admin (`C:\Program Files\...`), dejar ahi las DLL
tampoco es posible. La salida sin admin es copiar el programa a una carpeta tuya y
repetir con esa ruta.

Si Windows ya encuentra todas las DLL en el sistema, el comando lo dice y no copia
nada: el programa no deberia fallar por esto, y si falla, la causa es otra. Con
`-Force` se copian igualmente.

## Si pide una version que el kit no trae

```
  El programa no importa ninguna DLL de Visual C++ que el kit conozca (2012, 2013, 2015-2022).
    Pide MSVCR100.dll, de una version que el kit no trae.
```

`MSVCR100.dll` es Visual C++ 2010, que no esta en el catalogo. Si no aparece ninguna
DLL de Visual C++, el programa puede cargarlas en marcha (`LoadLibrary`), y eso no se
ve leyendo el `.exe`: indica la version con `-Version`, o copia la que Windows diga
que falta desde `..\VCRuntime\vc-<version>\<arquitectura>`.

## Lo que hay que saber

- **Tres versiones**: 2012, 2013 y 2015-2022. Cada una es una entrada en
  `Get-VCRuntimeCatalog` (`lib\VCRuntime.ps1`): anadir otra es anadir su URL y su hash.
  Las URL son las de destino de los enlaces `aka.ms` de Microsoft, no los enlaces: un
  `aka.ms` cambia de archivo con cada build y el hash fijado dejaria de cuadrar.
- **2015-2022 es la build 14.44.35211.** Sirve a un programa hecho con cualquier
  Visual Studio de 2015 en adelante **siempre que no sea mas nuevo que esa build**. Uno
  compilado con una herramienta posterior puede pedir una funcion que esta no tiene, y
  Windows lo dice como "no se encontro el punto de entrada". Se actualiza a mano.
- **Lo de 2015-2022 necesita el CRT universal** (`api-ms-win-crt-*.dll`), que viene
  con Windows 10 y 11. En Windows 7 u 8.1 no esta, y se instala aparte con admin.
- **No recibe parches de Windows Update.** Las DLL junto al programa son una copia
  fija. 2012 y 2013 ya no tienen soporte de Microsoft, asi que tampoco habra parches
  que perderse.
- **Los idiomas de MFC no se copian** (`mfc110esn.dll` y compania). MFC funciona sin
  ellos y usa sus textos en ingles para los pocos mensajes propios que muestra. Si los
  quieres, estan en la carpeta del kit.
- **Sin internet**: `Export-Env` lo mete en el bundle con el SHA-256 de cada DLL, e
  `Import-Env` lo deja en el otro equipo tras comprobarlas. Solo esto:
  `.\bin\env\Export-Env.bat -Runtime VCRuntime`. Si ya esta, no se descarga nada.
- **Comprobarlo**: `.\bin\env\Verify-Env.bat -Runtime VCRuntime` mira que todas las DLL
  sigan firmadas por Microsoft y sean de la arquitectura de su carpeta.
- **Para quitarlo**: `.\bin\env\Uninstall-Env.bat -Runtime VCRuntime -Version 2012`
  quita la copia del kit. Las DLL que se copiaron junto a un programa **no** se tocan:
  ese programa sigue funcionando. Si tambien quieres quitar esas, borralas a mano.
- `Doctor` dice, para cada version y para 32 y 64 bits, si Windows ya encuentra el
  runtime en el sistema y si el kit guarda una copia.
