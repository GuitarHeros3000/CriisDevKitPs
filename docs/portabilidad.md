# Llevarse el entorno

El bundle para una maquina sin internet, y reproducir un entorno con devenv.json.

> Parte de la documentacion de **CriisDevKit**. Vuelta al [README](../README.md).

## Llevarlo a una maquina sin internet

El kit depende de seis dominios: `nodejs.org`, `registry.npmjs.org`, `python.org`,
`pypi.org`, `api.adoptium.net` y `github.com`. En una laptop corporativa basta con
que bloqueen **uno** para que ese runtime sea inalcanzable.

```powershell
.\bin\env\Export-Env.bat -Output D:\usb\entorno.zip     En la maquina CON internet
.\bin\env\Import-Env.bat -Path D:\usb\entorno.zip       En la maquina SIN internet
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

## Reproducir un entorno: `Restore-Env` y `devenv.json`

```powershell
.\bin\env\Restore-Env.bat -Save     Escribe devenv.json con lo que YA tienes instalado
.\bin\env\Restore-Env.bat -WhatIf   Ensena que haria
.\bin\env\Restore-Env.bat           Instala todo lo que pide el manifiesto
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
        Vuelve a atarlo con:  .\bin\setup\Setup-MavenEnv.bat -JavaVersion 21
```

### `devenv.lock.json`: que dos maquinas monten LO MISMO

El manifiesto dice `"python": "3.12"`. Eso es una **linea**, no una version: hoy
instala 3.12.10 y dentro de un mes 3.12.11. Dos maquinas que restauren el mismo
`devenv.json` con semanas de diferencia acaban con parches distintos.

El lock cierra esa puerta, igual que un `package-lock.json`:

```powershell
.\bin\env\Restore-Env.bat -Lock      Escribe devenv.lock.json con las versiones exactas
.\bin\env\Restore-Env.bat            Si hay lock, MANDA el lock
.\bin\env\Restore-Env.bat -NoLock    Ignora el lock a proposito
```

Comprobado: con un lock que pedia `3.12.9` y un manifiesto que pedia `3.12`,
restauro **3.12.9** y no el 3.12.10 disponible.

**Los nueve se fijan.** Durante un tiempo solo cinco: Java y Angular recibian la
version como entero, .NET solo aceptaba canal y VS Code no tenia parametro. Ahora
los cuatro admiten **la linea o la version exacta en el mismo parametro**:

```powershell
.\bin\setup\Setup-JavaEnv.bat   -JavaVersion 21                 la linea
.\bin\setup\Setup-JavaEnv.bat   -JavaVersion jdk-21.0.9+10      ese release exacto
.\bin\setup\Setup-AngularEnv.bat -AngularVersion 20.3.35        ese CLI exacto
.\bin\setup\Setup-DotnetEnv.bat -Channel 10.0.400               ese SDK exacto
.\bin\setup\Setup-VSCodeEnv.bat -VSCodeVersion 1.135.0          esa version exacta
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
