# Trabajar en el kit

Las pruebas, el CI y como anadir un runtime nuevo.

> Parte de la documentacion de **CriisDevKit**. Vuelta al [README](../README.md).

## Pruebas

```powershell
.\bin\kit\Run-Tests.bat                    Todas
.\bin\kit\Run-Tests.bat -Name UserPath     Solo un archivo
.\bin\kit\Run-Tests.bat -Quiet             Solo el resumen
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
| `Android.Tests.ps1` | Leer el indice del SDK de Google (y descartar lo de desarrollo, las `-rc`, las `-ext` y las beta), dejar el `package.xml` que dejaria `sdkmanager`, la aceptacion de la licencia solo si su texto es el fijado, el telefono virtual ligero, y la seccion de Android de `Doctor` |
| `Arch.Tests.ps1` | x64 y arm64: como llama cada fuente a cada arquitectura, y que ningun patron se quede en x64 |
| `Catalog.Tests.ps1` | El catalogo, `devenv.json` y el lockfile, y que ningun comando se quede sin un runtime |
| `CorpNet.Tests.ps1` | Lo que se escribe en la configuracion del usuario: el `settings.xml` de Maven, el `pip.ini`, el PEM de la CA |
| `Doctor.Tests.ps1` | La tuberia de `-Json`, que la red se compruebe a la vez (y en orden), y leer la version de `ng` y `npm` sin ejecutarlos |
| `Documentacion.Tests.ps1` | Que la documentacion no contradiga al codigo: version, opciones del menu, cuenta de comandos y enlaces |
| `Download.Tests.ps1` | El diagnostico de un 407, los cuatro estados de la firma Authenticode, y descargas de verdad contra un servidor local que se corta, ignora `Range`, cambia el archivo o hace de proxy con clave; y la cache |
| `InstallNoAdmin.Tests.ps1` | El ambito de una instalacion y si de verdad se evito el admin |
| `Installers.Tests.ps1` | Leer un `.exe` (32, 64 bits y arm64), abrir un bundle Burn con la firma original en medio, sacar los archivos de un MSI sin msiexec, y sacar un zip sin salirse de la carpeta ni dejarla a medias |
| `KitUpdate.Tests.ps1` | Poner una version nueva del kit sin tocar lo del usuario, dejar pendientes los `.bat` en marcha, volver atras, y que el zip que publica el CI sea el que busca `Update-Kit` |
| `Project.Tests.ps1` | Que pide un proyecto: la linea de Python de un `requires-python`, las dependencias de `pyproject.toml` (con corchetes dentro), el JDK de un `pom.xml` y un `.venv` roto |
| `PaqueteAndroid.Tests.ps1` | Que el zip de Android para repartir (`tools\Build-PaqueteAndroid.ps1`) se genere, arranque y lleve solo lo de Android: ni Doctor, ni Update-Kit, ni las demas librerias enteras, ni el menu del kit |
| `Proxy.Tests.ps1` | Enmascarado de la clave, reglas de espejo y la URL del proxy |
| `Referencias.Tests.ps1` | Que ningun archivo mencione un comando que no esta donde dice |
| `Runtimes.Tests.ps1` | Resolver la version de Git y de los JDK, y el shell por cada JDK |
| `Semver.Tests.ps1` | `Test-SemverRange` contra los `engines` reales del CLI |
| `Shells.Tests.ps1` | Que el `.bat` generado **funciona al ejecutarlo en cmd**, incluso con una ruta hostil, y que `Use-Env` recupera de el la ruta exacta |
| `UpdateEnv.Tests.ps1` | Que el comando que `-Apply` ejecuta sea el mismo que se imprime |
| `UseEnv.Tests.ps1` | Que `Use-Env` no enganche el perfil de PowerShell cuando la politica de ejecucion no lo dejaria cargar |
| `UserPath.Tests.ps1` | `Add-UserPathEntry` y `Remove-UserPathEntry` |
| `VCRuntime.Tests.ps1` | Que version y que DLL de Visual C++ necesita un programa, siguiendo la cadena, y que nunca se pise una de la otra arquitectura (ni las de ARM que trae el redistribuible x64); y por que no arranca un programa (`Doctor-App`) |

Esta tabla la vigila una prueba: un archivo de pruebas que no aparezca aqui pone la
suite en rojo. Se quedo desfasada dos veces antes de que la hubiera.

Ninguna prueba toca el registro, el PATH real ni la red. Las del PATH sustituyen por
mocks sus dos unicas puertas al sistema, `Get-RawUserPath` y `Save-UserPath`.

Los ejecutables, bundles y MSI que necesitan `Installers` y `VCRuntime` se fabrican
en la propia prueba (`New-PeDePrueba` en `tests\Helpers.ps1`, `makecab.exe` y la API
de Windows Installer), en vez de leer los de System32: esos cambian de arquitectura
segun la maquina, y en el runner no hay ningun programa MFC.

Las descargas se prueban contra `Start-ServidorDePrueba`, un servidor HTTP minimo sobre
`TcpListener` (no necesita admin, al reves que `HttpListener`) que se porta mal a
proposito: corta a mitad, cierra sin avisar, ignora `Range`, cambia de ETag o pide
credenciales de proxy. Los zips con nombres que `Compress-Archive` no deja crear
(`..\fuera.txt`) salen de `New-ZipDePrueba`.

### En cada push: un Windows que nadie ha tocado

`.github\workflows\pruebas.yml` corre la suite en `windows-latest` en cada push y en
cada pull request. Lo que aporta no es ejecutar las pruebas -eso ya lo hace
`Run-Tests.bat`- sino **donde** las ejecuta.

La maquina de desarrollo tiene Node, Java, Python y npm instalados de antes. Una
prueba que dependiera sin querer de algo de ahi pasaria siempre en local y fallaria
en cuanto alguien clonara el repositorio; el runner es esa segunda maquina, y no hay
otra forma de tenerla.

De paso comprueba la premisa de la que cuelga todo lo anterior: **que Pester 3.x
venga de fabrica**. Si una imagen de Windows deja de traerlo, el job lo dice con un
aviso en vez de instalarlo sin mas y seguir como si nada, porque eso cambiaria el
argumento de *Por que Pester 3.4*, aqui arriba.

Y antes de las pruebas pasa todos los `.ps1` por el analizador de sintaxis. Las pruebas
cargan `lib\` entera, pero de `scripts\` solo leen el texto de unos cuantos: un error
de sintaxis en un comando poco visitado no lo notaba nadie hasta ejecutarlo.

Lo que el CI **no** da: una prueba que no comprueba nada pasa en verde tambien alli.
Eso solo lo caza romperla a proposito y ver que se pone en rojo.

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

## Publicar una version

```powershell
# 1. Subir $KitVersion en lib\Common.ps1 (y el README, que la prueba lo vigila)
git tag v2.4.0
git push origin v2.4.0
```

La etiqueta dispara `.github\workflows\publicar.yml`, que:

1. comprueba que la etiqueta **es** la version del kit: si no, `Update-Kit`
   rechazaria el zip por decir ser otra;
2. pasa la suite entera: una version publicada la instala `Update-Kit` sin que nadie
   la mire;
3. empaqueta con `git archive` (solo lo del repositorio, con los `.bat` en CRLF) en
   `CriisDevKitPs-X.Y.Z.zip`, y escribe su SHA-256 en `CriisDevKitPs-X.Y.Z.zip.sha256`;
4. crea la release con los dos archivos.

El nombre del zip es un contrato entre el flujo y `Update-Kit`, y hay una prueba
(`KitUpdate.Tests.ps1`) que lee los dos lados.

## Anadir un runtime nuevo

El patron esta pensado para crecer (Java, Go, .NET, Git portable...):

1. Crear `scripts\Setup-<Runtime>Env.ps1`.
2. Empezar con `. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")`.
3. Usar `$WorkspaceRoot` para la carpeta destino, `Invoke-Download` para bajar,
   `Test-ZipIntegrity` antes de extraer y `Add-UserPathEntry` para el PATH.
4. Copiar un `.bat` existente de la raiz y cambiarle el nombre del `.ps1`.
5. Anadir una comprobacion en `lib\Doctor.ps1`, llamarla desde el cuerpo de
   `Doctor-Env.ps1`, y el archivo a la lista `$expected` de `Test-KitIntegrity`.

### Doctor: las comprobaciones en `lib\Doctor.ps1`

`Doctor-Env.ps1` es solo los parametros y el orden en que se comprueba; las casi dos
mil lineas de comprobaciones estan en `lib\Doctor.ps1`. **No lo carga `Common.ps1`**:
solo Doctor y sus pruebas, para que el resto de comandos no paguen lo que no usan.

Antes estaba todo en el script, que al terminar sale con `exit`. Para probar una
funcion habia que sacarla con el analizador de sintaxis (`Get-TextoDeFunciones`); ahora
basta con cargar el archivo. Asi se prueban las comprobaciones de red en paralelo y
la lectura de versiones sin ejecutar `ng`, que bajaron Doctor de 13-17 s a 3-4 s.

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
| `Invoke-Download` | Descarga con proxy, TLS, reintentos, reanudacion, progreso, SHA-256, cache y diagnostico |
| `Expand-ZipArchive` | Saca un zip (unas 3 veces mas rapido que `Expand-Archive`), sin dejar media instalacion si falla |
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
