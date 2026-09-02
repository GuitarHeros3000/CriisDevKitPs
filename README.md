# Dev Environment (Sin Permisos de Administrador)

Configura entornos de desarrollo en laptops corporativas sin permisos de administrador.

## Por donde entrar: `Menu.bat`

El kit tiene 21 comandos y nadie se los sabe de memoria. `Menu.bat` los reune en una
pantalla que ademas responde la pregunta con la que uno llega: **que hay instalado**.

```
  ============================================================
   AssassinSkipAdm v2.0.0   -   entornos de desarrollo sin admin
  ============================================================

   Instalado: python 3.12

   INSTALAR
     1  Python     [3.12]          6  Maven
     2  Java                       7  Gradle
     3  Node                       8  .NET SDK
     4  Angular                    9  VS Code
     5  Git

   ABRIR                           ENTORNO
    20  Abrir un shell              40  Reproducir un devenv.json
    21  Activar en toda terminal    41  Guardar devenv.json
    22  Desactivar todo (Use-Env)   42  Fijar versiones (lock)
                                    43  Llevar a otra maquina
   MANTENER                         44  Traer de otra maquina
    30  Diagnostico
    31  Diagnostico y reparar      OTROS
    32  Informe para un ticket      50  Instalar software sin admin
    33  Ver actualizaciones         51  Pruebas del kit
    34  Desinstalar
```

**No reimplementa nada.** Cada opcion llama al mismo `.bat` que usarias a mano, asi
que hereda su salida, sus confirmaciones y sus codigos de error. Y la lista de
runtimes sale del **catalogo**: uno nuevo aparece en el menu por el hecho de estar
ahi. Los `.bat` sueltos siguen funcionando igual; el menu es un atajo, no una capa.

Es de consola a proposito, aunque una ventana seria posible sin instalar nada
(WinForms viene con Windows). La salida del kit lleva color, progreso y el informe
del `Doctor`: una GUI tendria que capturarla y repintarla, y **eso es la mayor parte
del trabajo, no la ventana**.

## Estructura del kit

```
AssassinSkipAdmPy/
├── *.bat                    Puntos de entrada (doble clic o linea de comandos)
├── lib/
│   └── Common.ps1           Descargas, proxy, checksums, semver, PATH, log
├── sources.json.ejemplo         Espejo interno (opcional)
├── devenv.json.ejemplo          Manifiesto de entorno (para tus proyectos)
├── scripts/
│   ├── Setup-AngularEnv.ps1     Start-AngularEnv.ps1
│   ├── Setup-PythonEnv.ps1      Start-PythonEnv.ps1
│   ├── Setup-JavaEnv.ps1        Start-JavaEnv.ps1
│   ├── Setup-NodeEnv.ps1        Start-NodeEnv.ps1
│   ├── Setup-GitEnv.ps1         Start-GitEnv.ps1
│   ├── Setup-MavenEnv.ps1       Start-MavenEnv.ps1
│   ├── Setup-GradleEnv.ps1      Start-GradleEnv.ps1
│   ├── Setup-DotnetEnv.ps1      Start-DotnetEnv.ps1
│   ├── Setup-VSCodeEnv.ps1      Start-VSCodeEnv.ps1
│   ├── Restore-Env.ps1          Entorno entero desde devenv.json
│   ├── Install-NoAdmin.ps1      Instalar software sin admin
│   ├── Doctor-Env.ps1           Diagnostico y reparacion
│   ├── Update-Env.ps1           Que hay desactualizado
│   ├── Uninstall-Env.ps1        Retirar y limpiar el PATH
│   ├── Use-Env.ps1              Ganarle a lo instalado con admin
│   ├── Export-Env.ps1           Import-Env.ps1
│   └── Run-Tests.ps1
└── tests/                       Suite de Pester
```

### Que instala cada uno, y que esquiva

| Runtime | Como se distribuye | Necesitaba admin? |
|---|---|---|
| Node, Python, Java | zip oficial | no |
| Angular | npm sobre su propia Node | no |
| **Git** | **PortableGit** (7z autoextraible) | **si: su instalador lo exige** |
| Maven, Gradle | zip oficial | no |
| .NET SDK | `dotnet-install.ps1` de Microsoft | no, es per-user de fabrica |
| **VS Code** | **zip en modo portable** | **si: su instalador lo exige** |

Los dos en negrita son los que de verdad esquivan algo. El resto ya tenian un
camino limpio; lo que aporta el kit ahi es colocarlos, resolverles las versiones,
el PATH, los checksums y el proxy.

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
├── Node/                    (Node suelto, independiente del de Angular)
│   └── node-22/
├── Git/
│   └── git-2.55/
├── Maven/
│   └── maven-3.9/
├── Gradle/
│   └── gradle-9.7/
├── Dotnet/
│   └── dotnet-10.0/
├── VSCode/
│   └── vscode-1.135/
│       └── data/            (tus ajustes y extensiones: esto lo hace portable)
└── Apps/                    (software instalado en modo portable)
    ├── tools/               (7z e innoextract, si el kit los necesito)
    └── <nombre-app>/
```

Una carpeta por **linea**, no por version: `python-3.12`, `jdk-21`, `node-22`,
`git-2.55`. Asi `-Force` actualiza el parche DENTRO en vez de dejar una carpeta nueva
por cada version publicada.

## Ver el plan antes de descargar: `-WhatIf`

Todos los `Setup-*Env` aceptan `-WhatIf`. Resuelven la version por red (solo lectura) y
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
| `runtimes/` | los archivos originales de **los nueve** runtimes, con su SHA-256 |
| `npm-global/` | el Angular CLI ya instalado, para no depender del registro de npm |
| `wheels/` | los paquetes pip como `.whl`, mas `get-pip.py` y el wheel de `pip` |

`Import-Env` verifica el SHA-256 de cada archivo antes de extraerlo (un USB puede
corromperlo) y **regenera los shells y el PATH con las rutas de la maquina destino**:
dentro del bundle van rutas absolutas del origen, que alli no valdrian.

Los nueve, sin excepciones. Durante un tiempo **no fue asi**: se anadieron seis
runtimes al kit y este comando se quedo en tres, asi que el bundle "portable"
ignoraba en silencio Git, Node suelto, Maven, Gradle, .NET y VS Code. Ahora los saca
del **catalogo**, y hay una prueba que pone la suite en rojo si un runtime del
catalogo se queda fuera de cualquier comando.

Cada archivo se coloca segun como venga empaquetado, que no es igual para todos:

| | |
|---|---|
| con envoltorio | el zip trae dentro una carpeta (`node-vX`, `apache-maven-X`) que se sube un nivel |
| plano | el zip vuelca su contenido directo (.NET, VS Code) |
| autoextraible | PortableGit no es un zip; se ejecuta con `-o` |

Y los remates propios de cada uno tambien: a Git se le ejecuta su `post-install`
(si no, Git Bash queda a medias) y a VS Code se le crea la carpeta `data\` (si no,
deja de ser portable en silencio).

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

`manifestVersion` va por la **2** desde que el bundle cubre los nueve runtimes. Un
kit viejo rechaza un bundle nuevo en vez de importarlo a medias sin decir nada; un
kit nuevo sigue leyendo los bundles v1, a los que simplemente les falta esa seccion.

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

## JAVA_HOME: el descuadre que no se ve

`java` en consola lo decide el **PATH**. Pero Maven, Gradle y los IDE leen
**`JAVA_HOME`**, que es otra variable. Cuando las dos apuntan a JDK distintos,
compilas con uno creyendo que usas el otro, y nada te lo dice.

`Doctor` compara las dos y avisa. Caso real de un equipo de pruebas: `java`
respondia **24.0.2** y `JAVA_HOME` apuntaba a un **`jdk1.8.0_202` de 2019**, asi
que todo se compilaba contra Java 8.

Alinearlo **no necesita admin**: el `JAVA_HOME` de usuario le gana al de maquina
(comprobado). Lo hace `.\Setup-JavaEnv.bat -SetJavaHome`.

> Cambia con que JDK compilan **todos** tus proyectos. Si algo corporativo
> depende de un Java antiguo, se entera.

## Desinstalacion

```powershell
.\Uninstall-Env.bat -Runtime Python                            Lista lo instalado
.\Uninstall-Env.bat -Runtime Python -Version 3.12 -WhatIf      Muestra el plan
.\Uninstall-Env.bat -Runtime Python -Version 3.12              Retira esa version
.\Uninstall-Env.bat -Runtime Angular -Version 20 -Node 22.23.2 Angular y su Node
.\Uninstall-Env.bat -Runtime Angular -All                      Todo el runtime
.\Uninstall-Env.bat -Everything                                TODO, de todos
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

Y no se limita a contarlo: cuando detecta un `[X] NO es la del kit`, **ofrece
activarlo con `Use-Env`** y `-Fix` lo aplica, con el runtime y la version ya
resueltos. Comprobado en un equipo con un Oracle Java 24 de maquina tapando el JDK
25 del kit: antes de `-Fix` respondia 24.0.2 y despues 25.0.4.1, en cmd y en
PowerShell.

> Esa reparacion es distinta de las demas: toca tu perfil de PowerShell y el
> AutoRun de cmd. `-Fix` te lo dice aparte antes de pedir confirmacion, y se
> revierte con `.\Use-Env.bat -Off`.

### Use-Env: ganar tambien en terminales normales

```powershell
.\Use-Env.bat                                  Ver estado
.\Use-Env.bat -Runtime Angular -Version 22     Activar
.\Use-Env.bat -Runtime Git -Version 2.55       Vale para los cinco runtimes
.\Use-Env.bat -Off -Runtime Angular            Desactivar una
.\Use-Env.bat -Off                             Desactivar todo
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

## Git (portable)

### Por que existe

Git es el caso que dejo **sin salida** a `Install-NoAdmin`, y esta comprobado con el
instalador de Git 2.55:

- Su instalador **ignora `/CURRENTUSER`**: pide administrador y se instala para toda
  la maquina.
- Y **tampoco se puede extraer**: usa un Inno Setup mas nuevo del que sabe leer
  `innoextract` 1.9 (la ultima que existe, solo llega a Inno Setup 6.0.5), y 7-Zip no
  reconoce el formato.

La salida es oficial y se llama **PortableGit**: no es un instalador, es un 7-Zip
autoextraible que Git for Windows publica en cada release. No toca el registro, no
pide administrador, y trae Git Bash entero.

### Instalacion

```powershell
.\Setup-GitEnv.bat                             Ultima publicada
.\Setup-GitEnv.bat -GitVersion 2.55.0.5        Version concreta
.\Setup-GitEnv.bat -Force                      Reinstalar / actualizar
```

Verifica el **SHA-256** contra el que la propia release publica en su tabla
`Filename | SHA-256`. Ocupa unos 385 MB ya extraido y tarda medio minuto.

Al terminar ejecuta el `post-install.bat` que trae PortableGit, que es lo que deja
listo el entorno de Git Bash (`/dev`, `/etc/mtab`). `Doctor` avisa si quedo sin
ejecutar: Git funcionaria igual, pero Git Bash iria justo.

### Uso

```powershell
.\Start-GitEnv.bat              Shell de cmd con git en el PATH
.\Start-GitEnv.bat -Bash        Abre Git Bash
```

### Si ya hay un Git instalado por administrador

Es el caso normal en un equipo corporativo, y **el PATH de usuario no puede ganarle**:
Windows compone MAQUINA + USUARIO, en ese orden. Para que responda el del kit:

```powershell
.\Use-Env.bat -Runtime Git -Version 2.55
```

Comprobado en un equipo con Git 2.55.0.3 instalado en `C:\Program Files\Git`: tras
activarlo, tanto PowerShell como cmd responden con el **2.55.0.5 del kit**, instalado
sin admin. Se revierte con `.\Use-Env.bat -Off -Runtime Git`.

Solo se pone `cmd\` en el PATH, que es lo que hace el instalador oficial en su opcion
por defecto: `bin\` trae `bash`, `sh` y otros que taparian comandos del sistema con el
mismo nombre. Para el entorno Unix completo esta `git-bash.exe`.

## Maven y Gradle

```powershell
.\Setup-MavenEnv.bat                        Ultima publicada
.\Setup-GradleEnv.bat -GradleVersion 8.14   Version concreta
```

Los dos son zip sin instalador: nunca han pedido admin. Lo que aporta el kit es
colocarlos, ponerlos en el PATH y **resolverles el JDK**, que es donde tropieza
todo el mundo: ninguno de los dos trae Java dentro y sin `JAVA_HOME` no arrancan.

El shell generado apunta al JDK del kit si lo hay. Si no, te lo dice por su nombre
en vez de dejar que fallen con un error de Java que no explica nada, y `Doctor`
detecta el caso de un shell generado cuando aun no habia ningun JDK.

Maven publica **SHA-512** y no SHA-256, que es la razon de que `Invoke-Download`
admita los dos.

### Un shell por cada JDK

Ni Maven ni Gradle leen la version de Java del proyecto: usan **el `JAVA_HOME` que
encuentren**. Con dos JDK instalados hay que decidir cual, y el kit no puede
adivinarlo por proyecto.

Asi que con **mas de un JDK** se genera un shell por cada uno:

```
Maven\maven-3.9\
├── mvn39-shell.bat          el JDK por defecto (el mas alto, o el de -JavaVersion)
├── mvn39-java21-shell.bat   JAVA_HOME = Java\jdk-21
└── mvn39-java25-shell.bat   JAVA_HOME = Java\jdk-25
```

Abres el que pide el proyecto en el que vas a trabajar. No hay que tocar
`JAVA_HOME` ni reejecutar nada, y como cada shell es una ventana aparte puedes
tener dos proyectos con Javas distintos abiertos a la vez.

Para fijar a que JDK apunta el shell por defecto:

```powershell
.\Setup-MavenEnv.bat -JavaVersion 21
```

Los shells por JDK se mantienen solos: instalar un JDK nuevo los regenera, y
desinstalar uno retira el suyo. Si el JDK del shell por defecto desaparece, se
reapunta al mas alto que quede -si no, la herramienta se quedaria rota con un
error de Java que no menciona la desinstalacion que lo causo-.

Comprobado compilando un `pom.xml` que exige `release 25`: bajo
`mvn39-java21-shell.bat` falla con *release version 25 not supported*, y bajo
`mvn39-java25-shell.bat` compila. O sea que cada shell ata Java **de verdad**, no
solo en lo que dice `mvn -version`.

> Esto no es lo mismo que las *toolchains* de Maven o Gradle, que resuelven el JDK
> desde dentro del proyecto. Requieren configuracion **en el proyecto**
> (`maven-toolchains-plugin` en el `pom.xml`, o un bloque `toolchain` en el
> `build.gradle`) y el kit no la va a meter en proyectos ajenos.

## Los JDK del kit dentro de VS Code

```powershell
.\Use-VSCodeJava.bat -WhatIf     Ensena que cambiaria
.\Use-VSCodeJava.bat             Los registra en el VS Code portable del kit
.\Use-VSCodeJava.bat -Default 21 Y elige cual manda por defecto
.\Use-VSCodeJava.bat -Global     Tambien en el VS Code que ya tenias instalado
.\Use-VSCodeJava.bat -Remove     Los quita
```

**El caso normal no necesita este comando.** El VS Code portable se mantiene solo,
igual que los shells de Maven y Gradle: instalar un JDK lo registra, desinstalarlo lo
retira, e instalar el editor teniendo ya JDK los deja anotados de entrada.

```
[SUCCESS] JDK instalado en ...\Java\jdk-21
[SUCCESS] VS Code al dia: VS Code 1.136 del kit : Java 21, 25
```

Si elegiste un JDK por defecto con `-Default`, **se respeta**: instalar otra version
no te cambia con cual compilas. Y donde nadie registro nada -o donde se quito con
`-Remove`- no se registra solo: mantener al dia lo que alguien pidio es una cosa, y
decidir por el otra distinta.

El comando queda para lo que no puede ser automatico: instalar la extension
(`-InstallExtension`, que son cientos de MB del marketplace y no puede dispararse
sola dentro de un `Setup-JavaEnv`), elegir el JDK por defecto, quitar el registro, y
el VS Code del equipo.

**Por defecto solo toca el VS Code portable del kit.** El que tengas instalado en el
equipo es tuyo: sus ajustes son personales y puede que quieras que siga compilando
con el Java que ya usaba. Se dice en cada ejecucion y se entra ahi solo con
`-Global`:

```
[INFO] No se toca: VS Code del equipo   (anade -Global si lo quieres)
```

Por lo mismo, `Doctor` **no menciona** el VS Code del equipo mientras no tenga JDK
del kit registrados: avisar de que "le falta" algo que nunca se pidio seria reganar
por no hacer una cosa que nadie ha decidido hacer.

La extension de Java de VS Code **no lee la version de Java del proyecto**: usa el
`JAVA_HOME` del proceso, que es uno solo para todas las ventanas y solo cambia al
reiniciar el editor. Con dos JDK instalados, eso significa que todos tus proyectos
compilan con el mismo.

Lo que si sabe hacer es elegir un JDK **por proyecto** si le dices cuales tienes.
Eso es `java.configuration.runtimes`, y es lo que escribe este comando:

```json
"java.configuration.runtimes": [
  { "name": "JavaSE-21", "path": "...\\Java\\jdk-21" },
  { "name": "JavaSE-25", "path": "...\\Java\\jdk-25", "default": true }
]
```

A partir de ahi, un proyecto que declara Java 21 compila con el 21 y uno que declara
25 con el 25, en el mismo VS Code y **sin tocar ningun archivo de los proyectos**.

Conoce los dos sitios donde puede vivir ese archivo: el VS Code **portable del kit**
(en `data\user-data\User\`) y el **instalado por usuario** en `%APPDATA%\Code`, que
es lo normal en un equipo corporativo. Comprobado con los dos a la vez.

### El portable no trae extensiones

Un VS Code portable recien instalado por el kit **no tiene ninguna extension**, asi
que registrar los JDK ahi no hace nada por si solo: quien lee ese ajuste es la
extension de Java. Se detecta y se dice, y se instala si se pide:

```powershell
.\Use-VSCodeJava.bat -InstallExtension
```

Instala `vscjava.vscode-java-pack` -que arrastra el servidor de lenguaje, el
depurador, las pruebas, Maven y Gradle- con el propio CLI de VS Code. **No pide
admin**: en el portable va a `data\extensions`, dentro de la carpeta del kit. Se
descarga del marketplace, asi que necesita red; el proxy del kit se le pasa por las
variables que VS Code si mira, porque el editor no usa la descarga del kit.

Comprobado de punta a punta: portable recien instalado -0 extensiones-, se registra
el JDK, avisa de que falta la extension, se instala con `-InstallExtension`, y
`Doctor` pasa de `[!] sin la extension de Java` a `[ok] Java 25`.

> Saber que extensiones hay tiene mas trampa de la que parece, y las dos vias
> evidentes fallan. El `extensions.json` de la carpeta de extensiones **queda vacio
> en cuanto usas perfiles de VS Code** -cada perfil lleva el suyo en
> `User\profiles\<id>\`-: en un equipo con 68 extensiones devolvia cero. Y mirar los
> nombres de carpeta a secas tampoco vale, porque al desinstalar VS Code dice
> *successfully uninstalled* pero deja la carpeta hasta el siguiente arranque. Lo
> que acierta en los dos casos es la carpeta **menos** lo que marque `.obsolete`.

**Es aditivo y reversible.** Los JDK que ya tuvieras registrados a mano -el de la
empresa, por ejemplo- se conservan; solo se reemplazan los que apuntan a la carpeta
`Java\` del kit. Hace una copia `.bak` antes de escribir, y `-Remove` deshace.

Si tu `settings.json` lleva **comentarios** -VS Code los admite y el lector de JSON
de PowerShell no- no lo reescribe: te imprime el bloque para que lo pegues. Comerse
los comentarios de alguien por un comando que iba de otra cosa no es aceptable.

No toca `java.jdt.ls.java.home`, que es el JDK con el que arranca el servidor de la
extension. Ese lo resuelve ella sola, y cambiarlo puede dejar sin Java a un editor
que funcionaba.

`Doctor` dice si VS Code esta al dia y avisa si instalas un JDK nuevo que aun no
conoce:

```
[ok]  VS Code del equipo        Java 21, 25   (por defecto JavaSE-25)
[!]   VS Code del equipo        falta Java 21
        Ponlo al dia con:  .\Use-VSCodeJava.bat
```

## .NET SDK

```powershell
.\Setup-DotnetEnv.bat                Ultimo canal LTS con soporte
.\Setup-DotnetEnv.bat -Channel 8.0   Canal concreto
```

El caso mas facil de todos: Microsoft publica `dotnet-install.ps1`, un script
pensado **expresamente** para instalar por usuario y en la carpeta que le digas.
Aqui no hay nada que esquivar.

El kit elige el canal LTS con soporte (descarta los que ya no reciben parches), lo
coloca en la estructura del resto, **le pasa el proxy** -el script no lee
`HTTPS_PROXY` por su cuenta, hay que darselo por parametro- y se encarga del PATH
con `-NoPath`, porque de eso se ocupa el kit con copia previa y no un script ajeno.

Ademas compara el PATH antes y despues de llamarlo, para no tener que *fiarse* de
que `-NoPath` se respete: si algun dia el instalador anadiera algo, lo dirias.
Comprobado que hoy lo respeta.

> Aparte de eso, la **primera ejecucion** del SDK -la que dispara el primer
> `dotnet new`- anade `%USERPROFILE%\.dotnet\tools`, que es donde van las
> herramientas globales de `dotnet`. Ocurre una sola vez por perfil y no la
> controla el kit. Si no la quieres, quitala con `Doctor` o a mano; `dotnet` te
> avisara si algun dia instalas una herramienta global y le falta.

El shell fija `DOTNET_ROOT`. No hace falta para compilar -`dotnet.exe` encuentra su
SDK por su ubicacion, comprobado- pero si para lo demas: las herramientas globales
y las apps publicadas la leen para elegir runtime, y con un .NET de maquina en
Program Files sin ella pueden acabar usando el del sistema.

## VS Code (portable)

```powershell
.\Setup-VSCodeEnv.bat                 Instalar o comprobar
.\Setup-VSCodeEnv.bat -Force -KeepData  Actualizar CONSERVANDO tus extensiones
.\Start-VSCodeEnv.bat                 Abrir el editor
.\Start-VSCodeEnv.bat -Shell          Consola con 'code' en el PATH
```

Su instalador normal pide admin. Pero Microsoft publica tambien el **.zip**, y ese
admite **modo portable oficial**: basta crear una carpeta `data` junto al
ejecutable y VS Code guarda ahi sus ajustes y extensiones en vez de en tu perfil.

Comprobado en un equipo que ya tenia otro VS Code instalado: se instalo una
extension desde el shell del kit y aterrizo en `data\`, con las del perfil
intactas. De propina, el entorno se lo puedes llevar entero en una carpeta.

> **Sin la carpeta `data\` deja de ser portable EN SILENCIO** y escribe en tu
> perfil. `Doctor` lo detecta y lo repara con `-Fix`. Y `Uninstall-Env` avisa
> aparte antes de borrarlo, porque `data\` son tus ajustes y extensiones, no algo
> del kit.

## Reproducir un entorno: `Restore-Env` y `devenv.json`

```powershell
.\Restore-Env.bat -Save     Escribe devenv.json con lo que YA tienes instalado
.\Restore-Env.bat -WhatIf   Ensena que haria
.\Restore-Env.bat           Instala todo lo que pide el manifiesto
```

Un `devenv.json` describe que necesita un proyecto:

```json
{
  "version": 1,
  "descripcion": "Backend Java con utilidades en Python",
  "runtimes": { "java": "21", "maven": "3.9", "python": "3.12", "git": "latest" },
  "paquetes": { "python": ["requests", "pytest"] }
}
```

**Para que sirve.** Hoy montar el entorno es acordarse de que comandos y que
versiones. Con el `devenv.json` **dentro del repositorio del proyecto**, la receta
viaja con el: en un portatil nuevo, tras una reinstalacion, o para otra persona, es
un comando. Y como es texto, se versiona: cuando subes de version queda registrado
y al resto le llega solo.

No descarga nada por su cuenta: llama a los mismos `Setup-*Env` que usarias a mano,
asi que hereda el proxy, el espejo, los checksums y las copias del PATH. Lo que ya
esta instalado no se vuelve a descargar.

El orden lo fija el kit y no el archivo: **Java se instala antes que Maven y
Gradle**, que lo necesitan.

Una errata **no se ignora**: si escribes `phyton`, el comando se niega a instalar
nada y te dice cuales reconoce. Dejar el entorno a medias sin decir por que seria
justo lo contrario de para lo que existe.

Si algo falla a mitad, sigue con el resto y al final te dice que entro y que no.

### Varias versiones del mismo runtime, y a que JDK va Maven

Un runtime admite una **lista**, y hay una seccion `java` que dice a que JDK va el
shell por defecto de Maven o de Gradle:

```json
{
  "version": 1,
  "runtimes": { "java": ["21", "25"], "maven": "3.9" },
  "java": { "maven": "21" }
}
```

Hacia falta porque con un solo valor por runtime el manifiesto **no sabia describir
tu maquina**: si trabajas en proyectos con Javas distintos, anotaba solo el mas alto
y perdia el segundo. Y sin la seccion `java`, Maven se ataba al JDK mas alto al
reproducirlo, que no tiene por que ser el del proyecto.

La seccion `java` se valida **antes** de instalar nada: atar Maven al JDK 21 en un
manifiesto que solo instala el 25 se para en seco, en vez de descargar medio entorno
y fallar al final.

`-Save` anota las dos cosas leyendo la maquina: todas las lineas instaladas, y a que
JDK apunta hoy el shell de cada herramienta, leido del propio shell. `-Lock` hace lo
mismo con las versiones exactas, y `Doctor` avisa si la atadura cambia:

```
[!]   Maven -> JDK              25  (lock: 21)
        Vuelve a atarlo con:  .\Setup-MavenEnv.bat -JavaVersion 21
```

### `devenv.lock.json`: que dos maquinas monten LO MISMO

El manifiesto dice `"python": "3.12"`. Eso es una **linea**, no una version: hoy
instala 3.12.10 y dentro de un mes 3.12.11. Dos maquinas que restauren el mismo
`devenv.json` con semanas de diferencia acaban con parches distintos.

El lock cierra esa puerta, igual que un `package-lock.json`:

```powershell
.\Restore-Env.bat -Lock      Escribe devenv.lock.json con las versiones exactas
.\Restore-Env.bat            Si hay lock, MANDA el lock
.\Restore-Env.bat -NoLock    Ignora el lock a proposito
```

Comprobado: con un lock que pedia `3.12.9` y un manifiesto que pedia `3.12`,
restauro **3.12.9** y no el 3.12.10 disponible.

**Los nueve se fijan.** Durante un tiempo solo cinco: Java y Angular recibian la
version como entero, .NET solo aceptaba canal y VS Code no tenia parametro. Ahora
los cuatro admiten **la linea o la version exacta en el mismo parametro**:

```powershell
.\Setup-JavaEnv.bat   -JavaVersion 21                 la linea
.\Setup-JavaEnv.bat   -JavaVersion jdk-21.0.9+10      ese release exacto
.\Setup-AngularEnv.bat -AngularVersion 20.3.35        ese CLI exacto
.\Setup-DotnetEnv.bat -Channel 10.0.400               ese SDK exacto
.\Setup-VSCodeEnv.bat -VSCodeVersion 1.135.0          esa version exacta
```

La carpeta y el nombre del shell siguen saliendo de la **linea** (`jdk-21`,
`angular-v20`), asi que fijar el parche no cambia donde se instala.

Comprobado: con un lock pidiendo `jdk-21.0.9+10` y un manifiesto pidiendo la linea
`21`, entra el `21.0.9+10` y `Doctor` confirma `= lock`.

Maven y Gradle tambien aceptan ya la linea, y no solo la version exacta. Antes no:
el manifiesto anotaba `"maven": "3.9"` y su Setup componia la URL de una version
literal `3.9`, que no existe, asi que `Restore-Env` no podia reinstalar Maven y solo
daba un 404. En Gradle era peor que un error visible: `9.7` y `9.7.1` existen las
dos, o sea que la linea instalaba el **primer** parche en silencio. Ahora las dos
resuelven al ultimo parche publicado de esa linea.

> Al pedir a VS Code una version concreta se usa otra ruta de descarga que **no
> publica checksum**. El kit lo dice antes de bajar en vez de dar por verificado lo
> que no lo esta.

**Y sobre los checksums:** el lock guarda el SHA-256 solo donde el kit lo anoto al
instalar, que hoy es Python. Los demas se verifican **al descargar** contra la
fuente oficial, y eso es lo que garantiza la integridad. Lo que garantiza el lock
es la **version**.

## Firma Authenticode: de quien viene el archivo

Un checksum dice que el archivo **llego entero**. No dice de **quien viene**: sale
del mismo servidor que el archivo, y con un espejo interno configurado, del mismo
espejo. Quien controle ese servidor controla las dos cosas.

La firma Authenticode responde a la otra pregunta, y contra una cadena de confianza
que Windows ya trae. Por eso funciona donde GPG no: aquel se abandono por el problema
de distribuir y rotar claves publicas, y aqui ese problema no existe.

El kit la comprueba en cada descarga firmable y en el instalador que le pases a
`Install-NoAdmin`. Ejemplos reales:

```
PortableGit-2.55.0.5-64-bit.7z.exe    Firmado por: Johannes Schindelin
dotnet-install.ps1                    Firmado por: Microsoft Corporation
npp.8.9.8.Installer.x64.exe           Firmado por: NOTEPAD++
7z2602-x64.msi                        Sin firma Authenticode
```

En Git y .NET ademas se compara contra **quien deberia firmarlos**, y si un dia firma
otro se avisa. Un cambio de certificado puede ser legitimo, pero merece una mirada.

> ### Nunca bloquea
>
> Informa; no decide por ti. Y no es una postura, es una necesidad: **el MSI de
> 7-Zip no esta firmado**, y el propio kit lo descarga para extraer instaladores
> NSIS. Bloquear lo no firmado romperia el kit consigo mismo.
>
> Tampoco es un club de empresas grandes: Notepad++ lo firma su autor a titulo
> personal. Un tercero puede estar perfectamente firmado, y si no lo esta, el kit
> te lo dice y sigue adelante.

### Cuatro estados, no dos

| Estado | Que significa |
|---|---|
| **Firmado por X** | firma valida y cadena de confianza correcta |
| **Sin firma Authenticode** | no esta firmado. Ni error ni sospecha: pasa con software legitimo |
| **Sin firma reconocible** | Windows no pudo determinarla; normalmente el archivo ni siquiera tiene formato firmable |
| **Firmado por X, pero tu equipo NO confia en quien lo emitio** | **si esta firmado**, pero por un certificado autofirmado, caducado o de una entidad desconocida |

El cuarto es el que importa y **el que se escapaba**: Windows devuelve `UnknownError`
tanto para un archivo que no es un ejecutable como para uno firmado por un editor
desconocido. Agrupar los dos hacia que un binario firmado por alguien en quien no
confias se anunciara como *"sin firma"*, que es tapar justo lo que hay que decir. Los
distingue si hay certificado o no.

Salio al preguntarse como probar esa rama, y se reproduce firmando un script con un
certificado autofirmado; hay una prueba que lo hace y se valido con un mutante.

### Tambien de lo que ya esta instalado

Comprobar la firma al descargar responde *"era legitimo cuando lo baje"*. `Doctor`
responde la otra mitad: *"?lo sigue siendo?"*. Un binario reemplazado **despues** de
instalar -por malware, o por un empujon de IT- pasaba desapercibido.

```
[ok]  Python 3.12               firmado por Python Software Foundation
[ok]  Java 25                   firmado por Eclipse Foundation
[ok]  Node 24                   firmado por OpenJS Foundation
[ok]  Git 2.55                  firmado por Johannes Schindelin
[ok]  Node 22.23.2 (de Angular) firmado por OpenJS Foundation
```

Y cuando no cuadra, lo dice con el nombre delante. Comprobado suplantando el
`node.exe` instalado de tres formas y devolviendolo despues a su sitio:

| Se sustituyo por | Que dice |
|---|---|
| otro binario firmado | `[X] firmado por Microsoft Windows, NO por OpenJS Foundation` |
| algo sin firma | `[!] sin firma reconocible` |
| uno firmado por un desconocido | `[X] firmado por Suplantador SL, en quien el equipo no confia` |

**Maven y Gradle no se comprueban**, y no se disimula: se lanzan con un `.cmd` y un
`.bat`, y Authenticode no aplica a un script por lotes. De Angular se comprueba su
Node; su CLI tambien es un `.cmd`.

**Lo que NO te da:** dice **quien** firmo, no si el software es de fiar. Un mal actor
puede comprar un certificado. Te da un nombre para que decidas tu, no un veredicto.

### Saber si te has salido del carril

El lock no solo sirve al restaurar. `Doctor` compara lo instalado contra el y senala
los desvios, que es la pregunta que uno se hace cuando algo compila distinto que a
un companero:

```powershell
.\Doctor-Env.bat                       Usa el devenv.lock.json de la carpeta actual
.\Doctor-Env.bat -Lock C:\proy\devenv.lock.json
```

Distingue tres casos: **coincide**, **distinto** (y se puede volver con
`Restore-Env`) y **el lock lo pide y no esta instalado**. Sin lock a la vista no dice
nada: no tiene sentido llenar el informe de ruido a quien no usa uno.

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

Codifica tambien los caracteres especiales de la **clave**: `@` es `%40` y `:` es
`%3A`. El kit los desescapa antes de enviarlos, asi que al proxy le llega la clave
de verdad.

**Esas credenciales se envian aparte, no dentro de la URL del proxy.**
`Invoke-WebRequest -Proxy` acepta la URL entera sin protestar pero descarta el
usuario y la clave, asi que el proxy responde 407 igual que si no hubieras puesto
nada. `Split-ProxyCredential` las separa y `Add-ProxyToRequest` las pasa por
`-ProxyCredential`; sin credenciales escritas se recurre a la identidad de Windows
(`-ProxyUseDefaultCredentials`), que es como estan montados los proxies con
autenticacion integrada. Comprobado contra un proxy Basic de verdad: antes, con la
clave correcta en la URL, fallaba con el mismo 407 que con la clave equivocada.

### Si el proxy inspecciona HTTPS

Muchos proxies corporativos abren el HTTPS y lo vuelven a firmar con la CA de la
empresa. Entonces las descargas fallan con un error de canal seguro, y el kit lo
traduce: hay que pedirle a IT ese certificado raiz e importarlo en **Certificados -
Usuario actual > Entidades de certificacion raiz de confianza**.

Eso **no necesita admin**, y esta comprobado de punta a punta: levantando un HTTPS
firmado por una CA desconocida, el kit falla culpando al certificado; con esa CA
importada en el almacen del usuario, la misma descarga pasa, sin elevar nada.

Pero Windows saca una **confirmacion de seguridad** al dar de alta una raiz, y no hay
forma de saltarsela ni con `certutil -f`. Es importante saberlo: quien no lo espera la
confunde con el aviso de administrador y responde que no, justo al reves de lo que
toca aqui.

### Autenticacion integrada (NTLM)

Si el proxy pide NTLM en vez de usuario y clave, el kit ofrece la identidad de
Windows. En un equipo **que no esta unido al dominio** esa identidad viene vacia,
SSPI corta el dialogo y .NET responde "no hay credenciales disponibles en el paquete
de seguridad", que no le dice nada a nadie. El kit lo traduce y te dice que escribas
las credenciales a mano. Con una cuenta de dominio escrita en la URL el dialogo NTLM
se completa bien: comprobado contra un proxy que exige NTLM, al que llego
`ACME\jperez` tal cual.

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
| `Split-ProxyCredential` | Separa la URL del proxy en direccion limpia y credenciales |
| `Add-ProxyToRequest` | Rellena proxy y credenciales en los parametros de una peticion |
| `Resolve-SourceUrl` | Reescribe una URL segun las reglas de espejo de `sources.json` |
| `Resolve-KitUrl` | La URL por la que se sale de verdad (oficial o espejo) |
| `Get-HashFromChecksumText` | Saca el hash de un archivo de checksum suelto |
| `Get-RuntimeCatalog` | Que runtimes hay, con que script se instala cada uno |
| `Read-DevEnvManifest` | Valida un `devenv.json` y devuelve el plan de instalacion |
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
