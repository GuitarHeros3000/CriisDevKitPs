#Requires -Version 5.1
<#
    Pruebas de lib\Catalog.ps1.

    Casi todas cubren un fallo que existio de verdad. Se anotan con el sintoma
    que producian, porque un test sin contexto se acaba borrando cuando estorba.
#>

. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

Describe "devenv.json (Read-DevEnvManifest)" {

    function Manifiesto($json) { return (ConvertFrom-Json $json) }

    It "devuelve los runtimes pedidos con su version" {
        $p = Read-DevEnvManifest -Config (Manifiesto '{ "version": 1, "runtimes": { "python": "3.12", "java": "21" } }')
        $p.Errores.Count  | Should Be 0
        $p.Runtimes.Count | Should Be 2
        ($p.Runtimes | Where-Object { $_.Clave -eq 'python' }).Version | Should Be '3.12'
    }

    # El orden lo fija el catalogo, no el archivo: Maven y Gradle necesitan un
    # JDK, asi que Java tiene que instalarse antes aunque en el JSON vaya despues.
    It "instala Java antes que Maven aunque el manifiesto los ponga al reves" {
        $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "maven": "3.9", "java": "21" } }')
        $p.Runtimes[0].Clave | Should Be 'java'
        $p.Runtimes[1].Clave | Should Be 'maven'
    }

    # Una errata no puede pasar en silencio: dejaria el entorno a medias sin
    # decir por que, que es lo contrario de para lo que sirve el comando.
    It "senala un runtime desconocido en vez de ignorarlo" {
        $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "phyton": "3.12" } }')
        $p.Errores.Count | Should BeGreaterThan 0
        ($p.Errores -join ' ') | Should Match 'phyton'
    }

    It "el error de runtime desconocido dice cuales si valen" {
        $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "rust": "1.0" } }')
        ($p.Errores -join ' ') | Should Match 'python'
        ($p.Errores -join ' ') | Should Match 'dotnet'
    }

    It "acepta las claves en mayusculas" {
        $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "PYTHON": "3.12" } }')
        $p.Errores.Count  | Should Be 0
        $p.Runtimes.Count | Should Be 1
    }

    It "recoge los paquetes de pip para Python" {
        $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "python": "3.12" }, "paquetes": { "python": ["django", "flask"] } }')
        ($p.Runtimes | Where-Object { $_.Clave -eq 'python' }).Paquetes | Should Be 'django,flask'
    }

    Context "varias versiones del mismo runtime" {

        # Con un solo valor por runtime, una maquina con dos JDK -trabajar en
        # proyectos con Javas distintos- no se podia reproducir desde su propio
        # manifiesto. Es el motivo de admitir listas.
        It "una lista instala las dos versiones" {
            $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "java": ["25", "21"] } }')
            $p.Errores.Count  | Should Be 0
            $p.Runtimes.Count | Should Be 2
            ($p.Runtimes.Version -join ',') | Should Be '21,25'
        }

        It "un valor suelto sigue funcionando igual" {
            $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "java": "21" } }')
            $p.Runtimes.Count   | Should Be 1
            $p.Runtimes[0].Java | Should BeNullOrEmpty
        }

        It "sigue instalando Java antes que Maven con varias lineas" {
            $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "maven": "3.9", "java": ["25", "21"] } }')
            ($p.Runtimes.Clave -join ',') | Should Be 'java,java,maven'
        }

        It "una lista vacia es un error, no un runtime sin version" {
            $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "java": [] } }')
            $p.Errores.Count | Should BeGreaterThan 0
        }

        # Instalarla dos veces no rompe nada, pero es una errata: mas vale
        # decirlo que ejecutar el mismo Setup dos veces sin explicacion.
        It "una version repetida se senala" {
            $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "java": ["21", "21"] } }')
            ($p.Errores -join ' ') | Should Match '21'
        }
    }

    Context "seccion java: a que JDK va el shell de Maven y Gradle" {

        It "ata Maven al JDK que se le diga" {
            $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "java": ["21", "25"], "maven": "3.9" }, "java": { "maven": "21" } }')
            $p.Errores.Count | Should Be 0
            ($p.Runtimes | Where-Object { $_.Clave -eq 'maven' }).Java | Should Be '21'
        }

        # Este es el error que justifica la validacion: sin ella, Restore-Env
        # instalaba Java y Maven y solo al final fallaba el -JavaVersion, con el
        # entorno ya a medias.
        It "rechaza atar Maven a un JDK que el manifiesto no instala" {
            $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "java": "25", "maven": "3.9" }, "java": { "maven": "21" } }')
            $p.Errores.Count | Should BeGreaterThan 0
            ($p.Errores -join ' ') | Should Match '21'
            ($p.Errores -join ' ') | Should Match 'instala: 25'
        }

        It "rechaza atar un runtime que no elige JDK" {
            $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "python": "3.12" }, "java": { "python": "21" } }')
            ($p.Errores -join ' ') | Should Match 'python'
        }

        It "rechaza un runtime desconocido en la seccion java" {
            $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "maven": "3.9" }, "java": { "grade": "21" } }')
            ($p.Errores -join ' ') | Should Match 'grade'
        }

        It "rechaza algo que no es una linea de JDK" {
            $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "java": "21", "maven": "3.9" }, "java": { "maven": "jdk-21" } }')
            ($p.Errores -join ' ') | Should Match 'jdk-21'
        }

        # Sin Java en el manifiesto la atadura puede ser legitima -un JDK ya
        # instalado a mano- asi que avisa en vez de parar.
        It "avisa, sin parar, si el manifiesto no instala Java" {
            $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "maven": "3.9" }, "java": { "maven": "21" } }')
            $p.Errores.Count | Should Be 0
            $p.Avisos.Count  | Should BeGreaterThan 0
            ($p.Runtimes | Where-Object { $_.Clave -eq 'maven' }).Java | Should Be '21'
        }

        It "avisa si se ata una herramienta que el manifiesto no instala" {
            $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "java": "21" }, "java": { "gradle": "21" } }')
            $p.Errores.Count | Should Be 0
            $p.Avisos.Count  | Should BeGreaterThan 0
        }
    }

    It "sin paquetes, deja el campo vacio" {
        $p = Read-DevEnvManifest -Config (Manifiesto '{ "runtimes": { "python": "3.12" } }')
        $p.Runtimes[0].Paquetes | Should BeNullOrEmpty
    }

    # Mejor negarse que instalar mal algo escrito para una version futura.
    It "rechaza un manifiesto de una version mas nueva que el kit" {
        $p = Read-DevEnvManifest -Config (Manifiesto '{ "version": 99, "runtimes": { "python": "3.12" } }')
        ($p.Errores -join ' ') | Should Match 'version 99'
    }

    It "avisa si no hay seccion runtimes" {
        $p = Read-DevEnvManifest -Config (Manifiesto '{ "version": 1 }')
        ($p.Errores -join ' ') | Should Match 'runtimes'
    }

    It "tolera un manifiesto nulo" {
        $p = Read-DevEnvManifest -Config $null
        $p.Errores.Count  | Should BeGreaterThan 0
        $p.Runtimes.Count | Should Be 0
    }

    It "todos los runtimes del catalogo se pueden pedir" {
        $claves = (Get-RuntimeCatalog).Clave
        $json = '{ "runtimes": { ' + (($claves | ForEach-Object { "`"$_`": `"latest`"" }) -join ', ') + ' } }'
        $p = Read-DevEnvManifest -Config (Manifiesto $json)
        $p.Errores.Count  | Should Be 0
        $p.Runtimes.Count | Should Be $claves.Count
    }
}

Describe "devenv.lock.json (Read-DevEnvLock)" {

    function Lock($json) { return (ConvertFrom-Json $json) }

    # El lock es al devenv.json lo que un package-lock.json al package.json: el
    # manifiesto dice "3.12", el lock dice "3.12.10".
    It "usa la version exacta cuando el Setup la admite" {
        $p = Read-DevEnvLock -Config (Lock '{ "runtimes": { "python": { "linea": "3.12", "exacta": "3.12.10", "fijable": true } } }')
        $p.Errores.Count      | Should Be 0
        $p.Runtimes[0].Version | Should Be '3.12.10'
        $p.Runtimes[0].Fijado  | Should Be $true
    }

    # Java tambien se fija desde que -JavaVersion acepta el release exacto.
    # Antes era el ejemplo del caso contrario: su parametro era un entero y no
    # habia forma de pedir 25.0.4.1+1.
    It "Java tambien usa la exacta" {
        $p = Read-DevEnvLock -Config (Lock '{ "runtimes": { "java": { "linea": "25", "exacta": "jdk-25.0.4.1+1" } } }')
        $p.Runtimes[0].Version | Should Be 'jdk-25.0.4.1+1'
        $p.Runtimes[0].Fijado  | Should Be $true
    }

    # La caida a la linea sigue en el codigo aunque hoy ningun runtime la
    # necesite: es la red de seguridad para el siguiente que se anada sin
    # soporte de version exacta. Se prueba con una entrada marcada a mano.
    It "sin exacta en el lock, se usa la linea" {
        $p = Read-DevEnvLock -Config (Lock '{ "runtimes": { "java": { "linea": "25" } } }')
        $p.Runtimes[0].Version | Should Be '25'
        $p.Runtimes[0].Fijado  | Should Be $false
    }

    It "conserva el checksum cuando el lock lo trae" {
        $p = Read-DevEnvLock -Config (Lock '{ "runtimes": { "python": { "linea": "3.12", "exacta": "3.12.10", "sha256": "abc123" } } }')
        $p.Runtimes[0].Sha256 | Should Be 'abc123'
    }

    It "respeta el orden del catalogo, no el del archivo" {
        $p = Read-DevEnvLock -Config (Lock '{ "runtimes": { "maven": { "linea": "3.9" }, "java": { "linea": "25" } } }')
        $p.Runtimes[0].Clave | Should Be 'java'
        $p.Runtimes[1].Clave | Should Be 'maven'
    }

    It "senala un runtime desconocido" {
        $p = Read-DevEnvLock -Config (Lock '{ "runtimes": { "rust": { "linea": "1.0" } } }')
        ($p.Errores -join ' ') | Should Match 'rust'
    }

    It "senala una entrada sin linea ni exacta" {
        $p = Read-DevEnvLock -Config (Lock '{ "runtimes": { "python": { "fijable": true } } }')
        ($p.Errores -join ' ') | Should Match 'ni linea ni exacta'
    }

    It "con solo exacta y sin linea, la usa igualmente" {
        $p = Read-DevEnvLock -Config (Lock '{ "runtimes": { "git": { "exacta": "2.55.0.5" } } }')
        $p.Errores.Count       | Should Be 0
        $p.Runtimes[0].Version | Should Be '2.55.0.5'
    }

    It "rechaza un lock de una version mas nueva que el kit" {
        $p = Read-DevEnvLock -Config (Lock '{ "version": 99, "runtimes": { "python": { "linea": "3.12" } } }')
        ($p.Errores -join ' ') | Should Match 'version 99'
    }

    It "tolera un lock nulo o sin runtimes" {
        (Read-DevEnvLock -Config $null).Errores.Count | Should BeGreaterThan 0
        (Read-DevEnvLock -Config (Lock '{ "version": 1 }')).Errores.Count | Should BeGreaterThan 0
    }

    # Un lock que solo sabe anotar un Java no reproduce la maquina que tiene el
    # 21 y el 25, que es justo lo que se queria fijar.
    It "fija varias lineas del mismo runtime" {
        $p = Read-DevEnvLock -Config (Lock '{ "runtimes": { "java": [ { "linea": "21", "exacta": "jdk-21.0.12.1+1", "fijable": true }, { "linea": "25", "exacta": "jdk-25.0.4.1+1", "fijable": true } ] } }')
        $p.Errores.Count  | Should Be 0
        $p.Runtimes.Count | Should Be 2
        ($p.Runtimes.Exacta -join ',') | Should Be 'jdk-21.0.12.1+1,jdk-25.0.4.1+1'
    }

    It "una entrada suelta sigue funcionando igual" {
        $p = Read-DevEnvLock -Config (Lock '{ "runtimes": { "java": { "linea": "25", "exacta": "jdk-25.0.4.1+1" } } }')
        $p.Runtimes.Count | Should Be 1
    }

    It "recoge a que JDK va el shell por defecto de Maven" {
        $p = Read-DevEnvLock -Config (Lock '{ "runtimes": { "maven": { "linea": "3.9", "java": "21" } } }')
        $p.Runtimes[0].Java | Should Be '21'
    }

    # Si esto se desalinea, el lock pediria versiones que el Setup rechaza.
    # Los nueve son fijables desde que Java, Angular, .NET y VS Code aceptan la
    # version exacta en su propio parametro; antes solo lo eran cinco.
    It "los nueve runtimes se pueden fijar" {
        foreach ($e in (Get-RuntimeCatalog)) {
            $e.Fijable | Should Be $true
        }
    }

    # Fijable sin parametro con que pedirlo seria mentira: Restore-Env no
    # tendria como pasar la version.
    It "todo runtime fijable tiene parametro de version" {
        foreach ($e in (Get-RuntimeCatalog | Where-Object { $_.Fijable })) {
            [string]::IsNullOrWhiteSpace($e.ParamVersion) | Should Be $false
        }
    }
}

Describe "Split-RuntimeVersionSpec" {

    # Los Setup aceptan la linea y la version exacta en el MISMO parametro, para
    # que un lock pueda fijarla sin necesitar otro distinto por runtime. Esto es
    # lo que distingue una forma de la otra, y no es igual para todos: la de
    # Java lleva prefijo y un '+', la de Angular es un semver.

    It "Java: reconoce el release exacto y saca su linea" {
        $r = Split-RuntimeVersionSpec -Clave java -Spec 'jdk-21.0.9+10'
        $r.Linea  | Should Be '21'
        $r.Exacta | Should Be 'jdk-21.0.9+10'
    }

    It "Java: la linea sola no fija nada" {
        $r = Split-RuntimeVersionSpec -Clave java -Spec '21'
        $r.Linea  | Should Be '21'
        $r.Exacta | Should BeNullOrEmpty
    }

    It "Java: acepta el release sin el prefijo jdk- y lo normaliza" {
        $r = Split-RuntimeVersionSpec -Clave java -Spec '21.0.9+10'
        $r.Linea  | Should Be '21'
        $r.Exacta | Should Be 'jdk-21.0.9+10'
    }

    It "Angular: 20.3.35 es exacta de la linea 20" {
        $r = Split-RuntimeVersionSpec -Clave angular -Spec '20.3.35'
        $r.Linea  | Should Be '20'
        $r.Exacta | Should Be '20.3.35'
    }

    It "Angular: 20 es solo la linea" {
        (Split-RuntimeVersionSpec -Clave angular -Spec '20').Exacta | Should BeNullOrEmpty
    }

    # .NET y VS Code tienen linea de DOS componentes, no uno: 10.0 y 1.135.
    It ".NET: 10.0.400 es exacta del canal 10.0" {
        $r = Split-RuntimeVersionSpec -Clave dotnet -Spec '10.0.400'
        $r.Linea  | Should Be '10.0'
        $r.Exacta | Should Be '10.0.400'
    }

    It ".NET: 10.0 es solo el canal" {
        $r = Split-RuntimeVersionSpec -Clave dotnet -Spec '10.0'
        $r.Linea  | Should Be '10.0'
        $r.Exacta | Should BeNullOrEmpty
    }

    It "VS Code: 1.135.0 es exacta de la linea 1.135" {
        $r = Split-RuntimeVersionSpec -Clave vscode -Spec '1.135.0'
        $r.Linea  | Should Be '1.135'
        $r.Exacta | Should Be '1.135.0'
    }

    It "vacio no pide nada" {
        $r = Split-RuntimeVersionSpec -Clave java -Spec ''
        $r.Linea  | Should BeNullOrEmpty
        $r.Exacta | Should BeNullOrEmpty
    }

    # La linea que devuelve tiene que servir para componer el nombre de carpeta
    # del catalogo; si no, se instalaria en un sitio y se buscaria en otro.
    It "la linea encaja con el patron de carpeta del catalogo" {
        $casos = @{ java = 'jdk-21.0.9+10'; angular = '20.3.35'; dotnet = '10.0.400'; vscode = '1.135.0' }
        foreach ($clave in $casos.Keys) {
            $e = @(Get-RuntimeCatalog | Where-Object { $_.Clave -eq $clave })[0]
            $linea = (Split-RuntimeVersionSpec -Clave $clave -Spec $casos[$clave]).Linea
            $carpeta = switch ($clave) {
                'java'    { "jdk-$linea" }
                'angular' { "angular-v$linea" }
                default   { "$clave-$linea" }
            }
            $carpeta | Should Match $e.Patron
        }
    }
}

Describe "Expand-BundledRuntime" {

    # Los archivos de los runtimes no vienen todos igual, y equivocarse deja la
    # instalacion un nivel mas abajo o mas arriba de donde toca:
    #   con envoltorio  el zip trae dentro una carpeta (node-vX, apache-maven-X)
    #   plano           el zip vuelca su contenido directo (dotnet, vscode)
    # El tercer modo, el autoextraible de PortableGit, no se puede probar con un
    # zip sintetico porque necesita el .exe real.

    function NuevoTemp {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ("exp-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        return $d
    }

    function ZipDe($origen, $destino) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::CreateFromDirectory($origen, $destino)
    }

    It "con envoltorio, sube el contenido un nivel" {
        $t = NuevoTemp
        try {
            # Un zip que dentro trae "apache-maven-3.9.16\bin\mvn.cmd"
            $src = Join-Path $t "src"
            New-Item -ItemType Directory -Path (Join-Path $src "apache-maven-3.9.16\bin") -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $src "apache-maven-3.9.16\bin\mvn.cmd") -Value 'x'
            $zip = Join-Path $t "a.zip"
            ZipDe $src $zip

            $destino = Join-Path $t "maven-3.9"
            $e = [PSCustomObject]@{ Envoltorio = $true; Sfx = $false }
            Expand-BundledRuntime -Archivo $zip -Destino $destino -Entrada $e | Should Be $true

            # El bin queda directamente bajo maven-3.9, no bajo otra carpeta.
            Test-Path (Join-Path $destino "bin\mvn.cmd") | Should Be $true
        }
        finally { Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "plano, deja el contenido tal cual" {
        $t = NuevoTemp
        try {
            $src = Join-Path $t "src"
            New-Item -ItemType Directory -Path $src -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $src "dotnet.exe") -Value 'x'
            $zip = Join-Path $t "b.zip"
            ZipDe $src $zip

            $destino = Join-Path $t "dotnet-10.0"
            $e = [PSCustomObject]@{ Envoltorio = $false; Sfx = $false }
            Expand-BundledRuntime -Archivo $zip -Destino $destino -Entrada $e | Should Be $true

            Test-Path (Join-Path $destino "dotnet.exe") | Should Be $true
        }
        finally { Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # Si el zip con envoltorio trae MAS de una carpeta arriba no hay envoltorio
    # que quitar, y hay que volcarlo todo en vez de perder contenido.
    It "con envoltorio pero varias carpetas arriba, no pierde nada" {
        $t = NuevoTemp
        try {
            $src = Join-Path $t "src"
            New-Item -ItemType Directory -Path (Join-Path $src "uno") -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $src "dos") -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $src "uno\a.txt") -Value 'a'
            Set-Content -LiteralPath (Join-Path $src "dos\b.txt") -Value 'b'
            $zip = Join-Path $t "c.zip"
            ZipDe $src $zip

            $destino = Join-Path $t "x"
            $e = [PSCustomObject]@{ Envoltorio = $true; Sfx = $false }
            Expand-BundledRuntime -Archivo $zip -Destino $destino -Entrada $e | Should Be $true

            Test-Path (Join-Path $destino "uno\a.txt") | Should Be $true
            Test-Path (Join-Path $destino "dos\b.txt") | Should Be $true
        }
        finally { Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe "Cobertura del catalogo" {

    # ESTA es la prueba que faltaba. El catalogo existe desde hace tiempo, pero
    # nada obligaba a que los comandos lo siguieran: se anadieron seis runtimes
    # y Export-Env e Import-Env se quedaron en tres, asi que el bundle
    # "portable" ignoraba en silencio Git, Maven, Gradle, .NET y VS Code.
    # Nadie se entero hasta que se comprobo a mano meses despues.
    #
    # A partir de aqui, anadir un runtime al catalogo y olvidarse de un comando
    # pone la suite en rojo el mismo dia.

    $scripts  = Join-Path (Split-Path -Parent $PSScriptRoot) "scripts"
    $catalogo = Get-RuntimeCatalog

    # Los comandos que deben admitir -Runtime con TODOS los del catalogo.
    $conValidateSet = @('Doctor-Env', 'Update-Env', 'Uninstall-Env', 'Use-Env', 'Export-Env', 'Import-Env')

    foreach ($nombre in $conValidateSet) {
        It "$nombre admite los $($catalogo.Count) runtimes del catalogo" {
            $txt = Get-Content (Join-Path $scripts "$nombre.ps1") -Raw

            # Doctor no tiene -Runtime; se comprueba que nombre cada carpeta.
            if ($nombre -eq 'Doctor-Env') {
                foreach ($e in $catalogo) {
                    $txt | Should Match ([regex]::Escape($e.Carpeta))
                }
                return
            }

            $m = [regex]::Match($txt, "ValidateSet\(([^)]*)\)")
            $m.Success | Should Be $true
            foreach ($e in $catalogo) {
                $m.Groups[1].Value | Should Match ([regex]::Escape("'$($e.Carpeta)'"))
            }
        }
    }

    It "todo runtime empaquetable sabe decir su archivo de descarga" {
        foreach ($e in ($catalogo | Where-Object { $_.Bundle })) {
            # No se llama a la red: solo se comprueba que Get-BundleArchiveInfo
            # contempla la clave, que es lo que se olvida al anadir un runtime.
            $cuerpo = (Get-Command Get-BundleArchiveInfo).Definition
            $cuerpo | Should Match ([regex]::Escape("'$($e.Clave)'"))
        }
    }

    It "todo runtime empaquetable sabe regenerar su shell" {
        foreach ($e in ($catalogo | Where-Object { $_.Bundle })) {
            (Get-Command Write-RuntimeShell).Definition | Should Match ([regex]::Escape("'$($e.Clave)'"))
        }
    }

    # Sin estos metadatos, Expand-BundledRuntime no sabe si el zip trae carpeta
    # dentro y dejaria el runtime un nivel mas abajo de donde toca.
    It "todo runtime empaquetable declara como viene empaquetado" {
        foreach ($e in ($catalogo | Where-Object { $_.Bundle })) {
            ($null -ne $e.Envoltorio) | Should Be $true
            ($null -ne $e.Sfx)        | Should Be $true
        }
    }

    It "los que NO se empaquetan tienen su tratamiento propio en Export-Env" {
        $txt = Get-Content (Join-Path $scripts "Export-Env.ps1") -Raw
        foreach ($e in ($catalogo | Where-Object { -not $_.Bundle })) {
            $txt | Should Match "Get-$($e.Carpeta)Entries"
        }
    }

    It "Restore-Env no nombra runtimes: los saca del catalogo" {
        $txt = Get-Content (Join-Path $scripts "Restore-Env.ps1") -Raw
        $txt | Should Match 'Get-RuntimeCatalog'
    }

    # El menu construye sus opciones de instalacion recorriendo el catalogo. Si
    # alguien las escribiera a mano, un runtime nuevo no apareceria y nadie se
    # enteraria hasta echarlo en falta.
    It "el menu saca los runtimes del catalogo" {
        $txt = Get-Content (Join-Path $scripts "Menu.ps1") -Raw
        $txt | Should Match 'Get-RuntimeCatalog'
    }

    # Cada opcion del menu llama a un .bat de la raiz. Uno mal escrito solo se
    # notaria al pulsarlo.
    It "todos los .bat que invoca el menu existen" {
        $raiz = Split-Path -Parent $PSScriptRoot
        $txt = Get-Content (Join-Path $scripts "Menu.ps1") -Raw
        $bats = @([regex]::Matches($txt, "Bat\s*=\s*'([^']+\.bat)'") | ForEach-Object { $_.Groups[1].Value })
        $bats.Count | Should BeGreaterThan 5
        foreach ($b in ($bats | Sort-Object -Unique)) {
            Test-Path (Join-Path $raiz $b) | Should Be $true
        }
    }

    # Los Setup y los Start se componen a partir del catalogo, asi que se
    # comprueban aparte de los literales.
    It "existen el Setup y el Start de cada runtime del catalogo" {
        $raiz = Split-Path -Parent $PSScriptRoot
        foreach ($e in $catalogo) {
            Test-Path (Join-Path $raiz "Setup-$($e.Carpeta)Env.bat") | Should Be $true
            Test-Path (Join-Path $raiz "Start-$($e.Carpeta)Env.bat") | Should Be $true
        }
    }
}

Describe "Resolve-RuntimeFromPath" {

    # Traduce "esta carpeta esta tapada en el PATH" a "esto se arregla con
    # Use-Env -Runtime Java -Version 25", que es lo que permite a Doctor
    # ofrecer la reparacion en vez de limitarse a contar el problema.

    It "reconoce el bin de un JDK del kit" {
        $r = Resolve-RuntimeFromPath -Path (Join-Path $WorkspaceRoot 'Java\jdk-25\bin')
        $r.Runtime | Should Be 'Java'
        $r.Version | Should Be '25'
    }

    It "reconoce la carpeta de un Python del kit" {
        $r = Resolve-RuntimeFromPath -Path (Join-Path $WorkspaceRoot 'Python\python-3.12')
        $r.Runtime | Should Be 'Python'
        $r.Version | Should Be '3.12'
    }

    It "reconoce una subcarpeta profunda" {
        $r = Resolve-RuntimeFromPath -Path (Join-Path $WorkspaceRoot 'Python\python-3.12\Scripts')
        $r.Version | Should Be '3.12'
    }

    It "el nombre que devuelve sirve tal cual para Use-Env" {
        $valida = @('Angular','Python','Java','Node','Git','Maven','Gradle','Dotnet','VSCode')
        foreach ($e in (Get-RuntimeCatalog)) {
            $valida -contains $e.Carpeta | Should Be $true
        }
    }

    It "devuelve nulo para algo ajeno al kit" {
        Resolve-RuntimeFromPath -Path 'C:\Program Files\Java\jdk1.8.0_202\bin' | Should BeNullOrEmpty
        Resolve-RuntimeFromPath -Path 'C:\Program Files\nodejs' | Should BeNullOrEmpty
    }

    # Una carpeta con nombre libre dentro de la raiz de un runtime no es del
    # kit: solo cuentan las que siguen su patron.
    It "devuelve nulo para una carpeta que no sigue el patron" {
        Resolve-RuntimeFromPath -Path (Join-Path $WorkspaceRoot 'Java\mi-jdk-a-mano\bin') | Should BeNullOrEmpty
    }

    It "tolera vacio" {
        Resolve-RuntimeFromPath -Path '' | Should BeNullOrEmpty
    }
}

Describe "Get-RuntimeCatalog" {

    # El catalogo es el unico sitio que sabe como se instala cada runtime. Si
    # una entrada esta mal, Restore-Env falla en tiempo de ejecucion y no al
    # leerse, asi que conviene comprobar la forma aqui.
    $catalogo = Get-RuntimeCatalog

    It "no repite claves" {
        ($catalogo.Clave | Sort-Object -Unique).Count | Should Be $catalogo.Count
    }

    It "cada entrada apunta a un script que existe" {
        $scripts = Join-Path (Split-Path -Parent $PSScriptRoot) "scripts"
        foreach ($e in $catalogo) {
            Test-Path (Join-Path $scripts $e.Script) | Should Be $true
        }
    }

    It "cada patron de carpeta captura un grupo" {
        foreach ($e in $catalogo) {
            $e.Patron | Should Match '\('
        }
    }

    It "las claves van en minuscula, que es como se escriben en el JSON" {
        foreach ($e in $catalogo) {
            $e.Clave | Should Be $e.Clave.ToLowerInvariant()
        }
    }

    # Uninstall-Env -Everything compone las carpetas a barrer con
    # Join-Path $WorkspaceRoot $e.Carpeta. Una Carpeta vacia daria la RAIZ DEL
    # WORKSPACE, o sea la carpeta que contiene el kit y todos los proyectos del
    # usuario, y esa se borraria por "estar vacia". Es la propiedad mas critica
    # del catalogo entero.
    It "ninguna Carpeta esta vacia: compondrian la raiz del workspace" {
        foreach ($e in $catalogo) {
            [string]::IsNullOrWhiteSpace($e.Carpeta) | Should Be $false
        }
    }

    It "ninguna Carpeta escapa hacia arriba" {
        foreach ($e in $catalogo) {
            $e.Carpeta | Should Not Match '\.\.'
            $e.Carpeta | Should Not Match '^[A-Za-z]:'
            $e.Carpeta | Should Not Match '^[\\/]'
        }
    }

    It "no hay dos runtimes compartiendo carpeta" {
        ($catalogo.Carpeta | Sort-Object -Unique).Count | Should Be $catalogo.Count
    }

    # Sin firmante esperado, Doctor solo puede DECIR quien firma; con el, puede
    # detectar una suplantacion. Declarar uno sin el otro deja la comprobacion a
    # medias sin que se note.
    It "ExeFirma y FirmanteEsperado van juntos o no van" {
        foreach ($e in $catalogo) {
            if ($e.ExeFirma) {
                [string]::IsNullOrWhiteSpace($e.FirmanteEsperado) | Should Be $false
            }
            else {
                [string]::IsNullOrWhiteSpace($e.FirmanteEsperado) | Should Be $true
            }
        }
    }

    It "el ejecutable a firmar es una ruta relativa" {
        foreach ($e in ($catalogo | Where-Object { $_.ExeFirma })) {
            $e.ExeFirma | Should Not Match '^[A-Za-z]:'
            $e.ExeFirma | Should Not Match '\.\.'
        }
    }
}
