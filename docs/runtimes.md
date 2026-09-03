# Los runtimes, uno a uno

Como se instala cada uno, que version elige y con que se abre.

> Parte de la documentacion de **CriisDevKit**. Vuelta al [README](../README.md).

## Angular

### Instalacion

```powershell
.\bin\setup\Setup-AngularEnv.bat -AngularVersion 20
.\bin\setup\Setup-AngularEnv.bat -AngularVersion 22 -NodeVersion 24.19.0
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
.\bin\start\Start-AngularEnv.bat              Abre la version mas reciente
.\bin\start\Start-AngularEnv.bat -Version 18  Abre una version concreta
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
.\bin\setup\Setup-PythonEnv.bat -PythonVersion 3.12
.\bin\setup\Setup-PythonEnv.bat -PythonVersion 3.12 -InstallPackages django,flask
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
[WARN]   Para actualizarlo:  .\bin\setup\Setup-PythonEnv.bat -PythonVersion 3.12 -Force
```

`-Force` borra la carpeta y reinstala, asi que **se pierden los paquetes pip** que
tuvieras ahi. Anotalos antes (`pip freeze > requirements.txt`).

### Uso

```powershell
.\bin\start\Start-PythonEnv.bat                Abre la version mas reciente
.\bin\start\Start-PythonEnv.bat -Version 3.11  Abre una version concreta
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
.\bin\setup\Setup-JavaEnv.bat                          Ultima LTS
.\bin\setup\Setup-JavaEnv.bat -JavaVersion 17          Version concreta
.\bin\setup\Setup-JavaEnv.bat -JavaVersion 21 -Force   Actualizar el patch
```

Descarga el JDK de **Eclipse Temurin (Adoptium)** en zip, verificando el SHA-256
que publica su propia API. Genera un `javaN-shell.bat` que fija PATH y JAVA_HOME.

### Uso

```powershell
.\bin\start\Start-JavaEnv.bat              Abre el JDK mas reciente
.\bin\start\Start-JavaEnv.bat -Version 17  Abre una version concreta
```

### JAVA_HOME: por defecto no se toca

Maven, Gradle y los IDE leen `JAVA_HOME`, no el PATH. Cambiarla altera con que JDK
compilan **todos** tus proyectos, asi que el kit no la toca salvo que lo pidas:

```powershell
.\bin\setup\Setup-JavaEnv.bat -JavaVersion 21 -SetJavaHome
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
.\bin\setup\Setup-GitEnv.bat                             Ultima publicada
.\bin\setup\Setup-GitEnv.bat -GitVersion 2.55.0.5        Version concreta
.\bin\setup\Setup-GitEnv.bat -Force                      Reinstalar / actualizar
```

Verifica el **SHA-256** contra el que la propia release publica en su tabla
`Filename | SHA-256`. Ocupa unos 385 MB ya extraido y tarda medio minuto.

Al terminar ejecuta el `post-install.bat` que trae PortableGit, que es lo que deja
listo el entorno de Git Bash (`/dev`, `/etc/mtab`). `Doctor` avisa si quedo sin
ejecutar: Git funcionaria igual, pero Git Bash iria justo.

### Uso

```powershell
.\bin\start\Start-GitEnv.bat              Shell de cmd con git en el PATH
.\bin\start\Start-GitEnv.bat -Bash        Abre Git Bash
```

### Si ya hay un Git instalado por administrador

Es el caso normal en un equipo corporativo, y **el PATH de usuario no puede ganarle**:
Windows compone MAQUINA + USUARIO, en ese orden. Para que responda el del kit:

```powershell
.\bin\env\Use-Env.bat -Runtime Git -Version 2.55
```

Comprobado en un equipo con Git 2.55.0.3 instalado en `C:\Program Files\Git`: tras
activarlo, tanto PowerShell como cmd responden con el **2.55.0.5 del kit**, instalado
sin admin. Se revierte con `.\bin\env\Use-Env.bat -Off -Runtime Git`.

Solo se pone `cmd\` en el PATH, que es lo que hace el instalador oficial en su opcion
por defecto: `bin\` trae `bash`, `sh` y otros que taparian comandos del sistema con el
mismo nombre. Para el entorno Unix completo esta `git-bash.exe`.

## Maven y Gradle

```powershell
.\bin\setup\Setup-MavenEnv.bat                        Ultima publicada
.\bin\setup\Setup-GradleEnv.bat -GradleVersion 8.14   Version concreta
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
.\bin\setup\Setup-MavenEnv.bat -JavaVersion 21
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
.\bin\env\Use-VSCodeJava.bat -WhatIf     Ensena que cambiaria
.\bin\env\Use-VSCodeJava.bat             Los registra en el VS Code portable del kit
.\bin\env\Use-VSCodeJava.bat -Default 21 Y elige cual manda por defecto
.\bin\env\Use-VSCodeJava.bat -Global     Tambien en el VS Code que ya tenias instalado
.\bin\env\Use-VSCodeJava.bat -Remove     Los quita
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
.\bin\env\Use-VSCodeJava.bat -InstallExtension
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

`Doctor` dice si VS Code esta al dia, avisa si hay algun JDK que aun no conoce, y
**lo arregla el mismo** con `-Fix`. Igual que con los shells por JDK de Maven y
Gradle: son archivos locales, asi que reescribirlos no necesita red ni reinstalar
nada.

```
[!]   VS Code 1.136 del kit     falta Java 21
[!]     Shells por JDK          falta Java 21
[X]     JAVA_HOME del shell     jdk-99 (ya no existe)

Reparable automaticamente (3):
  - reapuntar mvn39-shell.bat al JDK mas alto que quede
  - escribir los shells por JDK que faltan en maven-3.9 (Java 21)
  - poner al dia los JDK de VS Code 1.136 del kit
```

## .NET SDK

```powershell
.\bin\setup\Setup-DotnetEnv.bat                Ultimo canal LTS con soporte
.\bin\setup\Setup-DotnetEnv.bat -Channel 8.0   Canal concreto
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
.\bin\setup\Setup-VSCodeEnv.bat                 Instalar o comprobar
.\bin\setup\Setup-VSCodeEnv.bat -Force -KeepData  Actualizar CONSERVANDO tus extensiones
.\bin\start\Start-VSCodeEnv.bat                 Abrir el editor
.\bin\start\Start-VSCodeEnv.bat -Shell          Consola con 'code' en el PATH
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
