# Redes corporativas

Proxy, la CA que intercepta TLS, el espejo interno y las firmas.

> Parte de la documentacion de **CriisDevKit**. Vuelta al [README](../README.md).

## La CA de tu empresa dentro de los JDK

```powershell
.\bin\env\Use-CorpCert.bat -WhatIf                 Ensena que haria
.\bin\env\Use-CorpCert.bat                         La busca sola y la aplica
.\bin\env\Use-CorpCert.bat -Cert C:\ca.cer         Si te la dio IT en un archivo
.\bin\env\Use-CorpCert.bat -Remove                 La retira
```

Muchas redes corporativas abren el HTTPS para inspeccionarlo: el trafico llega
firmado por una CA de la empresa y no por la del sitio real. Windows lo acepta
porque IT metio esa CA en el almacen del sistema, y por eso el navegador y
PowerShell funcionan.

**Java no usa ese almacen.** Tiene el suyo, `lib\security\cacerts`, con unas 118 CA
publicas de fabrica, y la de tu empresa no esta. El resultado es el peor de los
casos para diagnosticar: el kit descarga el JDK sin problema -PowerShell si confia-
y el primer `mvn install` falla con

```
PKIX path building failed: unable to find valid certification path to requested target
```

que no menciona ni el proxy, ni la empresa, ni el certificado que falta.

Arreglar el `cacerts` **arregla Maven, Gradle y cualquier herramienta Java a la vez**,
porque todas van por ahi. Y no pide admin: ese archivo esta dentro de la carpeta del
JDK, que la puso el propio usuario.

Y no solo Java: **cada herramienta lo resuelve en un sitio distinto**, que es la
razon de que haga falta un comando y no baste con una variable de entorno.

| Herramienta | Que se le pone | Donde | Por que ahi |
|---|---|---|---|
| Java, Maven, Gradle | la CA | `<jdk>\lib\security\cacerts` | Java tiene su propio almacen; Maven y Gradle corren sobre el |
| Node, npm, Angular | la CA | `NODE_EXTRA_CA_CERTS` en su shell | Node lleva su lista compilada dentro; es la unica forma de anadirle una |
| Python, pip | la CA | `pip.ini` de esa instalacion | el del usuario (`%APPDATA%\pip`) vale para todos sus Python y no es del kit |
| Git | la CA | `etc\gitconfig` de ese Git | es su nivel *system*; el `~\.gitconfig` es personal |
| Maven | el **proxy** | `conf\settings.xml` de ese Maven | no lee `HTTP_PROXY`; el `~\.m2\settings.xml` suele tener tus credenciales |
| Gradle | el **proxy** | `GRADLE_OPTS` en su shell | tampoco lo lee; la JVM solo mira sus propiedades de sistema |
| .NET | nada | -- | usa el almacen de Windows, que IT ya configuro |

**Nada de eso toca tus archivos personales.** Comprobado: tras aplicarlo,
`~\.gitconfig`, `%APPDATA%\pip\pip.ini` y `~\.m2\settings.xml` siguen byte a byte
como estaban.

El proxy solo se escribe **si lo hay**. npm, pip y git si respetan `HTTPS_PROXY`, asi
que para ellos no hace falta nada; Maven y Gradle son la excepcion.

La CA se guarda en `%LOCALAPPDATA%\CriisDevKit` -en DER para `keytool` y en PEM
para Node, pip y Git- y se **reaplica sola** al instalar cualquiera de esas
herramientas, igual que los shells de Maven o los JDK de VS Code. `Doctor` dice
cuales la tienen y lo repara con `-Fix`.

Comprobado que cada una la lee **de verdad**, no solo que el archivo este escrito:
Node parsea el PEM y lo reconoce como CA, `pip config list` devuelve `global.cert`,
`git config --system` la tiene y `--global` no, y la huella SHA-256 que guarda Java
es identica a la del archivo.

### La CA viaja en el bundle

`Export-Env` la mete en el `.zip` y `Import-Env` la recupera y la aplica sola. El
segundo equipo suele ser de la **misma empresa**, con el mismo proxy inspeccionando,
asi que sin esto habria que volver a pedirsela a IT alli.

No es un secreto -es el certificado publico que la empresa presenta a todo el que
navega- pero identifica a tu empresa, asi que se dice en voz alta al exportar y se
deja fuera con `-SkipCert`:

```
[WARN] CA de la empresa incluida: CN=Proxy Inspector SA, O=Empresa Falsa
[WARN]   Identifica a tu empresa. Para dejarla fuera:  -SkipCert
```

Comprobado el viaje entero: se exporta, se retira de la maquina, se importa, y el
certificado que acaba en el `cacerts` es el mismo de origen por SHA-256.

### Como decide si tu red intercepta

La primera version comparaba las raices entre si: varios dominios sin relacion
firmados por la misma raiz parecia senal de un intermediario. Al probarlo en una red
normal resulto que **`api.adoptium.net` y `registry.npmjs.org` comparten raiz de
verdad** (GlobalSign ECC Root CA R4), asi que esa regla daba falsos positivos por
pura casualidad.

La pregunta buena no es *"se repite la raiz?"* sino **"la conoce Java?"**. Un JDK
trae las CA publicas de fabrica y la de un proxy corporativo no esta ahi por
definicion. Ademas es exactamente la condicion en la que importarla sirve de algo,
que es lo que se quiere decidir.

Comprobado en las dos direcciones: GlobalSign **si** esta entre las 118 del JDK -no
se confunde con una corporativa- y una CA de prueba fabricada al efecto **no**, o sea
que se detectaria.

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
.\bin\kit\Doctor-Env.bat                       Usa el devenv.lock.json de la carpeta actual
.\bin\kit\Doctor-Env.bat -Lock C:\proy\devenv.lock.json
```

Distingue tres casos: **coincide**, **distinto** (y se puede volver con
`Restore-Env`) y **el lock lo pide y no esta instalado**. Sin lock a la vista no dice
nada: no tiene sentido llenar el informe de ruido a quien no usa uno.

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
(ver [portabilidad](portabilidad.md)), y sin proxy el Python recien instalado se quedaba sin pip.

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

El SHA-256 que se anota en `.criisdevkit-sha256` y muestra `Doctor` es
**trazabilidad**: sirve para comparar dos maquinas que dicen tener la misma version y
para detectar que los archivos cambiaron despues de instalarlos.
