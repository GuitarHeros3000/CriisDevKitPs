# Dev Environment (Sin Permisos de Administrador)

[![Pruebas](https://github.com/GuitarHeros3000/CriisDevKitPs/actions/workflows/pruebas.yml/badge.svg)](https://github.com/GuitarHeros3000/CriisDevKitPs/actions/workflows/pruebas.yml)

Configura entornos de desarrollo en laptops corporativas sin permisos de administrador.

## Documentacion

Esta pagina es la puerta de entrada: que es el kit, donde deja las cosas y como
empezar. Lo demas esta separado por temas, porque en un solo archivo de 90 KB ya no
lo encontraba nadie -y se desfasaba sin que se notara.

| | |
|---|---|
| [Los runtimes, uno a uno](docs/runtimes.md) | Angular, Python, Java, Git, Maven, Gradle, .NET y VS Code: como se instala cada uno, que version elige y con que se abre |
| [Mantener el entorno](docs/mantenimiento.md) | `Doctor`, `Verify-Env`, `Update-Env`, desinstalar, el registro, y que version responde cuando hay varias |
| [Redes corporativas](docs/red-corporativa.md) | Proxy, NTLM, la CA que intercepta TLS, el espejo interno y las firmas Authenticode |
| [Llevarse el entorno](docs/portabilidad.md) | El bundle para una maquina sin internet, y reproducir un entorno con `devenv.json` |
| [Install-NoAdmin](docs/install-noadmin.md) | Instalar software de terceros en modo portable |
| [Trabajar en el kit](docs/desarrollo.md) | Las pruebas, el CI y como anadir un runtime nuevo |

## Por donde entrar: `Menu.bat`

El kit tiene 30 comandos y nadie se los sabe de memoria. `Menu.bat` los reune en una
pantalla que ademas responde la pregunta con la que uno llega: **que hay instalado**.

```
  ============================================================
   CriisDevKit v2.1.0   -   entornos de desarrollo sin admin
  ============================================================

   Instalado: python 3.12

     0  Empezar en un equipo nuevo

   INSTALAR
     1  Python     [3.12]          6  Maven
     2  Java                       7  Gradle
     3  Node                       8  .NET SDK
     4  Angular                    9  VS Code
     5  Git

   ABRIR
    20  Abrir un shell
    21  Activar en toda terminal
    22  Desactivar todo (Use-Env)
    23  Dar los JDK a VS Code
    24  CA de la empresa en Java

   MANTENER
    30  Diagnostico
    31  Diagnostico y reparar
    32  Informe para un ticket
    33  Ver actualizaciones
    34  Desinstalar
    35  Verificar lo instalado
    36  Aplicar actualizaciones

   ENTORNO
    40  Reproducir un devenv.json
    41  Guardar devenv.json
    42  Fijar versiones (lock)
    43  Llevar a otra maquina
    44  Traer de otra maquina

   OTROS
    50  Instalar software sin admin
    51  Pruebas del kit

    q  Salir
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
CriisDevKitPs/
├── Empezar.bat               Empieza por aqui en un equipo nuevo
├── Menu.bat                  Todo lo que sabe hacer el kit
├── bin/                      Los 30 comandos, agrupados igual que scripts/
│   ├── setup/                Setup-*.bat   instalar un runtime
│   ├── start/                Start-*.bat   abrir su shell
│   ├── env/                  Export, Import, Restore, Uninstall, Update,
│   │                         Use-Env, Use-CorpCert, Use-VSCodeJava, Verify-Env
│   └── kit/                  Doctor-Env, Install-NoAdmin, Run-Tests
├── lib/                     La libreria, un archivo por responsabilidad
│   ├── Common.ps1           Rutas base y carga de los demas (es el unico que
│   │                        cargan los scripts; los otros salen de aqui)
│   ├── Log.ps1              Registro en archivo y en consola
│   ├── Arch.ps1             x64 o arm64, y como lo llama cada fuente
│   ├── Proxy.ps1            Proxy corporativo y espejo interno
│   ├── Download.ps1         Descargas, checksums, firmas, reintentos
│   ├── Semver.ps1           Rangos de version de npm
│   ├── Shells.ps1           Los .bat que genera el kit
│   ├── Tools.ps1            7z, innoextract, Node
│   ├── Runtimes.ps1         Git, Maven, Gradle, .NET, VS Code
│   ├── CorpNet.ps1          La CA de la empresa y el proxy por herramienta
│   ├── VSCode.ps1           Ajustes, extensiones y los JDK que conoce
│   ├── Catalog.ps1          Catalogo, devenv.json y lockfile
│   └── UserPath.ps1         PATH de usuario
├── sources.json.ejemplo         Espejo interno (opcional)
├── devenv.json.ejemplo          Manifiesto de entorno (para tus proyectos)
├── scripts/                  La implementacion, agrupada por lo que hace
│   ├── setup/                Setup-*.ps1   instalar un runtime
│   ├── start/                Start-*.ps1   abrir su shell
│   ├── env/                  Export, Import, Restore, Uninstall, Update,
│   │                         Use-Env, Use-CorpCert, Use-VSCodeJava, Verify-Env
│   └── kit/                  Empezar, Menu, Doctor-Env, Install-NoAdmin,
│                             Run-Tests
├── docs/                     La documentacion por temas (ver el indice arriba)
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

### x64 y arm64

Los portatiles corporativos ya llegan con Windows on ARM, asi que el kit detecta la
arquitectura y **descarga el binario nativo**. No hay nada que configurar.

| Runtime | arm64 |
|---|---|
| Java, Node, Angular, Python, .NET, VS Code | nativo |
| Maven, Gradle | Java puro: el mismo zip vale para las dos |
| **Git** | **no hay build arm64; se usa el x64 emulado** |

Git for Windows no publica un PortableGit para arm64. En una maquina ARM se coge el
x64 y Windows lo emula: funciona, y para Git -procesos cortos- no se nota. `Doctor`
lo dice en vez de callarlo, porque quien mida rendimiento tiene derecho a saber cual
de sus runtimes no es nativo.

La arquitectura se detecta con `OSArchitecture` y **no** con `PROCESSOR_ARCHITECTURE`.
Esa variable la lee el PROCESO, y en Windows on ARM un PowerShell x64 emulado responde
`AMD64`: preguntando asi, el kit se bajaria binarios x64 en una maquina ARM y nadie
sabria por que va lento.

```powershell
$env:CRIISDEVKIT_ARCH = 'arm64'    # forzarla
```

Sirve para dos cosas: probar las descargas de una arquitectura sin tener esa maquina
delante, y bajarse los x64 a proposito en una ARM si algo fallara. `Doctor` avisa
cuando esta forzada, para que nadie diagnostique a ciegas.

**Cada fuente llama a las arquitecturas como le da la gana**, y equivocarse da un 404
que no explica nada. Los nombres estan en un solo sitio (`lib\Arch.ps1`) y
comprobados contra las APIs reales; los dos raros son `Adoptium: aarch64` (no
`arm64`) y `python.org: amd64` (no `x64`).

Los `.bat` de la raiz son la interfaz publica: siempre se ejecutan desde ahi.
La logica vive en `scripts\`, y lo compartido en `lib\Common.ps1`.

## Donde se instala todo

El kit nunca instala dentro de si mismo. Crea carpetas **hermanas**:

```
Proyectos Individuales/
├── CriisDevKitPs/       (este kit)
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
.\bin\setup\Setup-JavaEnv.bat -JavaVersion 21 -WhatIf
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
1. .\bin\kit\Doctor-Env.bat                          Ver como esta la maquina
2. .\bin\setup\Setup-PythonEnv.bat -PythonVersion 3.12 Instalar lo que necesites
3. .\bin\kit\Doctor-Env.bat                          Comprobar quien responde
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
- **`Use-Env.bat`** — hace que gane tambien en terminales normales. Ver [que version responde cuando hay varias](docs/mantenimiento.md#que-version-responde-cuando-hay-varias).

### Desinstalar

```
1. .\bin\env\Use-Env.bat -Off                        Si lo habias activado
2. .\bin\env\Uninstall-Env.bat -Runtime Python -All  Retira carpetas y limpia el PATH
```

## Empezar en un equipo nuevo

```powershell
.\Empezar.bat
```

Los comandos ya estaban todos y `Doctor` ya te decia cual falta en cada caso. Lo que
no habia era el **orden**, y en un portatil recien formateado eso es justo lo que no
se sabe. Esto no instala nada por su cuenta: llama a los mismos `.bat` de siempre, en
la secuencia que tiene sentido, preguntando antes de cada paso y dejando saltar
cualquiera.

```
1. Como esta tu red        proxy, e interceptacion TLS
2. La CA de tu empresa     solo si la red la necesita
3. Las herramientas        desde tu devenv.json, o desde el menu
4. VS Code                 que conozca los JDK
5. Lo que el equipo tapa   explica Use-Env, sin activarlo
6. Como ha quedado         Doctor
```

El paso 5 **no hace nada**: solo explica que `Use-Env` es lo unico que sale de las
carpetas del kit, y deja que sea Doctor quien diga si de verdad hace falta. Activarlo
sigue siendo una decision aparte y explicita.

## Solucion de problemas

**Empieza siempre por aqui:**
```powershell
.\bin\kit\Doctor-Env.bat
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
`%LOCALAPPDATA%\CriisDevKit\path-backups\`.

**Laptop sin permisos de admin:**
- Todo funciona en carpetas de usuario
- Los shells .bat funcionan sin restricciones de PowerShell

