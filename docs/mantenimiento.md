# Mantener el entorno

Diagnosticar, verificar, actualizar, desinstalar y saber que version responde.

> Parte de la documentacion de **CriisDevKit**. Vuelta al [README](../README.md).

## Registro de ejecuciones

Cada ejecucion deja un archivo en `%LOCALAPPDATA%\CriisDevKit\logs`, con el
nombre del comando y la hora:

```
Setup-PythonEnv-20260807-153529.log
Doctor-Env-20260807-154551.log
```

Se conservan los **20 ultimos**. `Doctor` te dice cuantos hay y cual es el de esa
ejecucion, para que puedas adjuntarlo a un ticket sin buscarlo.

### Para que sirve

El kit falla en la maquina de **otra persona**, no en la tuya: es un portatil
corporativo con otro proxy, otras politicas y otra red. Sin registro, lo unico que
podias pedirle era una captura de pantalla, y solo de lo que aun se viera.

| Sin registro | Con registro |
|---|---|
| "me sale un error" + captura recortada | el archivo entero, con horas |
| la ventana se cerro y no hay nada | queda en disco |
| no se sabe que version de Windows ni de PowerShell | van en la cabecera |
| hay que reproducirlo para verlo | ya esta reproducido |

Tambien captura lo que se te fue de la pantalla al hacer scroll, y el orden exacto
en que pasaron las cosas.

### Como esta hecho

Se usa `Start-Transcript`, no un `append` dentro de `Write-Log`. El motivo es
concreto: `Doctor` imprime casi todo con `Write-Host` (39 llamadas frente a 3 de
`Write-Log`), asi que enganchar solo `Write-Log` habria dejado el registro **vacio
justo en el caso que mas importa**. El transcript captura toda la salida de consola
sin tocar ninguna de las ~300 llamadas del kit.

Reglas que cumple:

- **Nunca rompe nada.** Disco lleno, permisos, un transcript ya abierto: se ignora
  y la herramienta sigue.
- **Silencioso.** El "Transcript started" iria a parar a la salida que leen otros
  procesos.
- **La clave del proxy no acaba ahi**, ni siquiera dentro de un mensaje de .NET.
- Se desactiva con `CRIISDEVKIT_NOLOG`.

## Que hay para actualizar

```powershell
.\bin\env\Update-Env.bat                 Todo lo instalado
.\bin\env\Update-Env.bat -Runtime Java   Solo uno
```

```
  Runtime               Instalado       Disponible
  Python 3.12           3.12.10         3.12.10         al dia
  Java 21               jdk-21.0.12+8   jdk-21.0.12+8   al dia
  Node 22 (suelto)      22.14.0         22.23.2         actualizable
  Angular CLI 20        20.3.33         20.3.33         al dia
  Node 22 (de Angular)  22.23.2         22.23.2         al dia

Para actualizar:
  Node 22 (suelto)   .\bin\setup\Setup-NodeEnv.bat -NodeVersion 22.23.2 -Force
```

**Sin `-Apply` no instala nada**, igual que `Doctor` sin `-Fix`: solo lee y te da el
comando exacto. Sale con codigo **1 si hay algo que actualizar**, para poder
encadenarlo.

Distingue la Node suelta de la que Angular instala para si mismo, porque son
instalaciones independientes: la de Angular la elige su CLI y no se toca a mano.

### -Apply: aplicarlas

```powershell
.\bin\env\Update-Env.bat -Apply                 Pide confirmacion
.\bin\env\Update-Env.bat -Runtime Node -Apply   Solo uno
.\bin\env\Update-Env.bat -Apply -Force          Sin preguntar
```

Ejecuta **exactamente los mismos comandos** que imprime sin el parametro, uno detras
de otro. No hay una segunda implementacion de "actualizar" que pueda desviarse de lo
que se anuncia: la cadena que se imprime y la que se ejecuta son la misma, y hay una
prueba que lo comprueba.

Tres decisiones que se notan cuando algo va mal:

- **El aviso de pip sale antes de confirmar, y nombra las versiones afectadas.**
  Actualizar implica `-Force`, que reinstala desde cero, y en Python eso borra sus
  paquetes. Enterrado al final de la lista no lo leia nadie, y eso no tiene vuelta
  atras. Antes: `pip freeze > requirements.txt`.
- **Si un comando no se resuelve, no se aplica nada.** Ni siquiera los que si. Dejar
  una tanda a medias deja el entorno en un estado que nadie pidio y que no se ve.
- **Pero si uno FALLA al ejecutarse, se sigue con el resto.** Que no se pueda bajar
  el JDK no es razon para no actualizar Maven. Se apuntan y se listan al final.

Termina diciendo como comprobar que quedo bien: `.\bin\env\Verify-Env.bat`.

## Diagnostico

```powershell
.\bin\kit\Doctor-Env.bat              Diagnostico completo (solo lee, no toca nada)
.\bin\kit\Doctor-Env.bat -SkipNetwork Sin pruebas de conectividad
.\bin\kit\Doctor-Env.bat -Fix         Repara lo que se pueda arreglar en local
.\bin\kit\Doctor-Env.bat -Report      Ademas, guarda un informe para adjuntar a un ticket
```

### -Report

Guarda el diagnostico en un markdown listo para mandar a IT, con el equipo, el
usuario, la build de Windows, la version de PowerShell y la del kit:

```powershell
.\bin\kit\Doctor-Env.bat -Report                              a %LOCALAPPDATA%\CriisDevKit\informes
.\bin\kit\Doctor-Env.bat -Report -ReportPath D:\ticket.md     a donde tu digas
```

**La clave del proxy va enmascarada** (`usuario:***@servidor`), asi que el archivo se
puede adjuntar tal cual. Se escribe **antes** de las reparaciones a proposito: si lo
generas junto con `-Fix`, lo util para el ticket es lo que fallaba, no como quedo
despues.

### -Json

Lo mismo, pero para que lo lea una maquina: comprobar el entorno en un pipeline, o
juntar los informes de varios equipos y ver que tienen en comun. `-Report` es para
que lo lea una persona; esto, para que no.

```powershell
.\bin\kit\Doctor-Env.bat -Json                            a %LOCALAPPDATA%\CriisDevKit\informes
.\bin\kit\Doctor-Env.bat -Json -JsonPath D:\equipo.json   a donde tu digas
```

```json
{
  "version_formato": 1,
  "kit":      { "version": "2.1.0", "raiz": "...", "workspace": "..." },
  "maquina":  { "equipo": "PC-1234", "usuario": "jperez", "windows": "10.0.26200.0" },
  "resumen":  { "problemas": 0, "avisos": 3 },
  "secciones": [
    { "titulo": "Java",
      "comprobaciones": [
        { "etiqueta": "JAVA_HOME vs java", "valor": "descuadrados: 1.8.0_202 frente a 24.0.2",
          "estado": "warn",
          "detalles": ["'java' en consola responde 24.0.2, pero Maven, Gradle y los IDE",
                       "leen JAVA_HOME: compilarian con Java 8."] } ] } ],
  "reparaciones": []
}
```

Cada detalle **cuelga de su comprobacion**, que es la diferencia con el markdown:
alli son lineas sangradas y hay que adivinar a cual se referian.

El codigo de salida sigue siendo **1 si hay algo grave**, asi que en un pipeline se
puede fallar por el codigo y mirar el JSON solo cuando falla, sin parsear nada en el
caso normal. `reparaciones` dice, ademas, cuales de esos problemas tienen arreglo
automatico con `-Fix`.

Se escribe **sin BOM**, al reves que el resto de los JSON del kit. Los otros se los
lee el propio kit y `ConvertFrom-Json` se traga el BOM; este lo va a abrir `jq` o
Python, donde tres bytes invisibles al principio son un error de sintaxis que no
explica de que va.

### -Fix

Sin `-Fix`, `Doctor` **no modifica nada**. Con `-Fix` repara solo lo que se puede
arreglar sin descargar, y pide confirmacion antes:

| Se repara | |
|---|---|
| Shells que faltan | `shell-vN.bat`, `pyXYZ-shell.bat`, `javaN-shell.bat` |
| `._pth` sin parchear | Python embeddable donde pip no importaria |
| `JAVA_HOME` roto | Apuntando a una carpeta que ya no existe |
| PATH duplicado | Entradas repetidas |
| PATH con rutas muertas | **Solo las que cuelgan de las carpetas del kit** |

Lo que necesita reinstalar (un `node.exe` corrupto, un `ng.cmd` que falta) no se
toca: se te dice que reejecutes el setup correspondiente.

**Las rutas muertas ajenas nunca se borran.** Una ruta que hoy no existe puede ser
una unidad de red o un USB desconectado en este momento; borrarla seria destruir
algo que si quieres. `Doctor` las lista marcadas como *(ajena: no se toca)*.

Es lo primero que conviene ejecutar cuando algo falla, o al llegar a un equipo nuevo.
No modifica nada: solo lee. Comprueba integridad del kit, sistema y espacio libre,
proxy y conectividad real a los cuatro dominios de los que depende todo, versiones de
Angular/Node/Python instaladas (incluido si el `._pth` esta parcheado y si pip responde),
herramientas de `Install-NoAdmin`, y salud del PATH (duplicados, rutas muertas, longitud).

Sale con codigo 1 si encuentra algun problema grave, para poder encadenarlo en scripts.

Todos los `.bat` propagan el codigo de salida de su `.ps1`. Como ademas terminan en
un `pause` (para que la ventana no se cierre al hacer doble clic), define
`CRIISDEVKIT_NOPAUSE` cuando los invoques desde otro script y no esperaran tecla:

```powershell
$env:CRIISDEVKIT_NOPAUSE = "1"
.\bin\kit\Doctor-Env.bat -SkipNetwork
if ($LASTEXITCODE -ne 0) { "revisa el entorno antes de seguir" }
```

## Verificar lo instalado

`Doctor` mira la maquina entera y por encima. `Verify-Env` mira **un runtime y mas
hondo**: si su firma sigue siendo la de siempre, si la instalacion esta completa, si
lo que hay dentro es de la version que dice la carpeta, y si el shell y el PATH
siguen en su sitio.

```powershell
.\bin\env\Verify-Env.bat                          todo lo instalado
.\bin\env\Verify-Env.bat -Runtime Java            solo Java
.\bin\env\Verify-Env.bat -Runtime Java -Version 21 solo esa linea
```

```
  Java 21
  ...\Java\jdk-21
[ok]  version                 21.0.12.1+1
[ok]  firma                   Eclipse Foundation
      sha-256 al instalar     no consta
        Se verifico al descargar, pero no se guardo: no hay contra que comparar.
[ok]  shell                   java21-shell.bat
[ok]  PATH de usuario         1 entrada(s)
```

Es de solo lectura: no descarga, no repara y no toca nada. Cuando encuentra algo,
dice con que comando se arregla. Sale con **1 si hay algo grave**, para encadenarlo.

### Lo que NO puede comprobar

**El SHA-256 de los archivos instalados.** Los `Setup-*` verifican el checksum al
descargar y despues **borran el archivo**, asi que no queda contra que comparar. La
unica excepcion es Python, que si anota el suyo.

Por eso se dice `no consta` en vez de callarlo: dar a entender una garantia que no
existe es peor que no darla.

Lo que si detecta un binario **cambiado despues de instalar** es la firma
Authenticode, y esa si se comprueba. Es la diferencia entre "este archivo es el que
descargue" (que ya no se puede saber) y "este archivo lo sigue firmando quien tiene
que firmarlo" (que si).

## JAVA_HOME: el descuadre que no se ve

`java` en consola lo decide el **PATH**. Pero Maven, Gradle y los IDE leen
**`JAVA_HOME`**, que es otra variable. Cuando las dos apuntan a JDK distintos,
compilas con uno creyendo que usas el otro, y nada te lo dice.

`Doctor` compara las dos y avisa. Caso real de un equipo de pruebas: `java`
respondia **24.0.2** y `JAVA_HOME` apuntaba a un **`jdk1.8.0_202` de 2019**, asi
que todo se compilaba contra Java 8.

Alinearlo **no necesita admin**: el `JAVA_HOME` de usuario le gana al de maquina
(comprobado). Lo hace `.\bin\setup\Setup-JavaEnv.bat -SetJavaHome`.

> Cambia con que JDK compilan **todos** tus proyectos. Si algo corporativo
> depende de un Java antiguo, se entera.

## Desinstalacion

```powershell
.\bin\env\Uninstall-Env.bat -Runtime Python                            Lista lo instalado
.\bin\env\Uninstall-Env.bat -Runtime Python -Version 3.12 -WhatIf      Muestra el plan
.\bin\env\Uninstall-Env.bat -Runtime Python -Version 3.12              Retira esa version
.\bin\env\Uninstall-Env.bat -Runtime Angular -Version 20 -Node 22.23.2 Angular y su Node
.\bin\env\Uninstall-Env.bat -Runtime Angular -All                      Todo el runtime
.\bin\env\Uninstall-Env.bat -Everything                                TODO, de todos
```

`-Everything` recorre el catalogo de runtimes, asi que uno nuevo queda cubierto por
estar en el catalogo y no por acordarse de tocar este comando. Sustituye a ejecutarlo
nueve veces para dejar limpia una maquina.

> Nunca toca la carpeta madre del workspace, la que contiene el kit y tus proyectos.
> Con `-Everything` esa era la ruta que quedaba en la variable de "retirar la carpeta
> si queda vacia", asi que hay una guarda explicita y una prueba de que ninguna
> entrada del catalogo puede componerla.

Retira la carpeta **y** limpia las entradas del PATH que apuntaban ahi. Sin esto,
borrar la carpeta a mano dejaba rutas muertas en el PATH del usuario para siempre.

- Pide confirmacion salvo con `-Force`, y `-WhatIf` no toca nada.
- Solo reconoce lo que el propio kit creo (`angular-vN`, `node-vX-win-x64`,
  `python-X.Y`, `npm-cache`). Cualquier otra carpeta que hubiera ahi se ignora.
- Nunca toca el PATH de maquina ni instalaciones ajenas al kit.
- Limpia el PATH **antes** de borrar carpetas: si algo falla, es preferible un PATH
  correcto con una carpeta de sobra que al reves.
- Guarda copia del PATH previo en `%LOCALAPPDATA%\CriisDevKit\path-backups\`.

## Que version responde cuando hay varias

**Usa siempre los shells generados.** Es la unica forma fiable, y aqui esta el porque.

### Limitacion: el kit no puede ganarle al PATH de maquina

Windows construye el PATH de un proceso nuevo asi:

```
PATH del proceso  =  PATH de MAQUINA  +  PATH de USUARIO
                     (HKLM, necesita admin)  (HKCU, es donde escribe el kit)
```

El bloque de maquina va **antes**. Si ya tienes algo instalado ahi (por ejemplo
`C:\Program Files\nodejs`), ese gana siempre, por mucho que el kit ponga su version
la primera dentro del bloque de usuario. Y el kit **no puede** tocar el PATH de
maquina: haria falta admin, que es justo lo que este proyecto evita.

Ejemplo real con Node 24 instalado por el kit y Node 22 en Program Files:

| | `node` | `ng` |
|---|---|---|
| Dentro de `shell-v22.bat` | **24.19.0** | **22.1.2** |
| Terminal normal | 22.18.0 | 20.2.0 |

Los shells generados hacen `set PATH=<kit>;%PATH%`, que antepone al PATH **ya
compuesto**, y por eso si ganan. `.\bin\kit\Doctor-Env.bat` diagnostica esto en su seccion
*Que version responde* y dice cual arranca de verdad.

Y no se limita a contarlo: cuando detecta un `[X] NO es la del kit`, **ofrece
activarlo con `Use-Env`** y `-Fix` lo aplica, con el runtime y la version ya
resueltos. Comprobado en un equipo con un Oracle Java 24 de maquina tapando el JDK
25 del kit: antes de `-Fix` respondia 24.0.2 y despues 25.0.4.1, en cmd y en
PowerShell.

> Esa reparacion es distinta de las demas: toca tu perfil de PowerShell y el
> AutoRun de cmd. `-Fix` te lo dice aparte antes de pedir confirmacion, y se
> revierte con `.\bin\env\Use-Env.bat -Off`.

### Use-Env: ganar tambien en terminales normales

```powershell
.\bin\env\Use-Env.bat                                  Ver estado
.\bin\env\Use-Env.bat -Runtime Angular -Version 22     Activar
.\bin\env\Use-Env.bat -Runtime Git -Version 2.55       Vale para los cinco runtimes
.\bin\env\Use-Env.bat -Off -Runtime Angular            Desactivar una
.\bin\env\Use-Env.bat -Off                             Desactivar todo
```

Admite los nueve: `Angular`, `Python`, `Java`, `Node`, `Git`, `Maven`, `Gradle`,
`Dotnet` y `VSCode`.

No se puede reordenar el PATH de maquina, pero **si se puede ejecutar codigo al abrir
cada terminal**, y eso ocurre despues de que Windows lo componga. Ahi la version del
kit si gana. Los dos enganches son de usuario y no necesitan admin:

| Shell | Donde |
|---|---|
| PowerShell | bloque marcado en `$PROFILE.CurrentUserAllHosts` |
| cmd.exe | `HKCU\Software\Microsoft\Command Processor` valor `AutoRun` |

#### Que hace falta para poder usarlo

Nada especial salvo una cosa: la **ExecutionPolicy** de PowerShell. Si esta en
`Restricted` o `AllSigned`, el perfil no se ejecuta y el enganche de PowerShell no
funciona (el de `cmd.exe` si, porque no es PowerShell).

`.\bin\kit\Doctor-Env.bat` lo comprueba y lo reporta en la seccion *Sistema*:

- Si viene de `CurrentUser`, se arregla sin admin:
  `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned`
- Si viene de `MachinePolicy` o `UserPolicy`, es politica de grupo y hay que pedirlo a IT.

No confundir con el `-ExecutionPolicy Bypass` que usan los `.bat` del kit: eso solo
afecta a ese proceso concreto, no a las terminales que abras tu.

#### Donde vive el perfil

En tu carpeta de usuario, pero Windows redirige `Documentos` si tienes OneDrive:

```
sin redireccion :  C:\Users\<usuario>\Documents\WindowsPowerShell\profile.ps1
con OneDrive    :  C:\Users\<usuario>\OneDrive\Documents\WindowsPowerShell\profile.ps1
```

El kit usa `$PROFILE.CurrentUserAllHosts`, o sea lo que diga Windows en cada maquina.

**Si esta en OneDrive, el perfil se sincroniza a tus otros equipos.** No rompe nada:
el bloque va envuelto en `Test-Path` y los archivos generados viven en
`%LOCALAPPDATA%`, que no se sincroniza, asi que en la otra maquina el bloque
simplemente no hace nada. Pero tendras ahi un `profile.ps1` que no pediste.

Resultado medido, con Node 22 de sistema instalado con admin:

| | antes | con Use-Env |
|---|---|---|
| `node` en cmd/PowerShell nuevos | 22.18.0 | **24.19.0** |
| `ng` | 20.2.0 | **22.1.2** |

Detalles de seguridad, porque `AutoRun` corre en **cada** `cmd`, incluidos los
`cmd /c` que lanzan npm y otras herramientas:

- El script generado es **completamente silencioso**: cualquier salida corromperia
  lo que esos procesos leen. Verificado: `cmd /c echo HOLA` devuelve una sola linea.
- Una **guarda heredada** (`CRIISDEVKIT_ACTIVE`) evita que el PATH crezca en
  shells anidados. Verificado: 25 entradas con 1 nivel y 25 con 4 niveles.
- El bloque del perfil va envuelto en `Test-Path`, asi que si se borran los archivos
  generados el perfil sigue funcionando.
- Si ya tenias un `AutoRun` de otra herramienta, se conserva y se respalda.
- `-Off` deja perfil y registro exactamente como estaban.
- Las rutas se **escapan** al generar los scripts: comilla simple duplicada en el
  `.ps1`, porcentaje duplicado en el `.cmd`. Sin eso, una carpeta de usuario como
  `C:\Users\O'Brien` producia un `activate.ps1` roto, y como lo carga el perfil, el
  sintoma era que **todas** las terminales nuevas fallaban al abrirse sin que nada
  lo relacionara con haber ejecutado `Use-Env`. La ruta del perfil va ademas en
  comillas simples: con dobles, un `$` en la ruta (`C:\Users\dev$user`) se expandia
  y la activacion apuntaba a un sitio inexistente, fallando **en silencio**.

Los enganches solo afectan a **terminales nuevas**.

### Entre versiones del propio kit

Dentro del bloque de usuario, las rutas se anaden **al principio**, asi que responde
la ultima instalada. Antes se anadian al final y ganaba la primera instalada:
poner Python 3.12 despues del 3.11 no cambiaba a que apuntaba `python`.

Al instalar sobre otras versiones ya presentes, el script las lista y avisa.

### Angular CLI nunca se publica en el PATH global

Cada version vive en su propio `npm-global`, y ponerlas todas en el PATH haria que
`ng` fuera impredecible. Solo esta disponible dentro de su shell. `Doctor` lo indica
como *"el kit trae: ... (solo dentro de su shell)"*.
