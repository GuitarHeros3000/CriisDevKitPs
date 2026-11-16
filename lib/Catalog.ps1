#Requires -Version 5.1
<#
    Catalogo de runtimes, devenv.json y lockfile

    Parte de lib\Common.ps1, que es quien carga este archivo. No se toma
    por separado: los scripts siguen haciendo un unico dot-source de
    Common.ps1 y no se enteran de esta division.
#>

# --------------------------------------------------------------------------
# Catalogo de runtimes
#
# Un solo sitio que sepa, para cada runtime: como se llama en un devenv.json,
# que script lo instala, con que parametro se le pasa la version, donde
# aterriza y como se llama su carpeta. Antes cada comando llevaba su propia
# lista y cada runtime nuevo obligaba a tocarlas todas.
# --------------------------------------------------------------------------

function Resolve-KitCommand {
    <#
        Donde vive un comando del kit (.bat), buscandolo por su nombre.

        Lo mismo que Resolve-KitScript pero para la capa de arriba: los comandos
        estan en bin\, repartidos en las mismas cuatro subcarpetas que scripts\,
        y solo Empezar.bat y Menu.bat se quedaron en la raiz.

        El menu los nombraba a secas y los componia contra la raiz, asi que al
        moverlos se quedo diciendo "Falta Doctor-Env.bat en el kit". Con esto,
        moverlos otra vez no rompe a nadie.

        Devuelve $null si no existe.
    #>
    param([Parameter(Mandatory=$true)][string]$Nombre)

    $bin = Join-Path $DevKitRoot "bin"
    $candidatos = @($DevKitRoot, $bin)
    foreach ($sub in @('setup', 'start', 'env', 'kit')) {
        $candidatos += (Join-Path $bin $sub)
    }

    foreach ($d in $candidatos) {
        $p = Join-Path $d $Nombre
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Resolve-KitScript {
    <#
        Donde vive un script del kit, buscandolo por su nombre.

        Existe para que nadie tenga que saber en que subcarpeta de scripts\ esta.
        El catalogo guarda "Setup-JavaEnv.ps1" a secas, y Restore-Env, Doctor y
        las pruebas lo resolvian cada uno por su cuenta pegando "scripts\"
        delante. Con eso, mover un script de carpeta rompia tres sitios a la vez
        y ninguno se enteraba hasta ejecutarlo.

        Ahora hay un unico punto que lo sabe, y mover un script entre setup\,
        start\, env\ y kit\ no obliga a tocar a nadie mas.

        Devuelve $null si no existe, que es lo que deja a quien llama decidir si
        eso es un error o no.
    #>
    param([Parameter(Mandatory=$true)][string]$Nombre)

    $raiz = Join-Path $DevKitRoot "scripts"
    if (-not (Test-Path -LiteralPath $raiz)) { return $null }

    # Primero donde toca por convencion, y solo si no esta se recorre el resto:
    # asi el caso normal no depende de listar carpetas.
    foreach ($sub in @('setup', 'start', 'env', 'kit')) {
        $p = Join-Path (Join-Path $raiz $sub) $Nombre
        if (Test-Path -LiteralPath $p) { return $p }
    }

    $hallado = @(Get-ChildItem -LiteralPath $raiz -Filter $Nombre -File -Recurse -ErrorAction SilentlyContinue)
    if ($hallado.Count -gt 0) { return $hallado[0].FullName }
    return $null
}

function Get-RuntimeCatalog {
    <#
        Fijable indica si el Setup de ese runtime acepta una version EXACTA o
        solo su linea. Es lo que decide hasta donde puede fijar un lockfile, y
        no es una eleccion nuestra sino una limitacion de cada script:

          python, node, git, maven, gradle   admiten X.Y.Z  -> exacto
          java, angular                      -Version es un entero: solo la mayor
          dotnet                             -Channel: solo el canal
          vscode                             no tiene parametro: siempre la ultima
    #>
    return @(
        [PSCustomObject]@{
            Clave = 'python'; Nombre = 'Python'; Script = 'Setup-PythonEnv.ps1'
            ParamVersion = 'PythonVersion'; ParamPaquetes = 'InstallPackages'
            Carpeta = 'Python'; Patron = '^python-(\d+\.\d+)$'; AdmiteForce = $true
            ExeFirma = 'python.exe';   FirmanteEsperado = 'Python Software Foundation'
            Bundle = $false
            Fijable = $true
        }
        [PSCustomObject]@{
            Clave = 'java'; Nombre = 'Java'; Script = 'Setup-JavaEnv.ps1'
            ParamVersion = 'JavaVersion'; ParamPaquetes = $null
            Carpeta = 'Java'; Patron = '^jdk-(\d+)$'; AdmiteForce = $true
            # Temurin ha firmado con dos nombres distintos segun la epoca: el
            # JDK 25 sale como "Eclipse Foundation" y el 21 como "Eclipse.org
            # Foundation, Inc.". Por eso el firmante esperado admite varias
            # formas: con una sola, un JDK legitimo se marcaba como suplantado.
            ExeFirma = 'bin\java.exe'; FirmanteEsperado = @('Eclipse Foundation', 'Eclipse.org Foundation')
            Bundle = $false
            Fijable = $true
        }
        [PSCustomObject]@{
            Clave = 'node'; Nombre = 'Node'; Script = 'Setup-NodeEnv.ps1'
            ParamVersion = 'NodeVersion'; ParamPaquetes = $null
            Carpeta = 'Node'; Patron = '^node-(\d+)$'; AdmiteForce = $true
            ExeFirma = 'node.exe';     FirmanteEsperado = 'OpenJS Foundation'
            Bundle = $true; Envoltorio = $true;  Sfx = $false
            Fijable = $true
        }
        [PSCustomObject]@{
            Clave = 'angular'; Nombre = 'Angular'; Script = 'Setup-AngularEnv.ps1'
            ParamVersion = 'AngularVersion'; ParamPaquetes = $null
            Carpeta = 'Angular'; Patron = '^angular-v(\d+)$'; AdmiteForce = $false
            ExeFirma = $null;           FirmanteEsperado = $null
            Bundle = $false
            Fijable = $true
        }
        [PSCustomObject]@{
            Clave = 'git'; Nombre = 'Git'; Script = 'Setup-GitEnv.ps1'
            ParamVersion = 'GitVersion'; ParamPaquetes = $null
            Carpeta = 'Git'; Patron = '^git-(\d+\.\d+)$'; AdmiteForce = $true
            ExeFirma = 'cmd\git.exe';  FirmanteEsperado = 'Johannes Schindelin'
            Bundle = $true; Envoltorio = $false; Sfx = $true
            Fijable = $true
        }
        [PSCustomObject]@{
            Clave = 'maven'; Nombre = 'Maven'; Script = 'Setup-MavenEnv.ps1'
            ParamVersion = 'MavenVersion'; ParamPaquetes = $null; ParamJava = 'JavaVersion'
            Carpeta = 'Maven'; Patron = '^maven-(\d+\.\d+)$'; AdmiteForce = $true
            ExeFirma = $null;           FirmanteEsperado = $null
            Bundle = $true; Envoltorio = $true;  Sfx = $false
            Fijable = $true
        }
        [PSCustomObject]@{
            Clave = 'gradle'; Nombre = 'Gradle'; Script = 'Setup-GradleEnv.ps1'
            ParamVersion = 'GradleVersion'; ParamPaquetes = $null; ParamJava = 'JavaVersion'
            Carpeta = 'Gradle'; Patron = '^gradle-(\d+\.\d+)$'; AdmiteForce = $true
            ExeFirma = $null;           FirmanteEsperado = $null
            Bundle = $true; Envoltorio = $true;  Sfx = $false
            Fijable = $true
        }
        [PSCustomObject]@{
            Clave = 'dotnet'; Nombre = '.NET SDK'; Script = 'Setup-DotnetEnv.ps1'
            ParamVersion = 'Channel'; ParamPaquetes = $null
            Carpeta = 'Dotnet'; Patron = '^dotnet-(\d+\.\d+)$'; AdmiteForce = $true
            ExeFirma = 'dotnet.exe';   FirmanteEsperado = '.NET'
            Bundle = $true; Envoltorio = $false; Sfx = $false
            Fijable = $true
        }
        [PSCustomObject]@{
            Clave = 'vscode'; Nombre = 'VS Code'; Script = 'Setup-VSCodeEnv.ps1'
            ParamVersion = 'VSCodeVersion'; ParamPaquetes = $null
            Carpeta = 'VSCode'; Patron = '^vscode-(\d+\.\d+)$'; AdmiteForce = $true
            ExeFirma = 'Code.exe';     FirmanteEsperado = 'Microsoft Corporation'
            Bundle = $true; Envoltorio = $false; Sfx = $false
            Fijable = $true
        }
    )
}

function Get-BundleArchiveInfo {
    <#
    .SYNOPSIS
        El archivo original de un runtime: URL, nombre y checksum si lo hay.
    .DESCRIPTION
        Lo usa Export-Env para meter en el bundle lo mismo que descargaria el
        Setup, de modo que en destino se instale sin red. Los setups borran el
        archivo tras extraerlo, asi que hay que volver a pedirlo.

        Angular, Python y Java NO pasan por aqui: tienen en Export-Env un
        tratamiento propio porque llevan ademas el arbol de npm-global y las
        ruedas de pip.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Clave,
        [Parameter(Mandatory=$true)][string]$Version
    )

    switch ($Clave) {
        'node' {
            $a = Get-NodeArchiveInfo -Version $Version
            return [PSCustomObject]@{
                Url = $a.Url; FileName = $a.FileName
                Sha256 = (Get-Sha256FromShasums -Uri $a.ShasumsUrl -FileName $a.FileName)
            }
        }
        'git' {
            $r = Get-GitPortableRelease -Version $Version
            if (-not $r) { return $null }
            return [PSCustomObject]@{ Url = $r.Url; FileName = $r.FileName; Sha256 = $r.Sha256 }
        }
        'maven' {
            $r = Get-MavenRelease -Version $Version
            if (-not $r) { return $null }
            return [PSCustomObject]@{ Url = $r.Url; FileName = $r.FileName; Sha512 = $r.Sha512 }
        }
        'gradle' {
            $r = Get-GradleRelease -Version $Version
            if (-not $r) { return $null }
            return [PSCustomObject]@{ Url = $r.Url; FileName = $r.FileName; Sha256 = $r.Sha256 }
        }
        'dotnet' {
            # El SDK tiene URL predecible. Se comprobo con dotnet-install
            # -DryRun, que imprime exactamente esta.
            return [PSCustomObject]@{
                Url      = "https://builds.dotnet.microsoft.com/dotnet/Sdk/$Version/dotnet-sdk-$Version-win-$(Get-ArchToken -Fuente dotnet).zip"
                FileName = "dotnet-sdk-$Version-win-$(Get-ArchToken -Fuente dotnet).zip"
                Sha256   = $null
            }
        }
        'vscode' {
            # La API de actualizacion solo da la ULTIMA, pero esta otra ruta
            # sirve cualquier version concreta y redirige al zip.
            return [PSCustomObject]@{
                Url      = "https://update.code.visualstudio.com/$Version/win32-$(Get-ArchToken -Fuente vscode)-archive/stable"
                FileName = "VSCode-win32-$(Get-ArchToken -Fuente vscode)-$Version.zip"
                Sha256   = $null
            }
        }
    }
    return $null
}

function Invoke-GitPostInstall {
    <#
        PortableGit trae un post-install.bat que remata la instalacion: crea
        /dev, /etc/mtab y el resto del entorno MSYS que necesita Git Bash. Se
        borra solo al terminar, y esa es la senal de que hizo su trabajo: el
        codigo de salida es 1 aunque vaya bien, porque lo ultimo que ejecuta es
        el DEL de si mismo.

        Se lanza con cmd y el directorio de trabajo puesto. Con el
        "git-bash.exe --command=post-install.bat" que sugiere su cabecera sale
        del paso sin hacer nada.

        Vive aqui y no en Setup-GitEnv porque Import-Env tambien lo necesita:
        un Git sacado del bundle quedaba con Git Bash a medias, y lo detecto
        Doctor avisando de "post-instalacion sin completar".
    #>
    param([Parameter(Mandatory=$true)][string]$GitPath)

    $script = Join-Path $GitPath "post-install.bat"
    if (-not (Test-Path -LiteralPath $script)) { return $true }

    Write-Log "  rematando la instalacion (entorno de Git Bash)..."
    try {
        Start-Process -FilePath "cmd.exe" -ArgumentList @('/c', "`"$script`"") `
                      -WorkingDirectory $GitPath -Wait -WindowStyle Hidden | Out-Null
    }
    catch {
        Write-Log "  no se pudo ejecutar post-install.bat: $($_.Exception.Message)" "WARN"
        return $false
    }

    if (Test-Path -LiteralPath $script) {
        # Git funciona igual; lo que puede quedar a medias es el entorno Unix.
        Write-Log "  post-install.bat no llego a terminar; git funciona, Git Bash puede ir justo" "WARN"
        return $false
    }
    return $true
}

function Expand-BundledRuntime {
    <#
        Coloca el archivo de un runtime en su carpeta definitiva, teniendo en
        cuenta como viene empaquetado cada uno:

          Envoltorio  el zip trae dentro una carpeta (node-vX, apache-maven-X)
                      que hay que renombrar a la del kit
          Plano       el zip vuelca su contenido directamente (dotnet, vscode)
          Sfx         no es un zip sino un autoextraible (PortableGit)
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Archivo,
        [Parameter(Mandatory=$true)][string]$Destino,
        [Parameter(Mandatory=$true)][PSCustomObject]$Entrada
    )

    if ($Entrada.Sfx) {
        $proc = Start-Process -FilePath $Archivo -ArgumentList @("-o`"$Destino`"", '-y') -Wait -PassThru
        return ($proc.ExitCode -eq 0)
    }

    Expand-ZipArchive -Path $Archivo -Destino $Destino -QuitarEnvoltorio:([bool]$Entrada.Envoltorio)
    return $true
}

function Write-RuntimeShell {
    <#
        Regenera el shell de un runtime con las rutas de ESTA maquina. Import-Env
        lo necesita para los seis runtimes que empaqueta: dentro del bundle van
        rutas absolutas del equipo de origen, que aqui no valen.

        Es un despachador y no una funcion nueva: cada Write-*Shell sigue donde
        estaba, aqui solo se elige cual.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Clave,
        [Parameter(Mandatory=$true)][string]$Ruta,
        [Parameter(Mandatory=$true)][string]$Version,
        [string]$Linea
    )

    switch ($Clave) {
        'node'   { return (Write-NodeShell   -NodePath $Ruta -Version $Version) }
        'git'    { return (Write-GitShell    -GitPath  $Ruta -Version $Version) }
        'maven'  { return (Write-BuildToolShell -Tool Maven  -ToolPath $Ruta -Version $Version -JavaHome (Get-KitJavaHome)) }
        'gradle' { return (Write-BuildToolShell -Tool Gradle -ToolPath $Ruta -Version $Version -JavaHome (Get-KitJavaHome)) }
        'dotnet' { return (Write-DotnetShell -DotnetPath $Ruta -Version $Version -Channel $Linea) }
        'vscode' { return (Write-VSCodeShell -VSCodePath $Ruta -Version $Version) }
    }
    return $null
}

function Get-RuntimeFolderName {
    <#
        Como se llama la carpeta de una linea: 21 -> jdk-21, 3.12 -> python-3.12.

        Este switch estaba copiado en tres sitios (aqui, en Doctor y en la
        cabeza de cada comando que compone rutas), y las copias no coincidian:
        la de Doctor no tenia el caso de Angular, asi que componia "angular-20"
        en vez de "angular-v20". No llego a fallar porque Angular no tiene
        binario firmable y esa rama nunca se ejecutaba, pero estaba puesta la
        trampa para el siguiente que la usara.
    #>
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$Entrada,
        [Parameter(Mandatory=$true)][string]$Linea
    )

    switch ($Entrada.Clave) {
        'angular' { return "angular-v$Linea" }
        'java'    { return "jdk-$Linea" }
        'node'    { return "node-$Linea" }
        default   { return "$($Entrada.Clave)-$Linea" }
    }
}

function Get-RuntimeInstallPath {
    <#
        Donde vive una linea instalada. No comprueba que exista: eso lo decide
        quien llama, que muchas veces pregunta justo para saberlo.
    #>
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$Entrada,
        [Parameter(Mandatory=$true)][string]$Linea
    )

    return (Join-Path (Join-Path $WorkspaceRoot $Entrada.Carpeta) (Get-RuntimeFolderName -Entrada $Entrada -Linea $Linea))
}

function Get-InstalledRuntimeVersion {
    <#
    .SYNOPSIS
        La version EXACTA instalada de un runtime, no la linea de su carpeta.
    .DESCRIPTION
        Cada runtime la guarda en un sitio distinto, y hasta ahora esa logica
        estaba repartida entre Doctor, Update-Env y los Start-*. Este es el sitio
        designado para averiguarlo; lo demas deberia acabar leyendo de aqui.

        Se prefiere leer un archivo a ejecutar el binario siempre que se pueda:
        es mas rapido y no depende de que haya variables de entorno puestas.
    #>
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$Entrada,
        [Parameter(Mandatory=$true)][string]$Linea
    )

    $dir = Get-RuntimeInstallPath -Entrada $Entrada -Linea $Linea
    if (-not (Test-Path -LiteralPath $dir)) { return $null }

    switch ($Entrada.Clave) {
        'python' {
            $exe = Join-Path $dir "python.exe"
            if (-not (Test-Path $exe)) { return $null }
            $run = Invoke-NativeCommand -FilePath $exe -Arguments @('-V') -Quiet
            if ($run.Output -match 'Python (\d+\.\d+\.\d+)') { return $Matches[1] }
            return $null
        }
        'java' {
            # El release exacto (jdk-25.0.4.1+1) lo deja Setup-JavaEnv en un
            # marcador, porque el numero de build no sale de java -version.
            $mk = Join-Path $dir ".criisdevkit-release"
            if (Test-Path $mk) { return (Get-Content $mk -Raw).Trim() }
            return (Get-JdkVersionAt -JavaHome $dir)
        }
        'node' {
            $exe = Join-Path $dir "node.exe"
            if (-not (Test-Path $exe)) { return $null }
            $run = Invoke-NativeCommand -FilePath $exe -Arguments @('--version') -Quiet
            if ($run.Output -match 'v?(\d+\.\d+\.\d+)') { return $Matches[1] }
            return $null
        }
        'angular' {
            $pkg = Join-Path $dir "npm-global\node_modules\@angular\cli\package.json"
            if (-not (Test-Path $pkg)) { return $null }
            try { return (Get-Content $pkg -Raw | ConvertFrom-Json).version } catch { return $null }
        }
        'git' {
            $exe = Join-Path $dir "cmd\git.exe"
            if (-not (Test-Path $exe)) { return $null }
            $run = Invoke-NativeCommand -FilePath $exe -Arguments @('--version') -Quiet
            return (ConvertFrom-GitVersionOutput -Output $run.Output)
        }
        'maven' {
            $jar = @(Get-ChildItem -Path (Join-Path $dir "lib\maven-core-*.jar") -ErrorAction SilentlyContinue)
            if ($jar.Count -gt 0 -and $jar[0].Name -match 'maven-core-([\d.]+)\.jar') { return $Matches[1] }
            return $null
        }
        'gradle' {
            $jar = @(Get-ChildItem -Path (Join-Path $dir "lib\gradle-launcher-*.jar") -ErrorAction SilentlyContinue)
            if ($jar.Count -gt 0 -and $jar[0].Name -match 'gradle-launcher-([\d.]+)\.jar') { return $Matches[1] }
            return $null
        }
        'dotnet' {
            $sdks = @(Get-ChildItem -LiteralPath (Join-Path $dir "sdk") -Directory -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -match '^\d+\.\d+\.\d+' })
            if ($sdks.Count -gt 0) { return @($sdks | Sort-Object Name -Descending)[0].Name }
            return $null
        }
        'vscode' {
            $exe = Join-Path $dir "Code.exe"
            if (-not (Test-Path $exe)) { return $null }
            $v = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
            if ($v -match '(\d+\.\d+\.\d+)') { return $Matches[1] }
            return $v
        }
    }
    return $null
}

function Get-InstalledRuntimeSha256 {
    <#
        El SHA-256 del archivo con que se instalo, si el kit lo anoto. Hoy solo
        lo deja Setup-PythonEnv; los demas verifican el checksum al descargar
        pero no lo guardan. Devuelve $null cuando no consta, y quien llama debe
        decirlo en vez de dar a entender que hay una garantia que no hay.
    #>
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$Entrada,
        [Parameter(Mandatory=$true)][string]$Linea
    )

    if ($Entrada.Clave -ne 'python') { return $null }

    $mk = Join-Path (Join-Path $WorkspaceRoot "Python\python-$Linea") ".criisdevkit-sha256"
    if (Test-Path -LiteralPath $mk) { return (Get-Content $mk -Raw).Trim() }
    return $null
}

function Resolve-RuntimeFromPath {
    <#
    .SYNOPSIS
        De una ruta dentro del workspace deduce a que runtime pertenece y de que
        version. Devuelve $null si la ruta no es de ninguno.
    .DESCRIPTION
        Sirve para pasar de "esta carpeta esta tapada en el PATH" a "esto se
        arregla con Use-Env -Runtime Java -Version 25".

        El nombre de carpeta del catalogo coincide con el que espera Use-Env en
        -Runtime, asi que se devuelve tal cual.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $p = $Path.TrimEnd('\')

    foreach ($e in (Get-RuntimeCatalog)) {
        $raiz = (Join-Path $WorkspaceRoot $e.Carpeta).TrimEnd('\')
        if (-not $p.StartsWith($raiz + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }

        # La primera carpeta por debajo de la raiz es la de la version.
        $carpeta = (($p.Substring($raiz.Length).TrimStart('\')) -split '\\')[0]
        if ($carpeta -match $e.Patron) {
            return [PSCustomObject]@{
                Runtime = $e.Carpeta      # es lo que espera Use-Env en -Runtime
                Nombre  = $e.Nombre
                Version = $Matches[1]
            }
        }
    }
    return $null
}

function Get-InstalledRuntimeLines {
    <#
        Devuelve que lineas hay instaladas de un runtime del catalogo, leyendo
        los nombres de carpeta. Es la base de Restore-Env -Save.
    #>
    param([Parameter(Mandatory=$true)][PSCustomObject]$Entrada)

    $raiz = Join-Path $WorkspaceRoot $Entrada.Carpeta
    if (-not (Test-Path -LiteralPath $raiz)) { return @() }

    return @(Get-ChildItem -LiteralPath $raiz -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {
            if ($_.Name -match $Entrada.Patron) { $Matches[1] }
        })
}

function Read-DevEnvManifest {
    <#
    .SYNOPSIS
        Valida un devenv.json ya cargado y devuelve lo que hay que instalar.
    .DESCRIPTION
        Separada de la lectura del archivo para poder probarla. Devuelve un
        objeto con Runtimes (lista ordenada segun el catalogo) y Errores.

        Un runtime desconocido no se ignora en silencio: se devuelve como error.
        Un devenv.json con una errata dejaria el entorno a medias sin decir por
        que, y este comando existe justo para lo contrario.

        El valor de un runtime puede ser una lista: "java": ["21", "25"] instala
        las dos. Hacia falta para describir el caso real de trabajar en proyectos
        con Javas distintos; con un solo valor por runtime, el manifiesto no
        sabia reproducir esa maquina.

        La seccion "java" ata el shell por defecto de Maven o Gradle a un JDK
        concreto: sin ella se quedarian con el mas alto instalado.
    #>
    param([AllowNull()]$Config)

    $errores  = @()
    $avisos   = @()
    $runtimes = @()

    if (-not $Config) {
        return [PSCustomObject]@{ Runtimes = @(); Errores = @('el manifiesto esta vacio o no es JSON valido'); Avisos = @() }
    }

    if ($Config.version -and [int]$Config.version -gt 1) {
        $errores += "el manifiesto declara version $($Config.version) y este kit entiende hasta la 1"
    }

    if (-not $Config.runtimes) {
        $errores += "no hay ninguna seccion 'runtimes'"
        return [PSCustomObject]@{ Runtimes = @(); Errores = $errores; Avisos = $avisos }
    }

    $catalogo = Get-RuntimeCatalog
    $pedidos  = @{}
    foreach ($p in $Config.runtimes.PSObject.Properties) {
        $clave = $p.Name.ToLowerInvariant()
        if (-not ($catalogo | Where-Object { $_.Clave -eq $clave })) {
            $errores += "runtime desconocido: '$($p.Name)'  (conocidos: $(($catalogo.Clave) -join ', '))"
            continue
        }

        # Un valor suelto y una lista se tratan igual a partir de aqui.
        $lista = @(@($p.Value) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                   ForEach-Object { ([string]$_).Trim() })
        if ($lista.Count -eq 0) {
            $errores += "$clave : no dice ninguna version"
            continue
        }

        $repes = @($lista | Group-Object | Where-Object { $_.Count -gt 1 })
        if ($repes.Count -gt 0) {
            $errores += "$clave : la version $($repes[0].Name) esta repetida"
            continue
        }

        $pedidos[$clave] = $lista
    }

    # La seccion java se valida contra lo que se va a instalar: atar Maven a un
    # JDK que el manifiesto no instala fallaria a mitad de la reproduccion, y es
    # justo lo que este validador existe para evitar.
    $ataduras = @{}
    if ($Config.java) {
        foreach ($p in $Config.java.PSObject.Properties) {
            $clave = $p.Name.ToLowerInvariant()
            $e = @($catalogo | Where-Object { $_.Clave -eq $clave })

            if ($e.Count -eq 0) {
                $errores += "seccion 'java': runtime desconocido '$($p.Name)'"
                continue
            }
            if (-not $e[0].ParamJava) {
                $conJava = ($catalogo | Where-Object { $_.ParamJava }).Clave -join ', '
                $errores += "seccion 'java': $clave no elige JDK  (solo lo hacen: $conJava)"
                continue
            }
            if (-not $pedidos.ContainsKey($clave)) {
                $avisos += "seccion 'java': se ata $clave a un JDK pero el manifiesto no instala $clave"
                continue
            }

            $linea = ([string]$p.Value).Trim()
            if ($linea -notmatch '^\d+$') {
                $errores += "seccion 'java': '$linea' no es una linea de JDK (se espera 21, 25...)"
                continue
            }
            if ($pedidos.ContainsKey('java') -and $pedidos['java'] -notcontains $linea) {
                $errores += "seccion 'java': se ata $clave al JDK $linea, que el manifiesto no instala (instala: $($pedidos['java'] -join ', '))"
                continue
            }
            if (-not $pedidos.ContainsKey('java')) {
                $avisos += "seccion 'java': se ata $clave al JDK $linea, que el manifiesto no instala; tendra que estar ya en la maquina"
            }

            $ataduras[$clave] = $linea
        }
    }

    # Se recorre el CATALOGO y no lo pedido, para que el orden de instalacion
    # sea siempre el mismo: Java antes que Maven y Gradle, que lo necesitan.
    foreach ($e in $catalogo) {
        if (-not $pedidos.ContainsKey($e.Clave)) { continue }

        $paquetes = $null
        if ($e.ParamPaquetes -and $Config.paquetes) {
            $prop = $Config.paquetes.PSObject.Properties[$e.Clave]
            if ($prop -and $prop.Value) { $paquetes = @($prop.Value) -join ',' }
        }

        # De menor a mayor: si el Setup ordena el PATH por orden de llegada, la
        # version mas alta acaba delante, que es la que se espera por defecto.
        $ordenadas = @($pedidos[$e.Clave] | Sort-Object {
            try { [version]($_ -replace '^(\d+)$', '$1.0') } catch { [version]'0.0' }
        })

        foreach ($v in $ordenadas) {
            $runtimes += [PSCustomObject]@{
                Clave    = $e.Clave
                Nombre   = $e.Nombre
                Version  = $v
                Paquetes = $paquetes
                Java     = $(if ($ataduras.ContainsKey($e.Clave)) { $ataduras[$e.Clave] } else { $null })
                Entrada  = $e
            }
        }
    }

    return [PSCustomObject]@{ Runtimes = $runtimes; Errores = $errores; Avisos = $avisos }
}

function Read-DevEnvLock {
    <#
    .SYNOPSIS
        Valida un devenv.lock.json ya cargado y devuelve que instalar.
    .DESCRIPTION
        El lockfile es al devenv.json lo que un package-lock.json al package.json:
        el manifiesto dice "Python 3.12", el lock dice "3.12.10". Sirve para que
        dos maquinas monten lo MISMO y no dos parches distintos de la misma linea.

        Cada entrada trae linea y exacta. Se usa la exacta solo si el Setup de
        ese runtime la admite -lo dice Fijable en el catalogo-; si no, se cae a
        la linea y se avisa, porque prometer un pin que no se puede cumplir es
        peor que no tenerlo.

        Un runtime puede traer varias entradas en una lista, igual que en el
        manifiesto: una maquina con dos JDK no se describe con una sola.
    #>
    param([AllowNull()]$Config)

    $errores  = @()
    $runtimes = @()

    if (-not $Config) {
        return [PSCustomObject]@{ Runtimes = @(); Errores = @('el lock esta vacio o no es JSON valido') }
    }
    if ($Config.version -and [int]$Config.version -gt 1) {
        $errores += "el lock declara version $($Config.version) y este kit entiende hasta la 1"
    }
    if (-not $Config.runtimes) {
        $errores += "el lock no tiene seccion 'runtimes'"
        return [PSCustomObject]@{ Runtimes = @(); Errores = $errores }
    }

    $catalogo = Get-RuntimeCatalog
    $pedidos  = @{}
    foreach ($p in $Config.runtimes.PSObject.Properties) {
        $clave = $p.Name.ToLowerInvariant()
        $e = @($catalogo | Where-Object { $_.Clave -eq $clave })
        if ($e.Count -eq 0) {
            $errores += "runtime desconocido en el lock: '$($p.Name)'"
            continue
        }
        # Una entrada suelta y una lista se tratan igual a partir de aqui.
        $pedidos[$clave] = @($p.Value)
    }

    foreach ($e in $catalogo) {
        if (-not $pedidos.ContainsKey($e.Clave)) { continue }

        foreach ($v in $pedidos[$e.Clave]) {
            $linea  = if ($v.linea)  { [string]$v.linea }  else { $null }
            $exacta = if ($v.exacta) { [string]$v.exacta } else { $null }

            if (-not $linea -and -not $exacta) {
                $errores += "$($e.Clave): la entrada del lock no trae ni linea ni exacta"
                continue
            }

            $usar = if ($e.Fijable -and $exacta) { $exacta } else { $linea }
            if (-not $usar) { $usar = $exacta }

            $runtimes += [PSCustomObject]@{
                Clave    = $e.Clave
                Nombre   = $e.Nombre
                Version  = $usar
                Exacta   = $exacta
                Linea    = $linea
                Fijado   = [bool]($e.Fijable -and $exacta)
                Sha256   = if ($v.sha256) { [string]$v.sha256 } else { $null }
                Paquetes = $null
                Java     = $(if ($v.java) { [string]$v.java } else { $null })
                Entrada  = $e
            }
        }
    }

    return [PSCustomObject]@{ Runtimes = $runtimes; Errores = $errores }
}

# --------------------------------------------------------------------------
# Python: python-build-standalone
# --------------------------------------------------------------------------
#
# Antes el kit instalaba el zip "embeddable" de python.org. Es Python, pero
# recortado para ir dentro de otro programa: sin venv, sin tkinter y sin pip.
# "python -m venv" fallaba con "No module named venv", y cualquier proyecto con
# interfaz tkinter no arrancaba.
#
# python-build-standalone (Astral, la gente de uv) publica CPython completo y
# portable: un .tar.gz que se descomprime y funciona, con venv, tkinter, pip y
# sqlite. Lo usan uv y Rye. Comprobado con 3.12.16: venv crea el entorno, y
# tkinter importa tambien DENTRO del venv.
#
# Lo que se pierde: python.exe no va firmado (el de python.org si). Lo que lo
# respalda es el SHA-256 de SHA256SUMS, que se comprueba al descargar y queda
# anotado en la carpeta.
#
# No se usa la API de GitHub para lo normal. Sin autenticar deja 60 consultas
# por hora y por IP, y en una oficina sale todo el mundo por la misma IP. La
# ultima release se saca de la redireccion de releases/latest, y lo que trae,
# de su SHA256SUMS: 140 KB de texto con el nombre y el hash de cada archivo.

$PythonBuildRepo = 'https://github.com/astral-sh/python-build-standalone'
$script:PythonBuildSumsCache = @{}

function ConvertFrom-PythonBuildSums {
    <#
        Del texto de un SHA256SUMS, los Python para Windows de una arquitectura.
        Cada linea es "<hash>  cpython-3.12.16+20261110-x86_64-pc-windows-msvc-
        install_only.tar.gz". Hasta 2024 el nombre llevaba "shared-" delante de
        install_only, y se aceptan los dos para poder buscar versiones viejas.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Texto,
        [ValidateSet('x64', 'arm64')][string]$Arch
    )

    if ([string]::IsNullOrWhiteSpace($Texto)) { return @() }
    if (-not $Arch) { $Arch = Get-KitArchitecture }

    $triple = "$(Get-ArchToken -Fuente pbs -Arch $Arch)-pc-windows-msvc"
    $patron = '^([0-9a-fA-F]{64})\s+\*?(cpython-(\d+)\.(\d+)\.(\d+)((?:a|b|rc)\d+)?\+(\d+)-' +
              [regex]::Escape($triple) + '-(?:shared-)?install_only\.tar\.gz)\s*$'

    $builds = @()
    foreach ($l in ($Texto -split "`r?`n")) {
        $m = [regex]::Match($l.Trim(), $patron)
        if (-not $m.Success) { continue }
        $archivo = $m.Groups[2].Value
        $tag = $m.Groups[7].Value
        $builds += [PSCustomObject]@{
            Version  = "$($m.Groups[3].Value).$($m.Groups[4].Value).$($m.Groups[5].Value)$($m.Groups[6].Value)"
            Linea    = "$($m.Groups[3].Value).$($m.Groups[4].Value)"
            Patch    = [int]$m.Groups[5].Value
            Previa   = [bool]$m.Groups[6].Value
            Tag      = $tag
            FileName = $archivo
            Sha256   = $m.Groups[1].Value.ToLowerInvariant()
            # El + del nombre va escapado, como lo publica GitHub.
            Url      = "$PythonBuildRepo/releases/download/$tag/$($archivo -replace '\+', '%2B')"
        }
    }
    return $builds
}

function Select-PythonBuild {
    <#
        De los Python de una release, el que corresponde a lo pedido:
          "3.12"     la ultima 3.12.x, nunca una alfa, beta o rc
          "3.12.10"  exactamente esa
        Devuelve $null si no esta.
    #>
    param(
        [AllowEmptyCollection()][object[]]$Builds = @(),
        [Parameter(Mandatory=$true)][string]$Requested
    )

    $r = $Requested.Trim()
    if ($r -match '^\d+\.\d+$') {
        return @($Builds | Where-Object { $_.Linea -eq $r -and -not $_.Previa } | Sort-Object Patch -Descending)[0]
    }
    return @($Builds | Where-Object { $_.Version -eq $r })[0]
}

function Get-PythonBuildLatestTag {
    <#
        La ultima release, sin gastar una consulta de la API: github.com
        redirige releases/latest a releases/tag/<fecha>. Si no se puede (un
        espejo que no redirige), se pregunta a la API como ultimo recurso.
    #>
    $uri = Resolve-KitUrl -Uri "$PythonBuildRepo/releases/latest" -Quiet
    $params = @{ Uri = $uri; Method = 'Head'; UseBasicParsing = $true; TimeoutSec = 30 }
    Add-ProxyToRequest -Params $params -Uri ([Uri]$uri)
    try {
        $r = Invoke-WebRequest @params
        $final = [string]$r.BaseResponse.ResponseUri
        if ($final -match '/releases/tag/(\d{8})/?$') { return $Matches[1] }
    }
    catch { }

    $api = Invoke-JsonApi -Uri 'https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest' `
                          -Headers @{ 'User-Agent' = "CriisDevKit/$KitVersion" } -Quiet
    if ($api -and $api.tag_name -match '^\d{8}$') { return $api.tag_name }
    return $null
}

function Get-PythonBuildsOfRelease {
    <# Los Python de Windows de una release, leidos de su SHA256SUMS. Se guarda por ejecucion. #>
    param(
        [Parameter(Mandatory=$true)][string]$Tag,
        [ValidateSet('x64', 'arm64')][string]$Arch
    )
    if (-not $Arch) { $Arch = Get-KitArchitecture }

    if (-not $script:PythonBuildSumsCache.ContainsKey($Tag)) {
        $script:PythonBuildSumsCache[$Tag] = Get-WebText -Uri "$PythonBuildRepo/releases/download/$Tag/SHA256SUMS" -Quiet
    }
    return @(ConvertFrom-PythonBuildSums -Texto $script:PythonBuildSumsCache[$Tag] -Arch $Arch)
}

function Search-OlderPythonBuild {
    <#
    .SYNOPSIS
        Un parche exacto que ya no esta en la ultima release (3.12.10, por ejemplo).
    .DESCRIPTION
        Hace falta para reproducir un lockfile. Cada release trae el ultimo
        parche de cada linea en ese momento, y el parche solo sube con el
        tiempo, asi que se busca por biseccion sobre las releases: unas siete
        lecturas de SHA256SUMS en vez de recorrerlas todas.

        Aqui si se usa la API, solo para la lista de etiquetas (dos consultas).
        Es el caso raro, no el de todos los dias.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Version,
        [ValidateSet('x64', 'arm64')][string]$Arch
    )
    if (-not $Arch) { $Arch = Get-KitArchitecture }
    if ($Version -notmatch '^(\d+)\.(\d+)\.(\d+)$') { return $null }
    $linea = "$($Matches[1]).$($Matches[2])"
    $patch = [int]$Matches[3]

    $tags = @()
    foreach ($pagina in 1, 2) {
        $t = Invoke-JsonApi -Uri "https://api.github.com/repos/astral-sh/python-build-standalone/tags?per_page=100&page=$pagina" `
                            -Headers @{ 'User-Agent' = "CriisDevKit/$KitVersion" } -Quiet
        if (-not $t) { break }
        $tags += @($t | ForEach-Object { $_.name } | Where-Object { $_ -match '^\d{8}$' })
        if (@($t).Count -lt 100) { break }
    }
    $tags = @($tags | Sort-Object -Descending -Unique)

    $lo = 0; $hi = $tags.Count - 1
    while ($lo -le $hi) {
        $mid = [int][Math]::Floor(($lo + $hi) / 2)
        $builds = @(Get-PythonBuildsOfRelease -Tag $tags[$mid] -Arch $Arch)
        $exacta = Select-PythonBuild -Builds $builds -Requested $Version
        if ($exacta) { return $exacta }

        $deLinea = Select-PythonBuild -Builds $builds -Requested $linea
        if ($deLinea) {
            # Indice mas alto = release mas vieja.
            if ($deLinea.Patch -gt $patch) { $lo = $mid + 1 } else { $hi = $mid - 1 }
        }
        else {
            # Sin esa linea: o ya no la publicaban (hay lineas mas nuevas) o
            # aun no existia.
            $mayor = @($builds | Where-Object { [version]$_.Linea -gt [version]$linea }).Count -gt 0
            if ($mayor) { $lo = $mid + 1 } else { $hi = $mid - 1 }
        }
    }
    return $null
}

function Find-PythonBuild {
    <#
    .SYNOPSIS
        El Python que hay que descargar para lo pedido ("3.12" o "3.12.10").
    .DESCRIPTION
        Primero en la ultima release; un parche exacto que ya no este ahi se
        busca hacia atras. Devuelve Version, Linea, Tag, FileName, Url y Sha256,
        o $null si no existe (o no hay red).

        Lo usan Setup-PythonEnv, Update-Env y Export-Env: con copias distintas
        acabarian eligiendo versiones distintas.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Requested,
        [ValidateSet('x64', 'arm64')][string]$Arch
    )
    if (-not $Arch) { $Arch = Get-KitArchitecture }

    $tag = Get-PythonBuildLatestTag
    if (-not $tag) { return $null }

    $b = Select-PythonBuild -Builds @(Get-PythonBuildsOfRelease -Tag $tag -Arch $Arch) -Requested $Requested
    if ($b) { return $b }

    if ($Requested.Trim() -match '^\d+\.\d+\.\d+$') {
        return (Search-OlderPythonBuild -Version $Requested.Trim() -Arch $Arch)
    }
    return $null
}

function Get-PythonArchiveInfo {
    <# El archivo de una version exacta, para Export-Env. $null si no se encuentra. #>
    param([Parameter(Mandatory=$true)][string]$FullVersion)
    return (Find-PythonBuild -Requested $FullVersion)
}

function Get-LatestPythonPatch {
    <# Ultima X.Y.Z de una linea, para Update-Env. $null si no se pudo saber. #>
    param([Parameter(Mandatory=$true)][string]$MinorPrefix)
    return (Find-PythonBuild -Requested $MinorPrefix)
}

function Get-InstalledRuntimeOrigin {
    <#
        De donde salio una instalacion, si el kit lo anoto: hoy solo Python, que
        puede ser el embeddable de python.org (instalaciones viejas) o el de
        python-build-standalone. Importa para la firma: el segundo no firma sus
        binarios, y decir "sin firma, raro" de el seria una falsa alarma.
    #>
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$Entrada,
        [Parameter(Mandatory=$true)][string]$Linea
    )
    $mk = Join-Path (Get-RuntimeInstallPath -Entrada $Entrada -Linea $Linea) ".criisdevkit-origen"
    if (Test-Path -LiteralPath $mk) { return (Get-Content -LiteralPath $mk -Raw).Trim() }
    return $null
}

# --------------------------------------------------------------------------
# Lo que el kit instala fuera del catalogo: VCRuntime\ y Apps\
# --------------------------------------------------------------------------
#
# Install-VCRuntime y Install-NoAdmin dejan carpetas junto al kit igual que los
# Setup, pero no son runtimes: no tienen shell, ni PATH, ni version que
# actualizar. Exportar, verificar y desinstalar las ignoraban, asi que no
# llegaban a un equipo sin internet. Un solo sitio dice que hay en ellas, para
# que los cuatro comandos no acaben contando cosas distintas.

$KitExtraFolders = @('VCRuntime', 'Apps')

function Get-KitExtraItems {
    <#
        Las piezas de una de esas carpetas, cada una con Carpeta (VCRuntime o
        Apps), Item (su ruta relativa: vc-2012\x86, o el nombre de la app) y
        Ruta. En VCRuntime la pieza es cada arquitectura de cada version: es lo
        que se descarga junto, y lo que tiene sentido llevar o quitar.

        -Raiz sustituye a la carpeta de trabajo, para las pruebas.
    #>
    param(
        [Parameter(Mandatory=$true)][ValidateSet('VCRuntime', 'Apps')][string]$Carpeta,
        [string]$Raiz = $WorkspaceRoot
    )

    $base = Join-Path $Raiz $Carpeta
    if (-not (Test-Path -LiteralPath $base)) { return @() }

    $items = @()
    if ($Carpeta -eq 'VCRuntime') {
        foreach ($v in (Get-ChildItem -LiteralPath $base -Directory -Filter 'vc-*' -ErrorAction SilentlyContinue)) {
            foreach ($a in (Get-ChildItem -LiteralPath $v.FullName -Directory -ErrorAction SilentlyContinue)) {
                if ($a.Name -notin @('x86', 'x64')) { continue }
                $items += [PSCustomObject]@{ Carpeta = $Carpeta; Item = "$($v.Name)\$($a.Name)"; Ruta = $a.FullName }
            }
        }
    }
    else {
        foreach ($d in (Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue)) {
            $items += [PSCustomObject]@{ Carpeta = $Carpeta; Item = $d.Name; Ruta = $d.FullName }
        }
    }
    return $items
}

function Get-FolderManifest {
    <#
        Cada archivo de una carpeta con su SHA-256, en rutas relativas. Es lo que
        viaja en el bundle para comprobar en destino que llego entero.
    #>
    param([Parameter(Mandatory=$true)][string]$Ruta)

    $base = (Resolve-Path -LiteralPath $Ruta).ProviderPath.TrimEnd('\')
    return @(Get-ChildItem -LiteralPath $base -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
        [ordered]@{ ruta = $_.FullName.Substring($base.Length + 1); sha256 = (Get-FileSha256 -FilePath $_.FullName) }
    })
}

function Test-FolderManifest {
    <#
        Si una carpeta tiene exactamente esos archivos con esos hashes. Devuelve
        la lista de lo que no cuadra (vacia si todo bien).
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Ruta,
        [AllowEmptyCollection()][object[]]$Archivos = @()
    )

    $malos = @()
    foreach ($a in $Archivos) {
        $f = Join-Path $Ruta $a.ruta
        if (-not (Test-Path -LiteralPath $f)) { $malos += "$($a.ruta): falta"; continue }
        if ((Get-FileSha256 -FilePath $f) -ne $a.sha256) { $malos += "$($a.ruta): no coincide" }
    }
    return $malos
}

function Get-LatestAngularCliVersion {
    <#
        Ultima version estable del CLI para una mayor de Angular, segun el
        registro de npm. Devuelve $null si el registro no respondio, y cadena
        vacia si respondio pero esa mayor no existe.
    #>
    param([Parameter(Mandatory=$true)][int]$Major)

    $pack = Invoke-JsonApi -Uri "https://registry.npmjs.org/@angular%2fcli" `
                           -Headers @{ Accept = 'application/vnd.npm.install-v1+json' } `
                           -TimeoutSec 120 -Quiet
    if (-not $pack -or -not $pack.versions) { return $null }

    $stable = @($pack.versions.PSObject.Properties.Name |
        Where-Object { $_ -match "^$Major\." -and $_ -notmatch '-(next|rc|beta|alpha)' } |
        Sort-Object { ConvertTo-SemverObject $_ })

    if ($stable.Count -eq 0) { return '' }
    return $stable[-1]
}

function Get-JavaArchiveInfo {
    <#
        Datos del JDK de Adoptium. Con -Major coge el ultimo de esa linea; con
        -Release, ESE exacto (ej: jdk-25.0.4.1+1), que es lo que permite fijarlo
        en un devenv.lock.json.

        Son dos endpoints distintos y la respuesta tiene distinta forma: el de
        "latest" devuelve una lista de objetos con .binary, y el de release_name
        un objeto con .binaries. Devuelve $null si la API no responde.

        Los filtros de la query no son opcionales en el segundo: sin ellos
        devuelve tambien los static-libs y el primer zip no seria el JDK.
    #>
    param(
        [int]$Major,
        [string]$Release
    )

    if (-not [string]::IsNullOrWhiteSpace($Release)) {
        $uri = "https://api.adoptium.net/v3/assets/release_name/eclipse/" +
               [Uri]::EscapeDataString($Release) +
               "?architecture=$(Get-ArchToken -Fuente adoptium)&image_type=jdk&os=windows"

        $r = Invoke-JsonApi -Uri $uri -TimeoutSec 120 -Quiet
        if (-not $r) { return $null }

        $obj = @($r)[0]
        $zip = @($obj.binaries | Where-Object { $_.package.name -like '*.zip' })
        if ($zip.Count -eq 0) { return $null }

        return [PSCustomObject]@{
            FileName = $zip[0].package.name
            Url      = $zip[0].package.link
            Sha256   = $zip[0].package.checksum
            Release  = $obj.release_name
            SizeMb   = [math]::Round($zip[0].package.size / 1MB, 1)
        }
    }

    if ($Major -le 0) { return $null }

    $uri = "https://api.adoptium.net/v3/assets/latest/$Major/hotspot" +
           "?architecture=$(Get-ArchToken -Fuente adoptium)&image_type=jdk&os=windows&vendor=eclipse"

    $assets = Invoke-JsonApi -Uri $uri -TimeoutSec 120 -Quiet
    if (-not $assets -or $assets.Count -eq 0) { return $null }

    $zip = @($assets | Where-Object { $_.binary.package.name -like '*.zip' })
    if ($zip.Count -eq 0) { return $null }

    $r = $zip[0]
    return [PSCustomObject]@{
        FileName = $r.binary.package.name
        Url      = $r.binary.package.link
        Sha256   = $r.binary.package.checksum
        Release  = $r.release_name
    }
}

function Split-RuntimeVersionSpec {
    <#
    .SYNOPSIS
        Separa lo que pide el usuario en "linea" y "exacta".
    .DESCRIPTION
        Los Setup aceptan ahora las dos formas en el MISMO parametro, para que
        un devenv.lock.json pueda fijar la version sin necesitar un parametro
        distinto por runtime:

            -JavaVersion 21              la linea: el ultimo parche de la 21
            -JavaVersion jdk-21.0.5+11   ese release exacto

        Devuelve Linea (siempre) y Exacta ($null si solo se pidio la linea).
        Reconocer una u otra depende del runtime, porque sus versiones no tienen
        la misma forma: la de Java lleva prefijo y un '+', la de Angular es un
        semver, y la de VS Code y .NET son X.Y frente a X.Y.Z.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Clave,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Spec
    )

    $s = $Spec.Trim()
    if ([string]::IsNullOrWhiteSpace($s)) {
        return [PSCustomObject]@{ Linea = $null; Exacta = $null }
    }

    switch ($Clave) {
        'java' {
            # jdk-25.0.4.1+1  ->  linea 25
            if ($s -match '^jdk-(\d+)') {
                return [PSCustomObject]@{ Linea = $Matches[1]; Exacta = $s }
            }
            # 25.0.4.1+1 sin prefijo: se acepta y se normaliza.
            if ($s -match '^(\d+)\.\d+.*\+') {
                return [PSCustomObject]@{ Linea = $Matches[1]; Exacta = "jdk-$s" }
            }
            return [PSCustomObject]@{ Linea = ($s -replace '^jdk-',''); Exacta = $null }
        }
        'angular' {
            # 20.3.35 -> linea 20 ;  20 -> solo linea
            if ($s -match '^(\d+)\.\d+') {
                return [PSCustomObject]@{ Linea = $Matches[1]; Exacta = $s }
            }
            return [PSCustomObject]@{ Linea = $s; Exacta = $null }
        }
        'dotnet' {
            # 10.0.400 -> canal 10.0 ;  10.0 -> solo canal
            if ($s -match '^(\d+\.\d+)\.\d+') {
                return [PSCustomObject]@{ Linea = $Matches[1]; Exacta = $s }
            }
            return [PSCustomObject]@{ Linea = $s; Exacta = $null }
        }
        'vscode' {
            # 1.135.0 -> linea 1.135 ;  1.135 -> solo linea
            if ($s -match '^(\d+\.\d+)\.\d+') {
                return [PSCustomObject]@{ Linea = $Matches[1]; Exacta = $s }
            }
            return [PSCustomObject]@{ Linea = $s; Exacta = $null }
        }
    }

    return [PSCustomObject]@{ Linea = $s; Exacta = $null }
}

function Get-WebText {
    <#
        GET que devuelve el cuerpo como texto, con el mismo tratamiento de proxy
        que el resto. Para paginas HTML o listados de directorio, donde
        Invoke-JsonApi no encaja.
        Devuelve $null si falla; quien llama decide si eso es fatal.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [int]$TimeoutSec = 60,
        [switch]$Quiet
    )

    $Uri = Resolve-KitUrl -Uri $Uri -Quiet:$Quiet

    $params = @{
        Uri             = $Uri
        UseBasicParsing = $true
        TimeoutSec      = $TimeoutSec
    }

    Add-ProxyToRequest -Params $params -Uri ([Uri]$Uri)

    try {
        $contenido = (Invoke-WebRequest @params).Content

        # Cuando el servidor no declara charset, PowerShell 5.1 no decodifica y
        # devuelve un ARRAY DE BYTES en vez de texto. Pasa con archivos sueltos
        # de checksum como el .sha256 de Gradle, y quien llama recibia
        # System.Object[] donde esperaba una cadena.
        if ($contenido -is [byte[]] -or $contenido -is [System.Array]) {
            return [System.Text.Encoding]::UTF8.GetString([byte[]]$contenido)
        }
        return $contenido
    }
    catch {
        if (-not $Quiet) {
            Write-Log "No se pudo leer $Uri" "WARN"
            $hint = Get-DownloadErrorHint -ErrorRecord $_
            if ($hint) { Write-Log "  -> $hint" "WARN" }
        }
        return $null
    }
}

function Test-UrlExists {
    <#
        Comprueba con una peticion HEAD si un archivo existe en el servidor,
        sin descargarlo. Util para probar versiones candidatas antes de elegir.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [int]$TimeoutSec = 30
    )

    # -Quiet: Test-UrlExists se usa en bucle para tantear versiones candidatas,
    # y anunciar el espejo en cada intento llenaria la pantalla de ruido.
    $Uri = Resolve-KitUrl -Uri $Uri -Quiet

    $params = @{
        Uri             = $Uri
        Method          = 'Head'
        UseBasicParsing = $true
        TimeoutSec      = $TimeoutSec
    }

    Add-ProxyToRequest -Params $params -Uri ([Uri]$Uri)

    try {
        Invoke-WebRequest @params | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Get-Sha256FromShasums {
    <#
        Lee un archivo de checksums remoto con el formato "<hash>  <archivo>"
        (el que publica nodejs.org junto a cada release) y devuelve el hash del
        archivo pedido, o $null si no se pudo obtener.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [Parameter(Mandatory=$true)][string]$FileName
    )

    $temp = Join-Path $env:TEMP ("shasums-" + [Guid]::NewGuid().ToString('N') + ".txt")

    if (-not (Invoke-Download -Uri $Uri -OutFile $temp -Description "checksums oficiales")) {
        return $null
    }

    try {
        foreach ($line in (Get-Content -LiteralPath $temp)) {
            $parts = $line -split '\s+', 2
            if ($parts.Count -eq 2 -and $parts[1].Trim() -eq $FileName) {
                return $parts[0].Trim().ToLowerInvariant()
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }

    return $null
}

function Test-ZipIntegrity {
    <#
        Abrir el zip obliga a leer su indice central, que esta al final del
        archivo: detecta descargas truncadas aqui, en vez de dejar que
        Expand-ZipArchive falle luego con un error incomprensible.
    #>
    param([Parameter(Mandatory=$true)][string]$ZipPath)

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        try {
            return ($zip.Entries.Count -gt 0)
        }
        finally {
            $zip.Dispose()
        }
    }
    catch {
        return $false
    }
}
