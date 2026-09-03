#Requires -Version 5.1
<#
    Pruebas de los shells .bat que genera el kit.

    El caso que importa es una carpeta con &, %, ^, comilla simple y espacios:
    todos legales en Windows y ninguno presente en la maquina de quien desarrolla
    esto, que es justo por lo que hacen falta pruebas y no una comprobacion a
    mano. "Marks & Spencer" es un nombre de carpeta corporativa de lo mas normal.

    Se comprueban las dos direcciones:
      generar  ->  el .bat funciona de verdad al ejecutarlo en cmd
      releer   ->  Use-Env recupera de el la ruta EXACTA
#>

$KitRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $KitRoot "lib\Common.ps1")

# Get-ShellEnvironment vive en Use-Env.ps1, que es un script ejecutable: se
# extrae solo esa funcion por AST para no disparar su programa principal.
$useEnvAst = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-KitScript -Nombre "Use-Env.ps1"), [ref]$null, [ref]$null)
$fnText = ($useEnvAst.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true) | Where-Object { $_.Name -eq 'Get-ShellEnvironment' }).Extent.Text
Invoke-Expression $fnText

$Hostil = Join-Path $env:TEMP "kit-tests-Marks & Spencer 100% ^O'Brien"

# Ejecuta un .bat generado y devuelve el entorno que deja.
function Invoke-ShellBat {
    param([string]$Bat)

    $tmp = Join-Path $env:TEMP ("kit-run-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        # Se copia a una ruta simple: lo que se prueba es el CONTENIDO del shell,
        # no si cmd sabe invocar un archivo cuya propia ruta lleva & y %.
        $copia  = Join-Path $tmp "shell.bat"
        Copy-Item -LiteralPath $Bat -Destination $copia -Force

        # La expansion retardada se activa DESPUES del call: con %PATH% el & del
        # valor se expandiria antes de parsear la linea y cortaria el echo en dos.
        $runner = Join-Path $tmp "runner.cmd"
        Set-Content -LiteralPath $runner -Encoding ASCII -Value @(
            '@echo off',
            'call "%~1" < nul',
            'setlocal enabledelayedexpansion',
            'echo ===PATH===!PATH!',
            'echo ===JAVA_HOME===!JAVA_HOME!',
            'echo ===NPM_CONFIG_PREFIX===!NPM_CONFIG_PREFIX!',
            'echo ===NPM_CONFIG_CACHE===!NPM_CONFIG_CACHE!'
        )

        $r = Invoke-NativeCommand -FilePath "cmd.exe" -Arguments @('/c', $runner, $copia) -Quiet
        $salida = $r.Output

        function Leer([string]$Clave) {
            if ($salida -match "===$Clave===(.*)") { return $Matches[1].Trim() }
            return ''
        }

        return [PSCustomObject]@{
            # Los parentesis alrededor de la llamada son obligatorios: sin ellos
            # PowerShell lee "-split" como un PARAMETRO de Leer, y el [0] acaba
            # devolviendo la primera letra de la cadena en vez de la primera ruta.
            PrimeraRuta = ((Leer 'PATH') -split ';')[0]
            JavaHome    = Leer 'JAVA_HOME'
            NpmPrefix   = Leer 'NPM_CONFIG_PREFIX'
            NpmCache    = Leer 'NPM_CONFIG_CACHE'
            Salida      = $salida
        }
    }
    finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe "Shells generados con una ruta hostil" {

    BeforeEach {
        if (Test-Path -LiteralPath $Hostil) { Remove-Item -LiteralPath $Hostil -Recurse -Force }
        New-Item -ItemType Directory -Path $Hostil -Force | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $Hostil -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context "Python" {

        It "deja el PATH correcto al ejecutarlo y se puede releer" {
            $dir = Join-Path $Hostil "python-3.12"
            New-Item -ItemType Directory -Path (Join-Path $dir "Scripts") -Force | Out-Null

            $bat = Write-PythonShell -PythonPath $dir -Version "3.12"

            (Invoke-ShellBat -Bat $bat).PrimeraRuta | Should Be $dir
            (Get-ShellEnvironment -ShellBat $bat).Paths[0] | Should Be $dir
        }

        It "usa la forma con comillas de set" {
            $dir = Join-Path $Hostil "python-3.12"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $bat = Write-PythonShell -PythonPath $dir -Version "3.12"

            (Get-Content $bat | Where-Object { $_ -like 'set *PATH=*' }) | Should Match '^set "PATH='
        }
    }

    Context "Java" {

        It "deja PATH y JAVA_HOME correctos, y el echo no rompe cmd" {
            $dir = Join-Path $Hostil "jdk-21"
            New-Item -ItemType Directory -Path (Join-Path $dir "bin") -Force | Out-Null

            $bat = Write-JavaShell -JdkPath $dir -Major "21" -Release "jdk-21.0.12+8"
            $r = Invoke-ShellBat -Bat $bat

            $r.PrimeraRuta | Should Be (Join-Path $dir "bin")
            $r.JavaHome    | Should Be $dir

            # Sin escapar, el & partia la linea y cmd intentaba ejecutar el resto
            # como un comando.
            $r.Salida | Should Match ([regex]::Escape("JAVA_HOME: $dir"))
            $r.Salida | Should Not Match 'no se reconoce|is not recognized'
        }

        It "se puede releer PATH y JAVA_HOME" {
            $dir = Join-Path $Hostil "jdk-21"
            New-Item -ItemType Directory -Path (Join-Path $dir "bin") -Force | Out-Null
            $bat = Write-JavaShell -JdkPath $dir -Major "21" -Release "jdk-21.0.12+8"

            $leido = Get-ShellEnvironment -ShellBat $bat
            $leido.Paths[0]          | Should Be (Join-Path $dir "bin")
            $leido.Vars['JAVA_HOME'] | Should Be $dir
        }
    }

    Context "Angular" {

        It "deja PATH y las NPM_CONFIG_* correctas" {
            $ang  = Join-Path $Hostil "angular-v20"
            $node = Join-Path $Hostil "node-v22.23.2-win-x64"
            New-Item -ItemType Directory -Path $ang, $node -Force | Out-Null

            $bat = Write-AngularShell -AngularPath $ang -NodePath $node -Version "20" -NodeVersion "22.23.2"
            $r = Invoke-ShellBat -Bat $bat

            $r.PrimeraRuta | Should Be $node
            $r.NpmPrefix   | Should Be (Join-Path $ang "npm-global")
            $r.NpmCache    | Should Be (Join-Path $Hostil "npm-cache")
            $r.Salida      | Should Not Match 'no se reconoce|is not recognized'
        }

        It "se pueden releer las dos rutas y las dos variables" {
            $ang  = Join-Path $Hostil "angular-v20"
            $node = Join-Path $Hostil "node-v22.23.2-win-x64"
            New-Item -ItemType Directory -Path $ang, $node -Force | Out-Null
            $bat = Write-AngularShell -AngularPath $ang -NodePath $node -Version "20" -NodeVersion "22.23.2"

            $leido = Get-ShellEnvironment -ShellBat $bat
            $leido.Paths.Count                 | Should Be 2
            $leido.Paths[0]                    | Should Be $node
            $leido.Vars['NPM_CONFIG_PREFIX']   | Should Be (Join-Path $ang "npm-global")
            $leido.Vars['NPM_CONFIG_CACHE']    | Should Be (Join-Path $Hostil "npm-cache")
        }
    }
}

Describe "Get-ShellEnvironment con shells del formato antiguo" {

    # Los shells generados por una version anterior del kit no llevan comillas y
    # siguen en disco tras actualizar. Si dejaran de entenderse, Use-Env no
    # activaria nada y sin decir por que.
    It "sigue leyendo un shell sin comillas" {
        $tmp = Join-Path $env:TEMP ("kit-viejo-" + [Guid]::NewGuid().ToString('N') + ".bat")
        $node   = 'C:\Users\test\Angular\node-v22.23.2-win-x64'
        $prefix = 'C:\Users\test\Angular\angular-v20\npm-global'
        Set-Content -LiteralPath $tmp -Encoding ASCII -Value @(
            '@echo off',
            "set PATH=$node;$prefix;%PATH%",
            "set NPM_CONFIG_PREFIX=$prefix",
            'cmd /k'
        )
        try {
            $leido = Get-ShellEnvironment -ShellBat $tmp
            $leido.Paths.Count               | Should Be 2
            $leido.Paths[0]                  | Should Be $node
            $leido.Vars['NPM_CONFIG_PREFIX'] | Should Be $prefix
        }
        finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It "devuelve nulo si el shell no existe" {
        Get-ShellEnvironment -ShellBat (Join-Path $env:TEMP "no-existe-jamas.bat") | Should BeNullOrEmpty
    }
}

Describe "Escapado de codigo generado" {

    Context "ConvertTo-PsLiteral (comillas simples de PowerShell)" {

        # Sintoma: un usuario llamado O'Brien producia un activate.ps1 roto, y
        # como lo carga el perfil, TODAS las terminales nuevas fallaban al abrir.
        It "duplica la comilla simple" {
            ConvertTo-PsLiteral "C:\Users\O'Brien" | Should Be "C:\Users\O''Brien"
        }

        It "deja intacto lo que no lleva comilla" {
            ConvertTo-PsLiteral 'C:\Users\crisr' | Should Be 'C:\Users\crisr'
        }

        # Lo escapado tiene que volver a valer EXACTAMENTE lo de partida al
        # evaluarlo como literal de PowerShell.
        It "el literal resultante vale lo mismo que la entrada" -TestCases @(
            @{ Ruta = "C:\Users\O'Brien\activate.ps1" }
            @{ Ruta = 'C:\Users\dev$user\activate.ps1' }
            @{ Ruta = 'C:\Users\a`b\activate.ps1' }
        ) {
            param($Ruta)
            $codigo = "'{0}'" -f (ConvertTo-PsLiteral $Ruta)
            (& ([scriptblock]::Create($codigo))) | Should Be $Ruta
        }
    }

    Context "ConvertTo-CmdLiteral (dentro de set `"VAR=...`")" {

        It "duplica el porcentaje" {
            ConvertTo-CmdLiteral 'C:\datos 100%' | Should Be 'C:\datos 100%%'
        }

        # Las comillas del set ya cubren estos, asi que NO deben tocarse: si se
        # escaparan, el valor final llevaria circunflejos de mas.
        It "no toca & ^ ni los espacios, que ya cubren las comillas" {
            ConvertTo-CmdLiteral 'C:\Marks & Spencer ^dev' | Should Be 'C:\Marks & Spencer ^dev'
        }
    }

    Context "ConvertFrom-CmdLiteral (al releer un shell generado)" {

        # Sin esto, una ruta con porcentaje se reescapaba en cada pasada de
        # Use-Env: %% -> %%%% -> %%%%%%%%
        It "deshace exactamente lo que hizo ConvertTo-CmdLiteral" -TestCases @(
            @{ Ruta = 'C:\datos 100%' }
            @{ Ruta = 'C:\Marks & Spencer 100% ^dev' }
            @{ Ruta = 'C:\normal\sin\nada' }
        ) {
            param($Ruta)
            ConvertFrom-CmdLiteral (ConvertTo-CmdLiteral $Ruta) | Should Be $Ruta
        }
    }

    Context "ConvertTo-CmdEchoText (linea echo, sin comillas posibles)" {

        It "escapa los especiales de cmd" {
            ConvertTo-CmdEchoText 'Marks & Spencer' | Should Be 'Marks ^& Spencer'
            ConvertTo-CmdEchoText 'a|b' | Should Be 'a^|b'
            ConvertTo-CmdEchoText 'a<b>c' | Should Be 'a^<b^>c'
            ConvertTo-CmdEchoText '100%' | Should Be '100%%'
        }

        # El circunflejo va PRIMERO por ser el propio caracter de escape. Si se
        # hiciera al final, escaparia los que se acaban de anadir y saldria
        # "Marks ^^& Spencer", que imprime un circunflejo de mas.
        It "escapa el circunflejo antes que el resto" {
            ConvertTo-CmdEchoText '^' | Should Be '^^'
            ConvertTo-CmdEchoText '^&' | Should Be '^^^&'
        }
    }
}
