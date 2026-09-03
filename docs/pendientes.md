# Pendientes y decisiones

Lo que falta por comprobar y no depende de escribir mas codigo, y las decisiones
que se tomaron a proposito para no volver a discutirlas cada vez.

> Parte de la documentacion de **CriisDevKit**. Vuelta al [README](../README.md).

## Comprobaciones que necesitan otra maquina

La suite cubre lo que se puede comprobar sin salir de un equipo. Estas cuatro no:
necesitan hardware o una red que aqui no hay. Estan **sin verificar**, y eso no es
lo mismo que estar mal.

### 1. El bundle entre dos maquinas fisicas

`Export-Env` mete en el zip rutas absolutas de la maquina de origen, e `Import-Env`
tiene que **regenerar los shells y el PATH con las del destino**. Con un solo equipo
eso no se prueba de verdad: hace falta que el nombre de usuario sea distinto para que
las rutas cambien.

```powershell
.\bin\env\Export-Env.bat -Output D:\usb\entorno.zip    en la maquina CON internet
.\bin\env\Import-Env.bat -Path D:\usb\entorno.zip      en la maquina SIN internet
```

Que comprobar: que llegan los nueve runtimes, que se verifica el SHA-256 de cada
archivo antes de extraerlo, y que los `.bat` generados en destino apuntan a rutas de
destino y no a las del origen.

### 2. NTLM integrado con una cuenta de dominio

Ya esta comprobado el caso de escribir las credenciales **en la URL del proxy**
(`ACME\jperez`). Falta el otro: un equipo **unido al dominio**, donde la identidad de
Windows deberia bastar sin escribir nada.

En un equipo fuera del dominio esa identidad va vacia, SSPI corta el dialogo y .NET
responde "no hay credenciales disponibles en el paquete de seguridad". El kit ya
traduce ese error, pero nadie ha visto todavia el camino bueno.

### 3. VS Code respetando `java.configuration.runtimes`

`Use-VSCodeJava` escribe ese ajuste. Lo que falta es comprobar que **la extension de
Java le hace caso de verdad**: un proyecto que declara Java 21 y otro que declara 25,
compilando cada uno con el suyo en el mismo editor.

Incluye los dos caminos que aqui no se pueden andar: `-InstallExtension` (son cientos
de MB del marketplace, hace falta la red corporativa) y `-Global`, contra el VS Code
instalado en `%APPDATA%\Code`.

### 4. arm64 en una maquina ARM

El kit ya detecta la arquitectura y pide binarios nativos, y esta comprobado que las
URLs que compone **existen**: Java, Node, Python y VS Code responden en arm64, y el
JDK aarch64 pesa 183.8 MB frente a los 195.6 del x64, o sea que es otro binario.

Lo que NO esta comprobado es que un JDK aarch64 descargado por el kit **arranque**, ni
el resto del flujo en Windows on ARM. Git es el unico sin build nativa: se usa el x64
emulado y `Doctor` lo avisa.

Para probar las descargas de una arquitectura sin tener esa maquina:

```powershell
$env:CRIISDEVKIT_ARCH = 'arm64'
```

## Decisiones tomadas

### No hay manifiesto de hashes de lo instalado

`Verify-Env` comprueba la firma Authenticode, que la instalacion este completa y que
la version de dentro sea la que dice la carpeta. Lo que **no** hace es guardar el
SHA-256 de cada archivo al instalar para compararlo despues.

Se estudio y se descarto, y no por lo que costaria mantenerlo: **el kit modifica sus
propias instalaciones a proposito**.

| Que lo modifica | Que carpeta |
|---|---|
| `Use-CorpCert` | el `lib\security\cacerts` **dentro** de cada JDK |
| Abrir VS Code | su `data\`, que es lo que lo hace portable |
| `pip install` | dentro de la carpeta de ese Python |
| `Setup-AngularEnv` | el `npm-global\` de Angular |
| Instalar un JDK nuevo | regenera los shells de Maven y Gradle |

Un manifiesto del arbol completo se pondria rojo **la primera vez que alguien use la
CA de su empresa**, y despues con cada paquete de pip y cada extension. No seria un
fallo suyo: seria contar la verdad sobre carpetas que estan pensadas para cambiar.

Y ese es el dano: un verificador que avisa en falso se acaba ignorando, y se lleva por
delante al que si funciona.

### El hueco de Maven y Gradle, y por que tampoco se tapa (todavia)

Maven y Gradle se lanzan con un `.cmd`, y a un script por lotes no se le aplica
Authenticode: son los dos unicos runtimes donde `Verify-Env` no puede decir nada de
la firma. Se investigo a fondo y **se decidio dejarlo**, pero el trabajo de
averiguarlo esta hecho y vale la pena no repetirlo.

**Lo que ya esta cubierto**, y conviene no olvidarlo antes de preocuparse:

| | |
|---|---|
| Maven | el zip se verifica contra su `.sha512` oficial (`Get-MavenRelease`) |
| Gradle | contra el `checksumUrl` de su API (`Get-GradleRelease`) |

O sea que "de donde vino el zip" esta resuelto. El hueco es solo lo que pase
**despues** de instalar.

**Que se podria tocar sin que nadie se entere**, de peor a menos malo:

- `bin\mvn.cmd` y `bin\gradle.bat`: texto plano, y se ejecuta en cada compilacion.
- Los `.jar` de `lib\`: el codigo real, mas dificil de manipular y de notar.

**Por que aqui SI seria viable un manifiesto**, al reves que en el resto del kit:
los shells que genera el kit van a la RAIZ de la carpeta del runtime
(`Join-Path $ToolPath $nombre`, en `Write-BuildToolShell`), no dentro de `bin\`. De
`bin\` el kit solo lee, para componer el PATH. **`bin\` y `lib\` no cambian nunca
despues de instalar**, asi que hashearlos no puede dar falsas alarmas, que es
justo lo que hunde la idea en Java, Python y VS Code.

Con eso la cadena quedaria entera: zip verificado contra la fuente oficial, hash de
lo extraido, y comparacion en cada `Verify-Env`. Lo suyo seria `bin\` **y** `lib\`:
la diferencia de coste son un par de segundos, y cubrir solo el lanzador deja una
asimetria rara de explicar. El unico riesgo de mantenimiento es que `-Force` tiene
que REGENERAR el manifiesto; si no, reinstalar Maven deja a `Verify-Env` gritando
contra el manifiesto viejo, que es el fallo que se queria evitar.

**Y aun asi no se hace**, por tres razones:

1. **El atacante no existe.** Lo que tenga permiso para editar `mvn.cmd` en tu perfil
   tiene puertas mejores y ya abiertas: el perfil de PowerShell, la clave `AutoRun`
   de cmd -que usa el propio `Use-Env`-, la carpeta de Inicio, las tareas
   programadas. Blindar una mientras siguen abiertas doce no es seguridad: es la
   apariencia de seguridad, que es peor porque tranquiliza.
2. **Lo que si pasa ya esta cubierto.** En estas maquinas lo que falla no es la
   manipulacion, es un zip a medias, un antivirus que se lleva un archivo o un proxy
   que corrompe la descarga. `Verify-Env` ya lo caza, y los checksums lo cazan antes.
3. **Va contra la disciplina del kit.** Casi cada prueba de aqui cubre un fallo que
   existio de verdad. Esta seria la primera escrita contra una hipotesis, teniendo
   sin verificar las cuatro cosas de arriba, donde el kit podria estar roto ahora.

**Cuando rehacer esta decision**, sin volver a investigar nada: si alguien pide
demostrar que un entorno no se ha tocado (auditoria, seguridad corporativa), o si
aparece un incidente real de binarios manipulados. Ahi deja de ser hipotesis, el
diseno ya esta arriba y la pieza de partida existe: `Get-InstalledRuntimeSha256`,
que Python ya usa para anotar el suyo.

Lo mismo justificaria el manifiesto general: un binario cambiado que siga estando
firmado es lo unico que Authenticode no ve.
