#Requires -Version 5.1
<#
    Pruebas de lib\Runtimes.ps1.

    Casi todas cubren un fallo que existio de verdad. Se anotan con el sintoma
    que producian, porque un test sin contexto se acaba borrando cuando estorba.
#>

. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

Describe "Git portable" {

    Context "Get-Sha256FromReleaseBody" {

        # Git for Windows publica los checksums en el CUERPO de la release, en
        # una tabla de texto libre. No es un campo de la API, asi que hay que
        # buscar la linea del archivo exacto.
        $cuerpo = @"
Please note that this is a maintenance release.

Filename | SHA-256
-------- | -------
Git-2.55.0.5-64-bit.exe | d065a4e23c3d9a6b5073d609b5be0830227ec3ca053c083ba385061ddfaf94c6
PortableGit-2.55.0.5-64-bit.7z.exe | 5aa8a20f6e9abb2c755f0e73c91c687701a46b309ad84a0ca6509380fa4ae290
MinGit-2.55.0.5-64-bit.zip | 56d7b226b7693196cfc71fef26568f536c4a021ab6c37ff2db4287bed908e96e
"@

        It "encuentra el hash del archivo pedido" {
            Get-Sha256FromReleaseBody -Body $cuerpo -FileName 'PortableGit-2.55.0.5-64-bit.7z.exe' |
                Should Be '5aa8a20f6e9abb2c755f0e73c91c687701a46b309ad84a0ca6509380fa4ae290'
        }

        # Los nombres se parecen mucho entre si; coger el de al lado seria dar
        # por bueno un archivo que no es.
        It "no confunde un archivo con otro de nombre parecido" {
            Get-Sha256FromReleaseBody -Body $cuerpo -FileName 'MinGit-2.55.0.5-64-bit.zip' |
                Should Be '56d7b226b7693196cfc71fef26568f536c4a021ab6c37ff2db4287bed908e96e'
        }

        It "devuelve nulo si ese archivo no esta en la tabla" {
            Get-Sha256FromReleaseBody -Body $cuerpo -FileName 'PortableGit-9.9.9-arm64.7z.exe' |
                Should BeNullOrEmpty
        }

        It "ignora la fila de cabecera y la de guiones" {
            Get-Sha256FromReleaseBody -Body $cuerpo -FileName 'Filename' | Should BeNullOrEmpty
            Get-Sha256FromReleaseBody -Body $cuerpo -FileName '--------' | Should BeNullOrEmpty
        }

        It "descarta lo que no tenga forma de SHA-256" {
            $malo = "PortableGit-1.0-64-bit.7z.exe | pendiente de publicar"
            Get-Sha256FromReleaseBody -Body $malo -FileName 'PortableGit-1.0-64-bit.7z.exe' |
                Should BeNullOrEmpty
        }

        It "tolera un cuerpo vacio o nulo" {
            Get-Sha256FromReleaseBody -Body ''   -FileName 'x' | Should BeNullOrEmpty
            Get-Sha256FromReleaseBody -Body $null -FileName 'x' | Should BeNullOrEmpty
        }
    }

    Context "Get-GitPortableAsset" {

        function ReleaseFalsa {
            param([string[]]$Nombres)
            return [PSCustomObject]@{
                tag_name = 'v2.55.0.windows.5'
                body     = "Filename | SHA-256`nPortableGit-2.55.0.5-64-bit.7z.exe | 5aa8a20f6e9abb2c755f0e73c91c687701a46b309ad84a0ca6509380fa4ae290"
                assets   = @($Nombres | ForEach-Object {
                    [PSCustomObject]@{ name = $_; browser_download_url = "https://ejemplo/$_" }
                })
            }
        }

        It "escoge el autoextraible de 64 bits y saca su version" {
            $r = Get-GitPortableAsset -Release (ReleaseFalsa @(
                'Git-2.55.0.5-64-bit.exe'
                'PortableGit-2.55.0.5-64-bit.7z.exe'
                'MinGit-2.55.0.5-64-bit.zip'))
            $r.Version  | Should Be '2.55.0.5'
            $r.FileName | Should Be 'PortableGit-2.55.0.5-64-bit.7z.exe'
            $r.Sha256   | Should Be '5aa8a20f6e9abb2c755f0e73c91c687701a46b309ad84a0ca6509380fa4ae290'
        }

        # Las releases traen tambien el de arm64, que en este equipo no sirve.
        It "no coge el de arm64" {
            $r = Get-GitPortableAsset -Release (ReleaseFalsa @('PortableGit-2.55.0.5-arm64.7z.exe'))
            $r | Should BeNullOrEmpty
        }

        It "devuelve nulo si la release no publica PortableGit" {
            $r = Get-GitPortableAsset -Release (ReleaseFalsa @('Git-2.55.0.5-64-bit.exe'))
            $r | Should BeNullOrEmpty
        }

        # Que falte el checksum no debe impedir instalar: se avisa y se sigue.
        It "sin checksum en el cuerpo, devuelve el resto igualmente" {
            $rel = ReleaseFalsa @('PortableGit-2.55.0.5-64-bit.7z.exe')
            $rel.body = 'sin tabla de checksums'
            $r = Get-GitPortableAsset -Release $rel
            $r.Version | Should Be '2.55.0.5'
            $r.Sha256  | Should BeNullOrEmpty
        }
    }

    Context "ConvertFrom-GitVersionOutput" {

        # Habia tres sitios parseando "git --version" cada uno a su manera, y
        # uno lo hacia mal: con [\d.]+ el cuantificador voraz se comia tambien
        # el punto de ".windows", asi que quedaba "2.55.0." y el sufijo ya no
        # encajaba. Se veia como "Git 2.55.0." al listar lo instalado.
        It "convierte la salida de Git for Windows al nombre del archivo publicado" {
            ConvertFrom-GitVersionOutput -Output 'git version 2.55.0.windows.5' | Should Be '2.55.0.5'
        }

        It "no deja el punto colgando" {
            (ConvertFrom-GitVersionOutput -Output 'git version 2.55.0.windows.5') |
                Should Not Match '\.$'
        }

        It "admite un numero de windows de dos cifras" {
            ConvertFrom-GitVersionOutput -Output 'git version 2.49.0.windows.12' | Should Be '2.49.0.12'
        }

        It "un Git que no sea el de Windows no lleva sufijo" {
            ConvertFrom-GitVersionOutput -Output 'git version 2.44.1' | Should Be '2.44.1'
        }

        It "tolera espacios y saltos alrededor" {
            ConvertFrom-GitVersionOutput -Output "`r`n  git version 2.55.0.windows.5  `r`n" | Should Be '2.55.0.5'
        }

        It "devuelve nulo con vacio o con algo que no es una version" {
            ConvertFrom-GitVersionOutput -Output ''      | Should BeNullOrEmpty
            ConvertFrom-GitVersionOutput -Output $null   | Should BeNullOrEmpty
            ConvertFrom-GitVersionOutput -Output 'error' | Should BeNullOrEmpty
        }

        It "lo que devuelve sirve para nombrar la carpeta" {
            $v = ConvertFrom-GitVersionOutput -Output 'git version 2.55.0.windows.5'
            Get-GitLine -Version $v | Should Be '2.55'
        }
    }

    Context "Get-HashFromChecksumText" {

        # No hay un formato unico para los archivos de checksum sueltos. Apache
        # publica el hash a secas, sha256sum pone "hash  archivo", y algun mirror
        # invierte el orden.
        It "acepta el hash a secas, como lo publica Apache" {
            $h = 'a' * 128
            Get-HashFromChecksumText -Text $h -Algorithm SHA512 | Should Be $h
        }

        It "acepta el formato de sha256sum" {
            $h = 'b' * 64
            Get-HashFromChecksumText -Text "$h  gradle-9.7.1-bin.zip" | Should Be $h
        }

        It "acepta el formato con el nombre delante" {
            $h = 'c' * 64
            Get-HashFromChecksumText -Text "gradle-9.7.1-bin.zip: $h" | Should Be $h
        }

        It "normaliza a minusculas" {
            Get-HashFromChecksumText -Text ('AB' * 32) | Should Be ('ab' * 32)
        }

        # Si el servidor devuelve una pagina de error en vez del checksum, dar
        # por bueno cualquier trozo hexadecimal seria peor que no verificar.
        It "no da por bueno un hash de longitud equivocada" {
            Get-HashFromChecksumText -Text ('a' * 64) -Algorithm SHA512 | Should BeNullOrEmpty
            Get-HashFromChecksumText -Text ('a' * 128) -Algorithm SHA256 | Should BeNullOrEmpty
        }

        It "no encuentra nada en una pagina de error" {
            Get-HashFromChecksumText -Text '<html><body>404 Not Found</body></html>' | Should BeNullOrEmpty
        }

        It "tolera vacio y nulo" {
            Get-HashFromChecksumText -Text ''    | Should BeNullOrEmpty
            Get-HashFromChecksumText -Text $null | Should BeNullOrEmpty
        }
    }

    Context "Get-ToolLine" {

        It "reduce a linea las versiones de Maven y Gradle" {
            Get-ToolLine -Version '3.9.16' | Should Be '3.9'
            Get-ToolLine -Version '9.7.1'  | Should Be '9.7'
        }

        It "dos parches de la misma linea dan la misma carpeta" {
            (Get-ToolLine -Version '3.9.6') | Should Be (Get-ToolLine -Version '3.9.16')
        }

        It "Get-GitLine delega en el, asi que dan lo mismo" {
            Get-GitLine -Version '2.55.0.5' | Should Be (Get-ToolLine -Version '2.55.0.5')
        }
    }

    Context "Get-GitLine" {

        # La carpeta se llama por la linea (git-2.55), no por la version
        # completa: si no, cada parche crearia una carpeta nueva y -Force
        # instalaria al lado en vez de reemplazar. Misma leccion que con Node.
        It "reduce la version a su linea" {
            Get-GitLine -Version '2.55.0.5' | Should Be '2.55'
            Get-GitLine -Version '2.56.1.1' | Should Be '2.56'
        }

        It "tolera la v inicial" {
            Get-GitLine -Version 'v2.55.0.5' | Should Be '2.55'
        }

        It "dos parches de la misma linea dan la misma carpeta" {
            (Get-GitLine -Version '2.55.0.1') | Should Be (Get-GitLine -Version '2.55.0.5')
        }
    }
}

Describe "Version de un JDK" {

    Context "Get-JavaMajor" {

        # Sin normalizar el esquema antiguo, comparar versiones daria que un
        # Java 8 ("1.8.0_202") es MAS NUEVO que un Java 25, y el aviso de
        # JAVA_HOME obsoleto no saltaria nunca. Es el caso real que lo motivo.
        It "entiende el esquema antiguo: 1.8.0_202 es Java 8" {
            Get-JavaMajor -Version '1.8.0_202' | Should Be 8
        }

        It "entiende el esquema moderno" {
            Get-JavaMajor -Version '25.0.4.1' | Should Be 25
            Get-JavaMajor -Version '24.0.2'   | Should Be 24
        }

        It "un Java 8 es MENOR que un Java 25, que es lo que hay que detectar" {
            (Get-JavaMajor -Version '1.8.0_202') -lt (Get-JavaMajor -Version '25.0.4.1') | Should Be $true
        }

        It "1.7.0 es Java 7 y no Java 1" {
            Get-JavaMajor -Version '1.7.0_80' | Should Be 7
        }

        It "tolera vacio, nulo y basura" {
            Get-JavaMajor -Version ''      | Should BeNullOrEmpty
            Get-JavaMajor -Version $null   | Should BeNullOrEmpty
            Get-JavaMajor -Version 'nada'  | Should BeNullOrEmpty
        }
    }

    Context "Get-JdkVersionAt" {

        # Se lee del archivo "release" que todo JDK trae en su raiz: es
        # instantaneo y funciona aunque ese JDK este roto.
        It "lee la version del archivo release" {
            $d = Join-Path ([System.IO.Path]::GetTempPath()) ("jdk-" + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            try {
                Set-Content -LiteralPath (Join-Path $d "release") -Value @(
                    'IMPLEMENTOR="Eclipse Adoptium"'
                    'JAVA_VERSION="25.0.4.1"'
                    'OS_ARCH="x86_64"'
                )
                Get-JdkVersionAt -JavaHome $d | Should Be '25.0.4.1'
            }
            finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
        }

        It "devuelve nulo si la carpeta no existe" {
            Get-JdkVersionAt -JavaHome 'C:\no-existe-este-jdk' | Should BeNullOrEmpty
        }

        It "tolera vacio y nulo" {
            Get-JdkVersionAt -JavaHome ''    | Should BeNullOrEmpty
            Get-JdkVersionAt -JavaHome $null | Should BeNullOrEmpty
        }

        It "devuelve nulo si hay carpeta pero no es un JDK" {
            $d = Join-Path ([System.IO.Path]::GetTempPath()) ("nojdk-" + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            try { Get-JdkVersionAt -JavaHome $d | Should BeNullOrEmpty }
            finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

Describe "Constructores de URL de descarga" {

    It "Get-NodeArchiveInfo compone la URL y el nombre de carpeta" {
        $i = Get-NodeArchiveInfo -Version '22.23.2'
        $i.FolderName | Should Be 'node-v22.23.2-win-x64'
        $i.Url        | Should Be 'https://nodejs.org/dist/v22.23.2/node-v22.23.2-win-x64.zip'
        $i.ShasumsUrl | Should Be 'https://nodejs.org/dist/v22.23.2/SHASUMS256.txt'
    }

    It "Get-NodeArchiveInfo tolera la v inicial" {
        (Get-NodeArchiveInfo -Version 'v22.23.2').FolderName | Should Be 'node-v22.23.2-win-x64'
    }

    It "Get-PythonArchiveInfo apunta al zip embeddable" {
        (Get-PythonArchiveInfo -FullVersion '3.12.10').Url |
            Should Be 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip'
    }
}

Describe "Un shell de Maven/Gradle por cada JDK" {

    # Quien trabaja a diario en proyectos que piden Javas distintos no puede
    # reejecutar el Setup cada vez que cambia de proyecto. Estas pruebas fijan
    # que exista un shell por JDK y que cada uno apunte al SUYO: si todos
    # acabaran en el mismo JAVA_HOME el resultado seria una compilacion con el
    # Java equivocado, que es un fallo silencioso.

    $raizReal = $WorkspaceRoot
    $falso    = Join-Path $env:TEMP ("kit-multijdk-" + [Guid]::NewGuid().ToString('N'))

    function New-JdkFalso {
        param([string]$Linea)
        $bin = Join-Path (Join-Path (Join-Path $falso "Java") "jdk-$Linea") "bin"
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $bin "java.exe") -Value "" -Encoding ASCII
    }

    function New-HerramientaFalsa {
        param([string]$Nombre)
        $p = Join-Path $falso $Nombre
        New-Item -ItemType Directory -Path (Join-Path $p "bin") -Force | Out-Null
        return $p
    }

    BeforeEach {
        if (Test-Path -LiteralPath $falso) { Remove-Item -LiteralPath $falso -Recurse -Force }
        New-Item -ItemType Directory -Path $falso -Force | Out-Null
        $script:WorkspaceRoot = $falso
    }

    AfterEach {
        $script:WorkspaceRoot = $raizReal
        Remove-Item -LiteralPath $falso -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context "Get-KitJdkLines" {

        # Ordenar como texto pondria "21" antes que "9". Con Java 8 y Java 21
        # instalados eso haria que "el mas alto" fuera el 8.
        It "ordena por numero y no como texto" {
            New-JdkFalso 21; New-JdkFalso 8; New-JdkFalso 25
            (Get-KitJdkLines) -join ',' | Should Be '8,21,25'
        }

        It "no cuenta una carpeta sin java.exe" {
            New-JdkFalso 21
            New-Item -ItemType Directory -Path (Join-Path $falso "Java\jdk-99") -Force | Out-Null
            (Get-KitJdkLines) -join ',' | Should Be '21'
        }

        It "sin carpeta Java devuelve vacio" {
            (Get-KitJdkLines).Count | Should Be 0
        }
    }

    Context "Resolve-KitJdk" {

        It "devuelve el JDK que se le pide" {
            New-JdkFalso 21; New-JdkFalso 25
            Resolve-KitJdk -Linea '21' | Should Be (Join-Path $falso "Java\jdk-21")
        }

        It "devuelve nulo si esa linea no esta instalada" {
            New-JdkFalso 25
            Resolve-KitJdk -Linea '21' | Should BeNullOrEmpty
        }

        It "sin linea se queda con el mas alto, como antes" {
            New-JdkFalso 21; New-JdkFalso 25
            Resolve-KitJdk | Should Be (Join-Path $falso "Java\jdk-25")
        }
    }

    Context "Write-BuildToolShell -SufijoJdk" {

        It "nombra el archivo con el JDK al que ata" {
            $mvn = New-HerramientaFalsa "maven-3.9"
            $f = Write-BuildToolShell -Tool Maven -ToolPath $mvn -Version '3.9.11' `
                                      -JavaHome 'C:\jdk-21' -SufijoJdk '21'
            Split-Path -Leaf $f | Should Be 'mvn39-java21-shell.bat'
        }

        It "sin sufijo mantiene el nombre de siempre" {
            $mvn = New-HerramientaFalsa "maven-3.9"
            $f = Write-BuildToolShell -Tool Maven -ToolPath $mvn -Version '3.9.11' -JavaHome 'C:\jdk-21'
            Split-Path -Leaf $f | Should Be 'mvn39-shell.bat'
        }
    }

    Context "Write-BuildToolShellsPorJdk" {

        It "escribe uno por JDK y cada uno apunta al suyo" {
            New-JdkFalso 21; New-JdkFalso 25
            $g = New-HerramientaFalsa "gradle-9.7"

            $hechos = (Write-BuildToolShellsPorJdk -Tool Gradle -ToolPath $g -Version '9.7.1').Escritos
            $hechos.Count | Should Be 2

            foreach ($h in $hechos) {
                $null = (Split-Path -Leaf $h) -match '-java(\d+)-shell\.bat$'
                $linea = $Matches[1]
                $jh = ([regex]::Match((Get-Content -LiteralPath $h -Raw), 'set "JAVA_HOME=([^"]+)"')).Groups[1].Value
                Split-Path -Leaf $jh | Should Be "jdk-$linea"
            }
        }

        # Con un solo JDK el shell normal ya apunta ahi: un segundo archivo
        # identico solo haria dudar de cual abrir.
        It "con un solo JDK no escribe ninguno" {
            New-JdkFalso 25
            $g = New-HerramientaFalsa "gradle-9.7"
            (Write-BuildToolShellsPorJdk -Tool Gradle -ToolPath $g -Version '9.7.1').Escritos.Count | Should Be 0
        }

        # Un shell que exporta un JAVA_HOME inexistente hace fallar la compilacion
        # con un error de Java que no menciona la desinstalacion.
        It "borra el shell de un JDK que ya no esta" {
            New-JdkFalso 21; New-JdkFalso 25
            $g = New-HerramientaFalsa "gradle-9.7"
            Write-BuildToolShellsPorJdk -Tool Gradle -ToolPath $g -Version '9.7.1' | Out-Null
            Test-Path (Join-Path $g "gradle97-java21-shell.bat") | Should Be $true

            Remove-Item -LiteralPath (Join-Path $falso "Java\jdk-21") -Recurse -Force
            Write-BuildToolShellsPorJdk -Tool Gradle -ToolPath $g -Version '9.7.1' | Out-Null

            Test-Path (Join-Path $g "gradle97-java21-shell.bat") | Should Be $false
            Test-Path (Join-Path $g "gradle97-java25-shell.bat") | Should Be $false
        }

        It "no toca el shell por defecto al limpiar" {
            New-JdkFalso 25
            $g = New-HerramientaFalsa "gradle-9.7"
            Write-BuildToolShell -Tool Gradle -ToolPath $g -Version '9.7.1' -JavaHome (Join-Path $falso "Java\jdk-25") | Out-Null
            Write-BuildToolShellsPorJdk -Tool Gradle -ToolPath $g -Version '9.7.1' | Out-Null
            Test-Path (Join-Path $g "gradle97-shell.bat") | Should Be $true
        }
    }

    Context "Los JDK del kit dentro de VS Code" {

        # El identificador no es libre: la extension de Java espera el nombre
        # oficial de la plataforma, y el 8 se llama JavaSE-1.8 y no JavaSE-8.
        It "nombra cada JDK como espera la extension" {
            New-JdkFalso 8; New-JdkFalso 21
            $e = @(Get-KitJavaRuntimeEntries)
            ($e.name -join ',') | Should Be 'JavaSE-1.8,JavaSE-21'
        }

        It "marca por defecto el que se le diga, y solo ese" {
            New-JdkFalso 21; New-JdkFalso 25
            $e = @(Get-KitJavaRuntimeEntries -Default '21')
            @($e | Where-Object { $_.default }).Count | Should Be 1
            ($e | Where-Object { $_.default }).name   | Should Be 'JavaSE-21'
        }

        It "sin default no marca ninguno" {
            New-JdkFalso 21
            @((Get-KitJavaRuntimeEntries) | Where-Object { $_.default }).Count | Should Be 0
        }

    }

    # Aparte y no dentro del anterior: Pester 3.4 -el que trae Windows- no
    # admite un Context dentro de otro.
    Context "Extensiones de un VS Code" {

        function New-PortableFalso {
            param([string[]]$Carpetas, [string[]]$Obsoletas)

            $raiz = Join-Path $falso "VSCode\vscode-1.136"
            $ext  = Join-Path $raiz "data\extensions"
            New-Item -ItemType Directory -Path $ext -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $raiz "data\user-data\User") -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $raiz "bin") -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $raiz "bin\code.cmd") -Value "" -Encoding ASCII
            # Get-VSCodeSettingsTargets exige el ejecutable, no solo la carpeta.
            Set-Content -LiteralPath (Join-Path $raiz "Code.exe") -Value "" -Encoding ASCII

            foreach ($c in $Carpetas) { New-Item -ItemType Directory -Path (Join-Path $ext $c) -Force | Out-Null }

            if ($Obsoletas) {
                $o = [ordered]@{}
                foreach ($c in $Obsoletas) { $o[$c] = $true }
                ([PSCustomObject]$o | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $ext ".obsolete") -Encoding ASCII
            }

            return (Join-Path $raiz "data\user-data\User\settings.json")
        }

        It "lee las extensiones de la carpeta" {
            $s = New-PortableFalso -Carpetas @('redhat.java-1.55.0-win32-x64', 'vscjava.vscode-maven-0.45.3')
            $e = @(Get-VSCodeExtensions -SettingsPath $s)
            ($e -join ',') | Should Be 'redhat.java,vscjava.vscode-maven'
        }

        # Al desinstalar, VS Code dice "successfully uninstalled" y deja la
        # carpeta hasta el siguiente arranque. Sin mirar .obsolete, una extension
        # retirada seguia constando como instalada.
        It "no cuenta una extension ya desinstalada" {
            $s = New-PortableFalso -Carpetas @('redhat.java-1.55.0-win32-x64') `
                                   -Obsoletas @('redhat.java-1.55.0-win32-x64')
            @(Get-VSCodeExtensions -SettingsPath $s).Count | Should Be 0
        }

        # Caso real: una version vieja marcada obsoleta y la nueva instalada.
        It "con dos versiones y la vieja obsoleta, la extension sigue estando" {
            $s = New-PortableFalso -Carpetas @('redhat.java-1.53.0-win32-x64', 'redhat.java-1.55.0-win32-x64') `
                                   -Obsoletas @('redhat.java-1.53.0-win32-x64')
            @(Get-VSCodeExtensions -SettingsPath $s) | Should Be 'redhat.java'
        }

        # Un portable sin carpeta de extensiones: recien instalado, antes de
        # arrancarlo por primera vez.
        It "un portable sin carpeta de extensiones devuelve vacio" {
            $s = Join-Path $falso "VSCode\vscode-1.136\data\user-data\User\settings.json"
            @(Get-VSCodeExtensions -SettingsPath $s).Count | Should Be 0
        }

        It "encuentra el code.cmd del portable a partir de su settings.json" {
            $s = New-PortableFalso -Carpetas @()
            Split-Path -Leaf (Get-VSCodeCli -SettingsPath $s) | Should Be 'code.cmd'
        }

        # El VS Code del equipo es del usuario y no lo gestiona el kit, asi que
        # los dos se distinguen: el comando solo entra en el segundo si se pide.
        It "marca cual es del kit y cual del equipo" {
            New-PortableFalso -Carpetas @() | Out-Null
            $t = @(Get-VSCodeSettingsTargets)
            @($t | Where-Object { $_.DelKit }).Count | Should Be 1
            ($t | Where-Object { $_.DelKit }).Ruta | Should Match 'user-data'
        }
    }

    Context "Sync-VSCodeJavaRuntimes" {

        # Mismo motivo que Sync-BuildToolShells: instalar o quitar un JDK tiene
        # que notarse donde el kit ya lo tiene anotado, sin reejecutar nada.

        function New-PortableConAjustes {
            param([string]$Json)

            $raiz = Join-Path $falso "VSCode\vscode-1.136"
            New-Item -ItemType Directory -Path (Join-Path $raiz "data\user-data\User") -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $raiz "Code.exe") -Value "" -Encoding ASCII

            $s = Join-Path $raiz "data\user-data\User\settings.json"
            if ($null -ne $Json) { Set-Content -LiteralPath $s -Value $Json -Encoding UTF8 }
            return $s
        }

        function Runtimes($ruta) {
            if (-not (Test-Path -LiteralPath $ruta)) { return @() }
            $j = Get-Content -LiteralPath $ruta -Raw | ConvertFrom-Json
            if (-not $j.PSObject.Properties['java.configuration.runtimes']) { return @() }
            return @($j.'java.configuration.runtimes')
        }

        It "anade el JDK nuevo donde ya habia registrados" {
            New-JdkFalso 21
            $s = New-PortableConAjustes ("{ ""java.configuration.runtimes"": [ { ""name"": ""JavaSE-21"", ""path"": ""$(($falso -replace '\\','\\'))\\Java\\jdk-21"", ""default"": true } ] }")

            New-JdkFalso 25
            $r = @(Sync-VSCodeJavaRuntimes)

            (Runtimes $s).name -join ',' | Should Be 'JavaSE-21,JavaSE-25'
            $r.Count | Should Be 1
        }

        # Cambiar el JDK por defecto porque aparezca otro seria decidir con que
        # compila el usuario sin avisarle.
        It "respeta el JDK por defecto que ya estaba elegido" {
            New-JdkFalso 21
            $s = New-PortableConAjustes ("{ ""java.configuration.runtimes"": [ { ""name"": ""JavaSE-21"", ""path"": ""$(($falso -replace '\\','\\'))\\Java\\jdk-21"", ""default"": true } ] }")

            New-JdkFalso 25
            Sync-VSCodeJavaRuntimes | Out-Null

            (@(Runtimes $s) | Where-Object { $_.default }).name | Should Be 'JavaSE-21'
        }

        It "si el JDK por defecto ya no esta, pasa al mas alto" {
            New-JdkFalso 21; New-JdkFalso 25
            $s = New-PortableConAjustes ("{ ""java.configuration.runtimes"": [ { ""name"": ""JavaSE-21"", ""path"": ""$(($falso -replace '\\','\\'))\\Java\\jdk-21"", ""default"": true } ] }")

            Remove-Item -LiteralPath (Join-Path $falso "Java\jdk-21") -Recurse -Force
            Sync-VSCodeJavaRuntimes | Out-Null

            (@(Runtimes $s) | Where-Object { $_.default }).name | Should Be 'JavaSE-25'
        }

        It "retira el JDK que se desinstalo" {
            New-JdkFalso 21; New-JdkFalso 25
            $s = New-PortableConAjustes ("{ ""java.configuration.runtimes"": [ { ""name"": ""JavaSE-21"", ""path"": ""$(($falso -replace '\\','\\'))\\Java\\jdk-21"" }, { ""name"": ""JavaSE-25"", ""path"": ""$(($falso -replace '\\','\\'))\\Java\\jdk-25"", ""default"": true } ] }")

            Remove-Item -LiteralPath (Join-Path $falso "Java\jdk-21") -Recurse -Force
            Sync-VSCodeJavaRuntimes | Out-Null

            (Runtimes $s).name | Should Be 'JavaSE-25'
        }

        # Quien los quito con -Remove no quiere que vuelvan solos al instalar un
        # Java. Mantener al dia lo que alguien pidio es una cosa; decidir por el,
        # otra distinta.
        It "no registra nada donde nadie lo pidio" {
            New-JdkFalso 21
            $s = New-PortableConAjustes '{ "editor.fontSize": 13 }'

            @(Sync-VSCodeJavaRuntimes).Count | Should Be 0
            (Runtimes $s).Count | Should Be 0
        }

        It "-Inicializar registra en un portable recien instalado" {
            New-JdkFalso 21; New-JdkFalso 25
            $s = New-PortableConAjustes $null

            @(Sync-VSCodeJavaRuntimes -Inicializar).Count | Should Be 1
            (Runtimes $s).name -join ',' | Should Be 'JavaSE-21,JavaSE-25'
        }

        # Reinstalar el editor conservando data\ no puede pisar una decision.
        It "-Inicializar no pisa un settings donde ya se opino" {
            New-JdkFalso 21
            $s = New-PortableConAjustes '{ "java.configuration.runtimes": [] }'

            @(Sync-VSCodeJavaRuntimes -Inicializar).Count | Should Be 0
            (Runtimes $s).Count | Should Be 0
        }

        It "conserva los demas ajustes al reescribir" {
            New-JdkFalso 21
            $s = New-PortableConAjustes ("{ ""editor.fontSize"": 13, ""java.configuration.runtimes"": [ { ""name"": ""JavaSE-21"", ""path"": ""$(($falso -replace '\\','\\'))\\Java\\jdk-21"" } ] }")

            New-JdkFalso 25
            Sync-VSCodeJavaRuntimes | Out-Null

            (Get-Content -LiteralPath $s -Raw | ConvertFrom-Json).'editor.fontSize' | Should Be 13
        }

        It "no reescribe si no ha cambiado nada" {
            New-JdkFalso 21
            $s = New-PortableConAjustes ("{ ""java.configuration.runtimes"": [ { ""name"": ""JavaSE-21"", ""path"": ""$(($falso -replace '\\','\\'))\\Java\\jdk-21"", ""default"": true } ] }")
            @(Sync-VSCodeJavaRuntimes).Count | Should Be 0
        }
    }

    Context "Merge-VSCodeJavaRuntimes" {

            $raiz = "C:\kit\Java"
            $delKit = @(
                [PSCustomObject]@{ name = 'JavaSE-21'; path = "$raiz\jdk-21" },
                [PSCustomObject]@{ name = 'JavaSE-25'; path = "$raiz\jdk-25"; default = $true }
            )

            # Quien tenga registrado a mano el JDK de la empresa no puede
            # perderlo por ejecutar un comando que iba de otra cosa.
            It "conserva un JDK ajeno al kit" {
                $actual = @([PSCustomObject]@{ name = 'JavaSE-1.8'; path = 'C:\Program Files\Java\jdk1.8.0_202' })
                $r = @(Merge-VSCodeJavaRuntimes -Actual $actual -DelKit $delKit -RaizJava $raiz)
                $r.Count | Should Be 3
                ($r | Where-Object { $_.name -eq 'JavaSE-1.8' }).path | Should Be 'C:\Program Files\Java\jdk1.8.0_202'
            }

            It "reemplaza los del kit en vez de duplicarlos" {
                $actual = @([PSCustomObject]@{ name = 'JavaSE-21'; path = "$raiz\jdk-21" })
                $r = @(Merge-VSCodeJavaRuntimes -Actual $actual -DelKit $delKit -RaizJava $raiz)
                $r.Count | Should Be 2
            }

            # Dos runtimes por defecto dejan a la extension en un estado que no
            # se puede predecir.
            It "deja un unico default" {
                $actual = @([PSCustomObject]@{ name = 'JavaSE-1.8'; path = 'C:\otro\jdk8'; default = $true })
                $r = @(Merge-VSCodeJavaRuntimes -Actual $actual -DelKit $delKit -RaizJava $raiz)
                @($r | Where-Object { $_.default }).Count | Should Be 1
                ($r | Where-Object { $_.default }).name   | Should Be 'JavaSE-25'
            }

            It "sin default del kit no le quita el suyo al ajeno" {
                $actual = @([PSCustomObject]@{ name = 'JavaSE-1.8'; path = 'C:\otro\jdk8'; default = $true })
                $sinDef = @([PSCustomObject]@{ name = 'JavaSE-21'; path = "$raiz\jdk-21" })
                $r = @(Merge-VSCodeJavaRuntimes -Actual $actual -DelKit $sinDef -RaizJava $raiz)
                ($r | Where-Object { $_.default }).name | Should Be 'JavaSE-1.8'
            }

            It "-Quitar deja solo los ajenos" {
                $actual = @(
                    [PSCustomObject]@{ name = 'JavaSE-21';  path = "$raiz\jdk-21" },
                    [PSCustomObject]@{ name = 'JavaSE-1.8'; path = 'C:\otro\jdk8' }
                )
                $r = @(Merge-VSCodeJavaRuntimes -Actual $actual -DelKit $delKit -RaizJava $raiz -Quitar)
                $r.Count  | Should Be 1
                $r[0].name | Should Be 'JavaSE-1.8'
            }

            It "aguanta un settings.json sin ningun runtime" {
                $r = @(Merge-VSCodeJavaRuntimes -Actual $null -DelKit $delKit -RaizJava $raiz)
                $r.Count | Should Be 2
            }

            # Sin normalizar la barra final, la misma carpeta escrita de dos
            # formas contaria como ajena y quedarian duplicados.
            It "no se le escapa una ruta del kit por la barra final" {
                $actual = @([PSCustomObject]@{ name = 'JavaSE-21'; path = "$raiz\jdk-21\" })
                $r = @(Merge-VSCodeJavaRuntimes -Actual $actual -DelKit $delKit -RaizJava $raiz)
                $r.Count | Should Be 2
            }
    }

    Context "Sync-BuildToolShells" {

        # Se monta un Gradle creible: Sync lee la version del jar, no de ejecutar
        # nada, asi que basta con el nombre del archivo.
        function New-GradleFalso {
            $g = Join-Path $falso "Gradle\gradle-9.7"
            New-Item -ItemType Directory -Path (Join-Path $g "bin") -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $g "lib") -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $g "bin\gradle.bat") -Value "" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $g "lib\gradle-launcher-9.7.1.jar") -Value "" -Encoding ASCII
            return $g
        }

        # Instalar un JDK despues de Gradle tiene que dar shell para el nuevo sin
        # reejecutar Setup-GradleEnv: es justo el caso de trabajar en proyectos
        # con Javas distintos.
        It "al aparecer un segundo JDK escribe los shells sin tocar el Setup" {
            New-JdkFalso 25
            $g = New-GradleFalso
            Write-BuildToolShell -Tool Gradle -ToolPath $g -Version '9.7.1' -JavaHome (Join-Path $falso "Java\jdk-25") | Out-Null

            New-JdkFalso 21
            $r = @(Sync-BuildToolShells)

            Test-Path (Join-Path $g "gradle97-java21-shell.bat") | Should Be $true
            Test-Path (Join-Path $g "gradle97-java25-shell.bat") | Should Be $true
            ($r -join ' ') | Should Match '2 shells'
        }

        # Sin esto, desinstalar el JDK al que apuntaba el shell por defecto deja
        # Gradle roto hasta que alguien reejecute su Setup, y el error que da
        # Java no menciona la desinstalacion.
        It "reapunta el shell por defecto si su JDK desaparecio" {
            New-JdkFalso 21; New-JdkFalso 25
            $g = New-GradleFalso
            Write-BuildToolShell -Tool Gradle -ToolPath $g -Version '9.7.1' -JavaHome (Join-Path $falso "Java\jdk-21") | Out-Null

            Remove-Item -LiteralPath (Join-Path $falso "Java\jdk-21") -Recurse -Force
            $r = @(Sync-BuildToolShells)

            $jh = Get-ShellJavaHome -ShellBat (Join-Path $g "gradle97-shell.bat")
            Split-Path -Leaf $jh | Should Be 'jdk-25'
            ($r -join ' ') | Should Match 'ahora a jdk-25'
        }

        It "no toca el shell por defecto si su JDK sigue ahi" {
            New-JdkFalso 21; New-JdkFalso 25
            $g = New-GradleFalso
            Write-BuildToolShell -Tool Gradle -ToolPath $g -Version '9.7.1' -JavaHome (Join-Path $falso "Java\jdk-21") | Out-Null

            Sync-BuildToolShells | Out-Null

            $jh = Get-ShellJavaHome -ShellBat (Join-Path $g "gradle97-shell.bat")
            Split-Path -Leaf $jh | Should Be 'jdk-21'
        }

        It "sin Maven ni Gradle instalados no dice nada" {
            New-JdkFalso 21; New-JdkFalso 25
            (Sync-BuildToolShells).Count | Should Be 0
        }
    }
}
