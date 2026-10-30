# Runtime de Visual C++

Las DLL que pide un programa ajeno, junto a el y sin permisos de administrador.

> Parte de la documentacion de **CriisDevKit**. Vuelta al [README](../README.md).

## El problema

Un programa hecho en C++ con Visual Studio 2012 no arranca en un equipo que no tenga
su runtime, y Windows lo dice asi:

```
No se puede iniciar el programa porque falta mfc110.dll en el equipo.
```

La solucion oficial es instalar el *Microsoft Visual C++ Redistributable*, que pide
administrador. Este comando es la otra salida, la que no lo pide.

## Uso

```powershell
.\bin\kit\Install-VCRuntime.bat -App "C:\SYS\BR\UTILERIAPUENTEBR.EXE"
```

```
  Programa: C:\SYS\BR\UTILERIAPUENTEBR.EXE
    Es de 32 bits (x86)
  Visual C++ 2012 x86 extraido en ...\VCRuntime\vc-2012\x86
  Necesita 2: mfc110.dll, msvcr110.dll

    copiada            mfc110.dll
    copiada            msvcr110.dll

  Listo: C:\SYS\BR\UTILERIAPUENTEBR.EXE ya encuentra Visual C++ 2012 en su carpeta,
  sin instalar nada.
```

La lista de lo que necesita sale del propio `.exe`, no de una receta: si el programa
importa tambien `msvcp110.dll`, aparece ahi; si no, no se copia.

Tambien desde el menu, opcion **51**. Otras formas:

```powershell
.\bin\kit\Install-VCRuntime.bat                     Solo descargar y extraer (x86 y x64)
.\bin\kit\Install-VCRuntime.bat -Arch x86           Solo una arquitectura
.\bin\kit\Install-VCRuntime.bat -App <exe> -Force   Sustituir lo que haya junto al programa
```

## Que hace

**1. Saca las DLL del redistribuible oficial sin ejecutarlo.** Lo descarga de
Microsoft (URL y SHA-256 fijados), lo abre como bundle WiX Burn, comprueba cada pieza
contra el hash que declara el propio bundle y lee sus MSI como bases de datos. Quedan
en `..\VCRuntime\vc-2012\<arquitectura>`, y antes de darlas por buenas se comprueba
que **las 20 llevan firma valida de Microsoft**.

No se usa el instalador, ni `msiexec`, ni nada que se ejecute: por eso funciona
aunque una directiva de empresa bloquee los instaladores.

**2. Con `-App`, copia junto al programa exactamente lo que pide.** Lee el `.exe`
para saber de cuantos bits es y que DLL importa, y sigue la cadena: un programa MFC
importa `mfc110.dll`, pero `mfc110.dll` importa a su vez `msvcr110.dll`, y copiar solo
la primera da el mismo error con otro nombre. `msvcp110.dll` solo se copia si alguien
la pide.

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

## Si no pide nada de 2012

```
  El programa no importa ninguna DLL de Visual C++ 2012.
    Pide las de OTRA version de Visual C++: MSVCR100.dll
```

Eso es Visual C++ 2010, y lo que le falta no es este runtime. Si no aparece ninguna
otra version, el programa puede cargar sus DLL en marcha (`LoadLibrary`), y eso no se
ve leyendo el `.exe`: copia la que Windows diga que falta desde
`..\VCRuntime\vc-2012\<arquitectura>`.

## Lo que hay que saber

- **Solo Visual C++ 2012** por ahora. Cada version es una entrada en
  `Get-VCRuntimeCatalog` (`lib\VCRuntime.ps1`): anadir otra es anadir su URL y su hash.
- **No recibe parches de Windows Update.** Las DLL junto al programa son una copia
  fija. La version 2012 ya no tiene soporte de Microsoft desde enero de 2023, asi que
  tampoco habra parches que perderse; la que trae el kit es la ultima (Update 4,
  11.0.61030).
- **Los idiomas de MFC no se copian** (`mfc110esn.dll` y compania). MFC funciona sin
  ellos y usa sus textos en ingles para los pocos mensajes propios que muestra. Si los
  quieres, estan en la carpeta del kit.
- **Sin internet**: extrae en un equipo que tenga (`Install-VCRuntime.bat` sin `-App`)
  y lleva la carpeta `VCRuntime\` al otro, al lado del kit. Si ya esta, no se descarga
  nada.
- **Para quitarlo**: borra las DLL que el comando dijo haber copiado junto al programa,
  y la carpeta `..\VCRuntime`. No hay nada mas que deshacer.
- `Doctor` dice, para 32 y para 64 bits, si Windows ya encuentra el runtime en el
  sistema y si el kit guarda una copia.
