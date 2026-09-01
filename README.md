# Dev Environment (Sin Permisos de Administrador)

Configura entornos de desarrollo en laptops corporativas sin permisos de administrador.

## Estructura del kit

```
AssassinSkipAdmPy/
├── *.bat                    Puntos de entrada (doble clic o linea de comandos)
├── lib/
│   └── Common.ps1           Descargas, proxy, checksums, semver, PATH, log
└── scripts/
    ├── Setup-AngularEnv.ps1
    ├── Setup-PythonEnv.ps1
    ├── Setup-JavaEnv.ps1
    ├── Start-AngularEnv.ps1
    ├── Start-PythonEnv.ps1
    ├── Start-JavaEnv.ps1
    ├── Install-NoAdmin.ps1
    ├── Doctor-Env.ps1
    ├── Uninstall-Env.ps1
    └── Use-Env.ps1
```

Los `.bat` de la raiz son la interfaz publica: siempre se ejecutan desde ahi.
La logica vive en `scripts\`, y lo compartido en `lib\Common.ps1`.

## Donde se instala todo

El kit nunca instala dentro de si mismo. Crea carpetas **hermanas**:

```
Proyectos Individuales/
├── AssassinSkipAdmPy/       (este kit)
├── Angular/
│   ├── node-v20.19.0-win-x64/
│   ├── angular-v18/
│   ├── angular-v19/
│   └── angular-v20/
├── Python/
│   ├── python-3.11/
│   └── python-3.12/
├── Java/
│   ├── jdk-17/
│   └── jdk-21/
└── Apps/                    (software instalado en modo portable)
    └── <nombre-app>/
```

## Ver el plan antes de descargar: `-WhatIf`

Los tres `Setup-*Env` aceptan `-WhatIf`. Resuelven la version por red (solo lectura) y
te dicen exactamente que pasaria, **sin tocar nada**:

```powershell
.\Setup-JavaEnv.bat -JavaVersion 21 -WhatIf
```
```
Se va a instalar:

  [release]  jdk-21.0.12+8
  [descarga] 195.6 MB  (SHA-256 verificado)
  [carpeta]  ...\Java\jdk-21
  [PATH]     ...\Java\jdk-21\bin
  [shell]    java21-shell.bat
  [JAVA_HOME] no se tocaria (usa -SetJavaHome si lo quieres)

-WhatIf: no se ha tocado nada.
```

Sirve sobre todo para tres cosas: ver **cuanto** vas a descargar antes de hacerlo por
un proxy lento, ver **que version exacta** se ha resuelto (el patch de Python o la
Node que pide ese Angular), y confirmar que `-Force` no va a borrar algo que querias.

## Por donde empezar

El flujo depende de si en esa maquina ya hay algo instalado con permisos de
administrador. `Doctor` te lo dice, asi que el orden es siempre el mismo:

```
1. .\Doctor-Env.bat                          Ver como esta la maquina
2. .\Setup-PythonEnv.bat -PythonVersion 3.12 Instalar lo que necesites
3. .\Doctor-Env.bat                          Comprobar quien responde
```

En el paso 3, mira la seccion **Que version responde**:

| Lo que ves | Que hacer |
|---|---|
| `[ok]` con la ruta del kit | Nada. Ya responde la del kit en cualquier terminal. |
| `[X] ... NO es la del kit` | Hay algo instalado con admin que la tapa. Usa `Start-*Env.bat`, o `Use-Env.bat` si la quieres global. |
| `[!] ... no es la del kit` | El kit la trae pero solo dentro de su shell (caso de `ng`). Usa `Start-AngularEnv.bat`. |

### Laptop bloqueada, sin nada instalado con admin

Es el caso para el que existe el kit. `Setup-*Env` **basta**: el PATH de usuario gana
porque no hay nada por delante. No hace falta `Use-Env` y no se crea ningun perfil.

### Maquina con runtimes ya instalados por IT

Ahi el PATH de maquina va por delante y tapa al del kit. Dos salidas:

- **`Start-*Env.bat`** — abre un shell con la version del kit. No deja rastro fuera
  de las carpetas que ya crea el setup. Es la opcion recomendada.
- **`Use-Env.bat`** — hace que gane tambien en terminales normales. Ver mas abajo.

### Desinstalar

```
1. .\Use-Env.bat -Off                        Si lo habias activado
2. .\Uninstall-Env.bat -Runtime Python -All  Retira carpetas y limpia el PATH
```

## Llevarlo a una maquina sin internet

El kit depende de seis dominios: `nodejs.org`, `registry.npmjs.org`, `python.org`,
`pypi.org`, `api.adoptium.net` y `github.com`. En una laptop corporativa basta con
que bloqueen **uno** para que ese runtime sea inalcanzable.

```powershell
.\Export-Env.bat -Output D:\usb\entorno.zip     En la maquina CON internet
.\Import-Env.bat -Path D:\usb\entorno.zip       En la maquina SIN internet
```

### Que lleva el bundle

| | |
|---|---|
| `env.json` | manifiesto: versiones exactas de cada runtime y paquete |
| `runtimes/` | los zip originales de Node, Python y el JDK, con su SHA-256 |
| `npm-global/` | el Angular CLI ya instalado, para no depender del registro de npm |
| `wheels/` | los paquetes pip como `.whl`, mas `get-pip.py` y el wheel de `pip` |

`Import-Env` verifica el SHA-256 de cada archivo antes de extraerlo (un USB puede
corromperlo) y **regenera los shells y el PATH con las rutas de la maquina destino**:
dentro del bundle van rutas absolutas del origen, que alli no valdrian.

### Detalles que costaron encontrar

- Instalar pip sin red necesita **dos** piezas: `get-pip.py` *y* el `pip-*.whl`.
  `get-pip.py --no-index` no instala el pip que lleva embebido, solo lo usa para
  ejecutarse; el paquete lo busca en `--find-links`.
- Instalar el wheel de pip con el propio pip falla con *"To modify pip, please run
  the following command"*: pip se protege de modificarse a si mismo.
- `pip freeze` nunca se lista a si mismo, asi que pip hay que pedirlo aparte.

### Opciones

```powershell
-Runtime Python     Exporta o importa solo un runtime
-SkipBinaries       Solo el manifiesto (unos KB); el destino necesitara internet
-WhatIf             Import-Env: muestra el plan sin instalar
```

El manifiesto lleva dos versiones distintas: `manifestVersion` describe el **formato**
del `env.json` y decide si el bundle se puede importar, y `kitVersion` identifica el
kit que lo genero. La segunda es informativa: si no coincide, `Import-Env` lo dice
pero no bloquea. `Doctor` muestra la version del kit de esta maquina.

## Registro de ejecuciones

Cada ejecucion deja un archivo en `%LOCALAPPDATA%\AssassinSkipAdm\logs`, con el
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
- Se desactiva con `ASSASSINSKIPADM_NOLOG`.

## Que hay para actualizar

```powershell
.\Update-Env.bat                 Todo lo instalado
.\Update-Env.bat -Runtime Java   Solo uno
```

```
  Runtime               Instalado       Disponible
  Python 3.12           3.12.10         3.12.10         al dia
  Java 21               jdk-21.0.12+8   jdk-21.0.12+8   al dia
  Node 22 (suelto)      22.14.0         22.23.2         actualizable
  Angular CLI 20        20.3.33         20.3.33         al dia
  Node 22 (de Angular)  22.23.2         22.23.2         al dia

Para actualizar:
  Node 22 (suelto)   .\Setup-NodeEnv.bat -NodeVersion 22.23.2 -Force
```

**No instala nada nunca.** Como `Doctor`, solo lee: te da el comando exacto y decides
tu, porque actualizar implica `-Force` y en Python eso borra los paquetes pip.

Sale con codigo **1 si hay algo que actualizar**, para poder encadenarlo.

Distingue la Node suelta de la que Angular instala para si mismo, porque son
instalaciones independientes: la de Angular la elige su CLI y no se toca a mano.

## Diagnostico

```powershell
.\Doctor-Env.bat              Diagnostico completo (solo lee, no toca nada)
.\Doctor-Env.bat -SkipNetwork Sin pruebas de conectividad
.\Doctor-Env.bat -Fix         Repara lo que se pueda arreglar en local
.\Doctor-Env.bat -Report      Ademas, guarda un informe para adjuntar a un ticket
```

### -Report

Guarda el diagnostico en un markdown listo para mandar a IT, con el equipo, el
usuario, la build de Windows, la version de PowerShell y la del kit:

```powershell
.\Doctor-Env.bat -Report                              a %LOCALAPPDATA%\AssassinSkipAdm\informes
.\Doctor-Env.bat -Report -ReportPath D:\ticket.md     a donde tu digas
```

**La clave del proxy va enmascarada** (`usuario:***@servidor`), asi que el archivo se
puede adjuntar tal cual. Se escribe **antes** de las reparaciones a proposito: si lo
generas junto con `-Fix`, lo util para el ticket es lo que fallaba, no como quedo
despues.

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
`ASSASSINSKIPADM_NOPAUSE` cuando los invoques desde otro script y no esperaran tecla:

```powershell
$env:ASSASSINSKIPADM_NOPAUSE = "1"
.\Doctor-Env.bat -SkipNetwork
if ($LASTEXITCODE -ne 0) { "revisa el entorno antes de seguir" }
```

## Desinstalacion

```powershell
.\Uninstall-Env.bat -Runtime Python                            Lista lo instalado
.\Uninstall-Env.bat -Runtime Python -Version 3.12 -WhatIf      Muestra el plan
.\Uninstall-Env.bat -Runtime Python -Version 3.12              Retira esa version
.\Uninstall-Env.bat -Runtime Angular -Version 20 -Node 22.23.2 Angular y su Node
.\Uninstall-Env.bat -Runtime Angular -All                      Todo el runtime
```

Retira la carpeta **y** limpia las entradas del PATH que apuntaban ahi. Sin esto,
borrar la carpeta a mano dejaba rutas muertas en el PATH del usuario para siempre.

- Pide confirmacion salvo con `-Force`, y `-WhatIf` no toca nada.
- Solo reconoce lo que el propio kit creo (`angular-vN`, `node-vX-win-x64`,
  `python-X.Y`, `npm-cache`). Cualquier otra carpeta que hubiera ahi se ignora.
- Nunca toca el PATH de maquina ni instalaciones ajenas al kit.
- Limpia el PATH **antes** de borrar carpetas: si algo falla, es preferible un PATH
  correcto con una carpeta de sobra que al reves.
- Guarda copia del PATH previo en `%LOCALAPPDATA%\AssassinSkipAdm\path-backups\`.

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
compuesto**, y por eso si ganan. `.\Doctor-Env.bat` diagnostica esto en su seccion
*Que version responde* y dice cual arranca de verdad.

### Use-Env: ganar tambien en terminales normales

```powershell
.\Use-Env.bat                                  Ver estado
.\Use-Env.bat -Runtime Angular -Version 22     Activar
.\Use-Env.bat -Off -Runtime Angular            Desactivar una
.\Use-Env.bat -Off                             Desactivar todo
```

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

`.\Doctor-Env.bat` lo comprueba y lo reporta en la seccion *Sistema*:

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
- Una **guarda heredada** (`ASSASSINSKIPADM_ACTIVE`) evita que el PATH crezca en
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

## Angular

### Instalacion

```powershell
.\Setup-AngularEnv.bat -AngularVersion 20
.\Setup-AngularEnv.bat -AngularVersion 22 -NodeVersion 24.19.0
```

Descarga Node.js portable (verificando su SHA-256 oficial), instala Angular CLI
en un `npm-global` propio de esa version y genera un `shell-vN.bat`.

### Que version de Node se instala

No es fija. El script pregunta al registro de npm que declara esa version del CLI
en `engines.node`, consulta las LTS disponibles en nodejs.org y elige.

**Regla:** la linea LTS mas alta que el rango nombra *explicitamente* con `^`. Los
terminos `^X.Y.Z` son las majors contra las que Angular probo de verdad; el `>=X` final
es una puerta abierta a majors que aun no existian. Se descartan las lineas por debajo
de Node 16.

Resultado actual (verificado contra registry.npmjs.org el 2026-08-04):

| Angular | `engines.node` del CLI | Node instalado |
|---|---|---|
| 14 | `^14.15.0 \|\| >=16.10.0` | 16.20.2 |
| 15 | `^14.20.0 \|\| ^16.13.0 \|\| >=18.10.0` | 16.20.2 |
| 16 | `^16.14.0 \|\| >=18.10.0` | 16.20.2 |
| 17 | `^18.13.0 \|\| >=20.9.0` | 18.20.8 |
| 18 | `^18.19.1 \|\| ^20.11.1 \|\| >=22.0.0` | 20.20.2 |
| 19 | `^18.19.1 \|\| ^20.11.1 \|\| >=22.0.0` | 20.20.2 |
| 20 | `^20.19.0 \|\| ^22.12.0 \|\| >=24.0.0` | 22.23.2 |
| 21 | `^20.19.0 \|\| ^22.12.0 \|\| >=24.0.0` | 22.23.2 |
| 22 | `^22.22.3 \|\| ^24.15.0 \|\| >=26.0.0` | 24.19.0 |

Como la resolucion es dinamica, una version futura de Angular funcionara sin tocar el
codigo. La tabla equivalente esta ademas cableada en el script como respaldo para cuando
no hay red. Con `-NodeVersion` se fuerza una version concreta; si no cumple lo que pide
el CLI, se avisa antes de descargar nada.

Varias versiones de Node conviven en `Angular\`, asi que Angular 16 y Angular 22 pueden
estar instalados a la vez sin pisarse.

### Uso

```powershell
.\Start-AngularEnv.bat              Abre la version mas reciente
.\Start-AngularEnv.bat -Version 18  Abre una version concreta
```

### Comandos

```powershell
ng version           Ver version
ng new <nombre>      Crear proyecto
ng serve             Servidor desarrollo
ng generate <tipo>   Generar componentes
ng build             Compilar produccion
```

## Python

### Instalacion

```powershell
.\Setup-PythonEnv.bat -PythonVersion 3.12
.\Setup-PythonEnv.bat -PythonVersion 3.12 -InstallPackages django,flask
```

Descarga el Python *embeddable*, lo parchea para que pip funcione
(`import site` + `Lib\site-packages`) y genera un `pyXYZ-shell.bat`.

### Que patch se instala

Si indicas `3.12`, el script busca la **ultima 3.12.x que tenga binario para Windows**.
No basta con coger el numero mas alto: cuando una serie pasa a modo *solo seguridad*,
python.org publica esas versiones unicamente como codigo fuente. Hoy, por ejemplo,
3.12.13 existe pero no tiene zip embeddable, asi que se instala 3.12.10 y el script
dice por que.

Con `-PythonVersion 3.12.9` se instala exactamente esa.

### Actualizar el patch

La carpeta se llama solo `python-3.12`, asi que una version ya instalada tapa a
cualquier patch posterior. El script compara el patch **real** del `python.exe`
instalado con el disponible y avisa:

```
[WARN] Ya hay Python 3.12.9 instalado en python-3.12
[WARN]   Disponible: 3.12.10
[WARN]   Para actualizarlo:  .\Setup-PythonEnv.bat -PythonVersion 3.12 -Force
```

`-Force` borra la carpeta y reinstala, asi que **se pierden los paquetes pip** que
tuvieras ahi. Anotalos antes (`pip freeze > requirements.txt`).

### Uso

```powershell
.\Start-PythonEnv.bat                Abre la version mas reciente
.\Start-PythonEnv.bat -Version 3.11  Abre una version concreta
```

### Comandos

```powershell
python --version      Ver version
pip install <paquete> Instalar paquete
django-admin          Comandos Django
flask                 Comandos Flask
```

## Java (JDK)

### Instalacion

```powershell
.\Setup-JavaEnv.bat                          Ultima LTS
.\Setup-JavaEnv.bat -JavaVersion 17          Version concreta
.\Setup-JavaEnv.bat -JavaVersion 21 -Force   Actualizar el patch
```

Descarga el JDK de **Eclipse Temurin (Adoptium)** en zip, verificando el SHA-256
que publica su propia API. Genera un `javaN-shell.bat` que fija PATH y JAVA_HOME.

### Uso

```powershell
.\Start-JavaEnv.bat              Abre el JDK mas reciente
.\Start-JavaEnv.bat -Version 17  Abre una version concreta
```

### JAVA_HOME: por defecto no se toca

Maven, Gradle y los IDE leen `JAVA_HOME`, no el PATH. Cambiarla altera con que JDK
compilan **todos** tus proyectos, asi que el kit no la toca salvo que lo pidas:

```powershell
.\Setup-JavaEnv.bat -JavaVersion 21 -SetJavaHome
```

`Uninstall-Env` la retira sola si apuntaba a lo que borra, para no dejarte Maven
apuntando a una carpeta inexistente.

`Doctor` muestra cual manda y de donde sale (usuario o maquina).

### Nota sobre la red

La API vive en `api.adoptium.net` pero los binarios se sirven desde `github.com`.
Son dos permisos distintos en un cortafuegos corporativo, asi que `Doctor` los
comprueba por separado.

## Install-NoAdmin

Instala software en tu perfil de usuario **sin permisos de administrador**, usando el
modo per-user que el propio instalador ya soporta. No modifica el instalador ni el
sistema, y no eleva privilegios: si un software necesita admin de verdad, lo dice y para.

### Uso

```powershell
.\Install-NoAdmin.bat -Path "C:\Descargas\app.msi"
```

### Que hace

1. Detecta el tipo de instalador (MSI / WiX Burn / Inno Setup / NSIS / desconocido).
2. Intenta la instalacion per-user nativa (sin admin).
3. Verifica **donde aterrizo de verdad**, comparando HKCU **y HKLM** antes y despues.
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
| Inno Setup | cadena `Inno Setup` en el binario | `/CURRENTUSER` | `innounp` |
| NSIS | cadena `Nullsoft` en el binario | no fiable | `7z x` |

Burn se detecta por su seccion PE, no por buscar la palabra "Burn" en el binario:
esa aparece por casualidad en casi cualquier ejecutable grande.

Un `/layout` de Burn deja los MSI sueltos, no una app portable lista para usar. Si
alguno de esos MSI instala drivers o servicios, seguira necesitando admin.

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

## Redes corporativas (proxy y certificados)

Todas las descargas pasan por `Invoke-Download` en `lib\Common.ps1`, que:

- Fuerza **TLS 1.2** (PowerShell 5.1 negocia TLS 1.0, que python.org y nodejs.org rechazan).
- Detecta el **proxy** automaticamente: primero `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY`,
  y si no, el proxy del sistema (WPAD/PAC u Opciones de Internet).
- Reintenta solo los fallos transitorios; un 404 o un 407 no se reintentan.
- Descarga a un archivo `.part` y solo lo publica si termino bien, para no dejar
  nunca un zip a medias que parezca valido.
- Traduce el error a la causa real (proxy, certificado, DNS, version inexistente).

Si el proxy pide credenciales:

```powershell
$env:HTTPS_PROXY = "http://usuario:clave@proxy.empresa:8080"
```

**Si tu usuario es de dominio, codifica la barra invertida como `%5C`:**

```powershell
$env:HTTPS_PROXY = "http://dominio%5Cusuario:clave@proxy.empresa:8080"
```

Sin codificar, la URL **no es una URI valida** y el proxy no funciona en absoluto:
ni siquiera llega a intentarse la conexion. El error de .NET no lo explica, asi que
el kit lo detecta antes y te dice esto mismo.

**La clave nunca se imprime.** Todo lo que muestra un proxy pasa por
`Format-ProxyForDisplay`, que la sustituye por `***` y conserva el usuario (que si
hace falta para diagnosticar). Importa sobre todo en `Doctor`, cuya salida es justo
la que se acaba pegando en un ticket para IT.

Y como los mensajes de excepcion de .NET incrustan la URL del proxy tal cual,
`Write-Log` pasa **todo** por `Protect-ProxySecrets` antes de imprimirlo. Enmascarar
solo en origen no bastaba: la fuga que lo motivo venia de dentro de un error de
.NET, o sea de un sitio donde nadie se habria acordado de enmascarar.

Tampoco viaja en la linea de comandos de `pip`. Se le pasa por `PIP_PROXY`, que es su
propio mecanismo de variables de entorno (toda opcion larga tiene su `PIP_<OPCION>`),
no el `HTTPS_PROXY` generico que no siempre se respeta. Con un argumento `--proxy` la
clave quedaba visible para cualquier proceso del equipo mientras pip corriera
(`Win32_Process`, Administrador de tareas); el bloque de entorno de un proceso ajeno,
en cambio, no se lee sin permiso para abrir su memoria.

Cubre los **dos** momentos en que se usa pip: instalar los paquetes de
`-InstallPackages` y arrancar pip con `get-pip.py`. El segundo tambien necesita red
(ver mas abajo), y sin proxy el Python recien instalado se quedaba sin pip.

Si el proxy inspecciona HTTPS y falla el certificado, pide a IT el certificado raiz e
importalo en *Certificados - Usuario actual* > *Entidades de certificacion raiz de
confianza* (no necesita admin).

### Verificacion de descargas

| Descarga | Que se comprueba | Nivel |
|---|---|---|
| Node.js | SHA-256 contra el `SHASUMS256.txt` de nodejs.org | integridad |
| JDK (Temurin) | SHA-256 que publica la API de Adoptium | integridad |
| Python | el zip abre y no llego truncado; se anota su SHA-256 | integridad |
| get-pip.py | HTTPS | — |

**Ninguno de los tres es verificacion de autenticidad, y conviene saberlo.**

Un checksum viaja por **el mismo canal** que el archivo. Quien pueda sustituirte el
zip puede sustituir tambien el hash, y encajaran perfectamente. Eso sirve contra una
descarga corrupta o un fallo del CDN, que es lo habitual, pero **no** contra alguien
capaz de interceptar la conexion. En una red con proxy que inspecciona HTTPS, ese
"alguien" esta en el camino por diseno.

Lo unico que resolveria eso es verificar las **firmas GPG**, que no se pueden
falsificar sin la clave privada del firmante. Existen: nodejs.org publica
`SHASUMS256.txt.asc`, python.org publica un `.asc` por archivo y Adoptium un `.sig`.
El kit **no las verifica**, y la razon no es tecnica sino de mantenimiento:

- Se comprobo que funciona: con el `gpg.exe` que trae Git for Windows y la clave
  correcta, la firma del zip de Python valida (`Good signature`, salida 0).
- El problema es **conseguir y mantener las claves**. Node firma cada release con la
  clave del releaser que la publica, y hay una decena rotando: fijarlas en el repo
  significa que el kit se rompe cada pocos meses. De las de Node y Adoptium no se
  encontro fuente publica estable.

Asi que el kit se queda en integridad y lo dice claro, en vez de aparentar mas.

Sobre el `.sigstore` de Python: sacarle el digest a mano no aportaria nada, porque
quien sirviera un zip manipulado serviria tambien un `.sigstore` a juego. Verificarlo
de verdad exige contrastarlo contra el log de transparencia, o sea herramientas que
una maquina bloqueada no tiene (y para Python haria falta Python).

El SHA-256 que se anota en `.assassinskipadm-sha256` y muestra `Doctor` es
**trazabilidad**: sirve para comparar dos maquinas que dicen tener la misma version y
para detectar que los archivos cambiaron despues de instalarlos.

## Solucion de problemas

**Empieza siempre por aqui:**
```powershell
.\Doctor-Env.bat
```

**Error de ejecucion de scripts:**
```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

Los `.bat` ya usan `-ExecutionPolicy Bypass`, asi que normalmente no hace falta.

**npm falla detras del proxy:** npm tiene su propia configuracion, aparte de la del kit:
```powershell
npm config set proxy http://usuario:clave@proxy.empresa:8080
npm config set https-proxy http://usuario:clave@proxy.empresa:8080
```

**El PATH quedo raro:** cada modificacion guarda una copia previa en
`%LOCALAPPDATA%\AssassinSkipAdm\path-backups\`.

**Laptop sin permisos de admin:**
- Todo funciona en carpetas de usuario
- Los shells .bat funcionan sin restricciones de PowerShell

## Pruebas

```powershell
.\Run-Tests.bat                    Todas
.\Run-Tests.bat -Name UserPath     Solo un archivo
.\Run-Tests.bat -Quiet             Solo el resumen
```

Sale con codigo 1 si falla alguna, asi que se puede encadenar.

### Por que Pester 3.4

Es la version que **viene de fabrica con Windows**. Pedir Pester 5 obligaria a un
`Install-Module` contra PSGallery, que es justo lo que bloquea el proxy corporativo
para el que existe este kit: unas pruebas que no se pueden ejecutar en la maquina de
destino no sirven de nada. El runner fuerza la 3.x aunque haya una 5 instalada,
porque la sintaxis de asercion cambio (`Should Be` paso a `Should -Be`).

### Que se cubre

| Archivo | Que prueba |
|---|---|
| `Common.Tests.ps1` | Funciones puras: enmascarado del proxy, los cuatro escapados, `Test-SemverRange` contra los `engines` reales del CLI, semver, URLs |
| `Shells.Tests.ps1` | Los tres shells generados: que el `.bat` **funciona al ejecutarlo en cmd** y que `Use-Env` recupera de el la ruta exacta |
| `UserPath.Tests.ps1` | `Add-UserPathEntry` y `Remove-UserPathEntry` |

Ninguna prueba toca el registro, el PATH real ni la red. Las del PATH sustituyen por
mocks sus dos unicas puertas al sistema, `Get-RawUserPath` y `Save-UserPath`.

### El caso que justifica todo esto

Casi cada prueba cubre un fallo que existio de verdad, y **ninguno se reproduce en la
maquina de quien desarrolla el kit**:

| Fallo | Solo aparece si... |
|---|---|
| Todas las terminales rotas al abrirse | tu usuario se llama `O'Brien` |
| El PATH del shell cortado por la mitad | tu carpeta se llama `Marks & Spencer` |
| La contrasena del proxy filtrada a medias | tu clave contiene un `@` |
| Rutas reescapadas en bucle (`%%%%`) | tu ruta contiene un `%` |

Probar el kit a mano en la propia maquina no encuentra nada de esto. Por eso las
pruebas usan una carpeta llamada `Marks & Spencer 100% ^O'Brien`.

## Anadir un runtime nuevo

El patron esta pensado para crecer (Java, Go, .NET, Git portable...):

1. Crear `scripts\Setup-<Runtime>Env.ps1`.
2. Empezar con `. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")`.
3. Usar `$WorkspaceRoot` para la carpeta destino, `Invoke-Download` para bajar,
   `Test-ZipIntegrity` antes de extraer y `Add-UserPathEntry` para el PATH.
4. Copiar un `.bat` existente de la raiz y cambiarle el nombre del `.ps1`.
5. Anadir una comprobacion en `Doctor-Env.ps1` y el archivo a su lista `$expected`.

### Convencion: las funciones no llaman a `exit`

Una funcion que falla **explica el motivo y devuelve `$null`**; quien la llama
decide si eso es fatal. Los `exit` viven solo en el cuerpo del script:

```powershell
$version = Resolve-MiRuntimeVersion -Requested $Pedida
if (-not $version) { exit 1 }
```

Es la misma convencion que ya siguen `Invoke-Download` (`$true`/`$false`) e
`Invoke-JsonApi` (`$null`) en `Common.ps1`, y existe por dos motivos: una funcion
que llama a `exit` **no se puede probar** (se lleva por delante el proceso de
pruebas) y **no se puede reutilizar** desde un script que instale varios runtimes
seguidos, porque el primer fallo aborta todo lo demas.

No hay que reescribir proxy, TLS, reintentos ni manejo de PATH: ya vienen de `Common.ps1`.

### Los shells se generan con las rutas escapadas

Un `.bat` tiene dos contextos y cada uno escapa distinto, asi que hay dos funciones:

| Donde | Que protege | Ejemplo generado |
|---|---|---|
| `set "VAR=..."` | las comillas cubren `&`, `\|`, `^`, `<`, `>`; queda el `%` | `set "PATH=C:\Marks & Spencer 100%%\bin;%PATH%"` |
| `echo ...` | no admite comillas: hay que escapar a mano | `echo Ruta: C:\Marks ^& Spencer 100%%` |

Con `set PATH=` **sin** comillas, un `&` en la ruta partia la linea en dos comandos
y el shell quedaba con el PATH a medias. Nombres asi son de lo mas normal en una
carpeta corporativa.

`Use-Env` vuelve a **leer** estos shells para saber que rutas antepone cada uno, asi
que su expresion regular acepta las comillas como opcionales: los shells generados
por una version anterior del kit siguen en disco y tienen que seguir entendiendose.

### Lo que ofrece `lib\Common.ps1`

| Funcion | Para que |
|---|---|
| `Write-Log` | Log con timestamp y color |
| `Invoke-Download` | Descarga con proxy, TLS, reintentos, SHA-256 y diagnostico |
| `Invoke-JsonApi` | GET de una API JSON con el mismo tratamiento de proxy |
| `Get-Sha256FromShasums` | Lee un `SHASUMS256.txt` remoto |
| `Get-FileSha256` | SHA-256 de un archivo local |
| `Test-ZipIntegrity` | Detecta zips truncados antes de extraer |
| `Test-SemverRange` | Comprueba una version contra un rango npm (`^`, `~`, `>=`, `\|\|`) |
| `Add-UserPathEntry` | Anade al PATH (al principio por defecto), sin duplicar |
| `Remove-UserPathEntry` | Quita entradas exactas o todo lo que cuelgue de una carpeta |
| `Show-PathConflicts` | Avisa si ya hay otras versiones del runtime en el PATH |
| `Resolve-DownloadProxy` | Devuelve el proxy a usar para una URL |
| `Format-ProxyForDisplay` | Oculta la clave de una URL de proxy antes de mostrarla |
| `Protect-ProxySecrets` | Igual, pero en cualquier punto de un texto (errores de .NET) |
| `Test-ProxyUsable` | Valida la URL del proxy y explica el `%5C` de las cuentas de dominio |
| `Start-KitLog` | Abre el registro en archivo de la ejecucion |
| `Get-UnsupportedSemverComparators` | Terminos de un rango que `Test-SemverRange` no sabe leer |
| `ConvertTo-PsLiteral` | Escapa un valor para codigo PowerShell generado (comillas simples) |
| `ConvertTo-CmdLiteral` | Escapa un valor para `set "VAR=..."` de un `.bat` |
| `ConvertFrom-CmdLiteral` | Lo deshace, al volver a leer un shell generado |
| `ConvertTo-CmdEchoText` | Escapa un valor para una linea `echo` de un `.bat` |
| `Invoke-NativeCommand` | Ejecuta un `.exe` sin que su stderr aborte el script |
| `Restore-EnvVar` | Devuelve una variable de entorno a su valor previo |
| `Get-WebText` | GET que devuelve texto (listados HTML), con proxy |
| `Test-UrlExists` | HEAD para saber si un archivo existe sin descargarlo |

`Invoke-NativeCommand` es obligatorio para llamar a `python`, `pip`, `npm`, `ng`, `7z`
o `innounp`. En PowerShell 5.1 todo lo que un `.exe` escribe en stderr se convierte en
un `ErrorRecord`, y con `$ErrorActionPreference = "Stop"` eso aborta el script aunque
el comando fuera solo una comprobacion. Ni `2>$null` ni `*> $null` lo impiden.

### npm y la configuracion del usuario

`Setup-AngularEnv` **no** ejecuta `npm config set`: eso escribiria en
`%USERPROFILE%\.npmrc` de forma permanente y dejaria el npm que el usuario ya tuviera
apuntando su cache dentro de este kit. En su lugar se usan `NPM_CONFIG_PREFIX` y
`NPM_CONFIG_CACHE`, solo para el proceso y en el shell generado.

`Test-SemverRange` cubre lo que usan los campos `engines` en la practica: `^`, `~`,
`>=`, `<=`, `>`, `<`, `=`, alternativas con `||`, conjunciones separadas por espacio,
comodines (`14.x`, `20.19.*`) y versiones parciales (`20` equivale a `20.x.x`).

No es semver completo: **los rangos con guion (`1.2 - 1.5`) siguen sin soportarse**.
La diferencia es que ahora se avisa en vez de descartarlos en silencio:
`Get-UnsupportedSemverComparators` senala los terminos que no se entienden y
`Setup-AngularEnv` los reporta una vez, antes de elegir la version de Node.

Los comodines si se anadieron, porque `"node": "14.x"` es de lo mas comun en un campo
`engines` y antes se interpretaba como **exactamente 14.0.0**: cualquier Node 14.21
quedaba descartado y nadie se enteraba.
