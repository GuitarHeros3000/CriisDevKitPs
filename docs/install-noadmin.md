# Install-NoAdmin

Instalar software de terceros en modo portable, sin permisos de administrador.

> Parte de la documentacion de **CriisDevKit**. Vuelta al [README](../README.md).

## Install-NoAdmin

Instala software en tu perfil de usuario **sin permisos de administrador**, usando el
modo per-user que el propio instalador ya soporta. No modifica el instalador ni el
sistema, y no eleva privilegios: si un software necesita admin de verdad, lo dice y para.

### Uso

```powershell
.\bin\kit\Install-NoAdmin.bat -Path "C:\Descargas\app.msi"
```

### Que hace

1. Detecta el tipo de instalador (MSI / WiX Burn / Inno Setup / NSIS / desconocido).
2. Intenta la instalacion per-user nativa (sin admin).
3. Verifica **donde aterrizo de verdad**: primero lo que declara el propio instalador
   (para un MSI, el `MSI_LUA` del log de Windows Installer), y si no lo dice, la ruta
   donde quedaron los archivos. La rama del registro **no** decide: 7-Zip se instala
   per-user en `%LOCALAPPDATA%` y aun asi registra en HKLM.
4. Si no hay modo per-user, extrae los archivos a una carpeta portable en `..\Apps`.
5. Si necesita admin real (drivers, servicios, MSI per-machine), lo informa con honestidad.

### Te dice si de verdad se evito el admin

Que un instalador devuelva 0 **no significa** que se instalara sin admin. Significa
que termino bien, y eso incluye el caso en que ignoro `/CURRENTUSER`, pidio permiso
de administrador, se le concedio y se instalo para todos los usuarios.

Eso paso de verdad con el instalador de Git, y el kit anunciaba
`INSTALACION COMPLETADA (per-user)`, que era falso. Ahora se comparan **los dos**
registros y el resultado se dice tal cual es:

| Resultado | Codigo | Que significa |
|---|---|---|
| `INSTALACION COMPLETADA (per-user)` | 0 | entrada nueva en HKCU: se evito el admin |
| `SE INSTALO PARA TODA LA MAQUINA` | **2** | entrada nueva en HKLM: **hubo elevacion** |
| `AMBITO SIN CONFIRMAR` | 0 | sin rastro en ninguno; no se puede afirmar nada |

El codigo **2** existe para distinguir el caso intermedio: el instalador funciono,
pero el kit no cumplio su objetivo. Un `0` ahi seria mentir por omision.

Si te sale el aviso de administrador, **responde NO**: significa que ese instalador
ignora el modo por usuario. Luego prueba con `-ExtractOnly`, que lo saca a portable
sin instalar nada.

### Tipos reconocidos

| Tipo | Como se detecta | Modo per-user | Extraccion |
|---|---|---|---|
| MSI | extension `.msi` | `MSIINSTALLPERUSER=1 ALLUSERS=2` | `msiexec /a` |
| WiX Burn | seccion PE `.wixburn` | no existe uno estandar | `/layout` |
| Inno Setup | cadena `Inno Setup` en el binario | `/CURRENTUSER` | `innoextract` (o `innounp` si lo tienes) |
| NSIS | cadena `Nullsoft` en el binario | no fiable | `7z x` |

Las herramientas de extraccion no hace falta instalarlas: si faltan, el kit se las
consigue solo y las deja en `..\Apps\tools`. 7-Zip se saca de su MSI oficial con
`msiexec /a`, e `innoextract` de su zip.

Burn se detecta por su seccion PE, no por buscar la palabra "Burn" en el binario:
esa aparece por casualidad en casi cualquier ejecutable grande.

Un `/layout` de Burn deja los MSI sueltos, no una app portable lista para usar. Si
alguno de esos MSI instala drivers o servicios, seguira necesitando admin. Y cuando
el bundle lleva sus cargas **embebidas** -lo normal en un instalador de un solo
archivo- `/layout` responde 0 pero solo copia el propio instalador: el kit lo trata
como fallo en vez de anunciar una extraccion que no ha ocurrido.

**Inno Setup reciente no se puede extraer.** `innoextract` 1.9 es la ultima que
existe y solo cubre hasta Inno Setup 6.0.5; 7-Zip tampoco reconoce el formato.
Comprobado con el instalador de Git 2.55. Para esos, la via es la instalacion
per-user, que es lo que el kit intenta antes de extraer.

### Opciones

```powershell
-Path <ruta>       Ruta al instalador .msi o .exe (obligatorio)
-ExtractOnly       Omite la instalacion y extrae directamente a portable
-DestRoot <ruta>   Carpeta destino para el modo portable (por defecto ..\Apps)
```

### Las herramientas de extraccion se consiguen solas

El modo portable necesita un extractor. Si no lo tienes, **el kit lo descarga** y lo
deja en `..\Apps\tools`. Si ya tienes el tuyo en el PATH, se usa el tuyo.

| Tipo | Herramienta | De donde sale |
|---|---|---|
| NSIS | `7z.exe` | del MSI oficial de 7-zip.org, extraido con `msiexec /a` |
| Inno Setup | `innoextract.exe` | del zip oficial de constexpr.org |

La version de 7-Zip no esta cableada: se lee de su pagina de descargas y se coge la
mas alta, para que no caduque.

**Limitacion real de Inno Setup.** `innoextract 1.9` es la ultima que existe y solo
cubre hasta **Inno Setup 6.0.5**, asi que con un instalador reciente falla. Lo que si
funciona con esos es `innounp`, pero **no se puede descargar de forma automatica**:
solo se distribuye por SourceForge, que responde una pagina HTML intermedia en vez
del archivo. Si te topas con ese caso el kit te lo dice con todas las letras y te
propone la salida buena, que casi siempre es no extraer:

> casi todos los Inno Setup admiten instalacion per-user, que es lo que este script
> intenta **antes** de extraer. Prueba sin `-ExtractOnly`.

7-Zip tampoco sirve de recambio ahi: se probo con un instalador de Inno moderno y no
saca nada aprovechable.

### Notas

- Las instalaciones per-user aparecen en el menu Inicio y en `%LOCALAPPDATA%`.
- Solo se copian `7z.exe` y `7z.dll`, no la carpeta entera del MSI.
