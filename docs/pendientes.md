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

**Si algun dia hace falta**, el hueco real es pequeno y esta identificado: Maven y
Gradle se lanzan con un `.cmd` sin firma, asi que son los unicos donde Authenticode no
llega. Eso se cierra con algo bastante menor que un manifiesto. Y la pieza de partida
ya existe: `Get-InstalledRuntimeSha256`, que Python ya usa para anotar el suyo.

Lo que si justificaria el manifiesto entero es otra cosa: tener que **demostrarle a
seguridad** que un entorno no se ha tocado, o preocuparse por un binario cambiado que
siga estando firmado, que es lo unico que Authenticode no ve.
