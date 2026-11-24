#Requires -Version 5.1
<#
    El paquete de Android para repartir (tools\Build-PaqueteAndroid.ps1): que
    lleve lo que hace falta para que funcione, y nada mas.

    Se genera de verdad en una carpeta temporal. El propio generador ya se
    niega a terminar si al paquete le falta una funcion, si nombra un comando
    que no lleva o si no arranca; aqui se comprueba ademas lo que NO tiene que
    ir, que es lo que se le prometio a quien lo reparte.
#>

$KitRoot = Split-Path -Parent $PSScriptRoot
$RaizTmp = Join-Path ([IO.Path]::GetTempPath()) ("paquete-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))

Describe "El paquete de Android" {

    $env:CRIISDEVKIT_NOLOG = '1'
    $salida = @(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $KitRoot 'tools\Build-PaqueteAndroid.ps1') -Destino $RaizTmp 2>&1 | ForEach-Object { "$_" })
    $codigo = $LASTEXITCODE
    $p = Join-Path $RaizTmp 'CriisDevKit-Android'

    It "se genera, y pasa sus comprobaciones (se lee, no le falta nada, arranca)" {
        if ($codigo -ne 0) { throw ("El generador fallo:`n" + ($salida -join "`n")) }
        ($salida -join "`n") | Should Match 'Comprobado'
    }

    It "lleva el menu, el LEEME, los comandos de Android y su libreria" {
        foreach ($f in 'Android.bat', 'LEEME.md', 'scripts\kit\Menu-Android.ps1', 'scripts\start\Start-AndroidApp.ps1',
                       'scripts\start\Start-AndroidEmulator.ps1', 'scripts\start\Start-AndroidLog.ps1',
                       'scripts\setup\Setup-AndroidEnv.ps1', 'scripts\setup\Setup-JavaEnv.ps1',
                       'lib\Common.ps1', 'lib\Android.ps1', 'lib\Project.ps1') {
            "$f=$(Test-Path -LiteralPath (Join-Path $p $f))" | Should Be "$f=True"
        }
    }

    # Lo prometido: solo lo de Android. Si un dia Android empieza a usar algo
    # de una de estas, que se note aqui y se decida, no que se cuele.
    It "no lleva nada mas del kit" {
        foreach ($f in 'Menu.bat', 'Empezar.bat', 'tests', 'docs', 'tools', 'bin\kit', 'bin\env', 'bin\setup',
                       'lib\Doctor.ps1', 'lib\KitUpdate.ps1', 'lib\VCRuntime.ps1', 'lib\Semver.ps1', 'scripts\env') {
            "$f=$(Test-Path -LiteralPath (Join-Path $p $f))" | Should Be "$f=False"
        }
        (Get-Content -LiteralPath (Join-Path $p 'lib\Common.ps1') -Raw) | Should Not Match 'VCRuntime|Semver'
    }

    It "de la libreria, solo una parte: las funciones que usa Android" {
        $hay = @(Get-ChildItem -LiteralPath (Join-Path $p 'lib') -Filter '*.ps1' | ForEach-Object {
            [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$null).FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) }).Count
        $kit = @(Get-ChildItem -LiteralPath (Join-Path $KitRoot 'lib') -Filter '*.ps1' | ForEach-Object {
            [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$null).FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) }).Count
        $hay | Should BeGreaterThan 50
        $hay | Should BeLessThan ($kit / 2)
    }

    # No es una funcion a la que se llame, sino algo que la libreria hace al
    # cargarse: seguir solo las llamadas lo dejaba fuera.
    It "conserva lo que una libreria hace al cargarse (abrir el registro)" {
        (Get-Content -LiteralPath (Join-Path $p 'lib\UserPath.ps1') -Raw) | Should Match '(?m)^Start-KitLog'
        (Get-Content -LiteralPath (Join-Path $p 'lib\Log.ps1') -Raw) | Should Match 'function Start-KitLog'
    }

    It "habla de su menu, no del del kit" {
        $todo = (Get-ChildItem -LiteralPath $p -Recurse -File -Include '*.ps1', '*.md' | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
        $todo | Should Not Match 'Menu\.bat, opcion 60'
        $todo | Should Match 'Android\.bat, opcion 1'
    }

    It "el .bat del menu va en CRLF y el zip lleva la carpeta dentro" {
        $t = [IO.File]::ReadAllText((Join-Path $p 'Android.bat'))
        ($t -replace "`r`n", '') | Should Not Match "`n"
        $zip = @(Get-ChildItem -LiteralPath $RaizTmp -Filter 'CriisDevKit Android *.zip')[0]
        $zip | Should Not BeNullOrEmpty
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::OpenRead($zip.FullName)
        try { @($z.Entries | Where-Object { $_.FullName -notlike 'CriisDevKit-Android/*' }).Count | Should Be 0 }
        finally { $z.Dispose() }
    }

    # Lo pidio el usuario: que quien reciba el paquete no tenga las
    # explicaciones. El codigo si va entero -o no arrancaria-, pero sin un solo
    # comentario (el #Requires es una directiva, no un comentario).
    It "los .ps1 no llevan ningun comentario, pero si siguen leyendose" {
        foreach ($f in Get-ChildItem -LiteralPath $p -Recurse -Filter '*.ps1' -File) {
            $tokens = $null; $errores = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errores)
            $errores | Should BeNullOrEmpty
            $coment = @($tokens | Where-Object { $_.Kind -eq [System.Management.Automation.Language.TokenKind]::Comment -and $_.Text -notmatch '(?i)^#requires\b' })
            "$($f.Name): $($coment.Count)" | Should Be "$($f.Name): 0"
        }
    }
}

Describe "Remove-PsComments" {

    # Se saca del propio generador (vive en tools\, que Resolve-KitScript no
    # mira): asi se prueba la de verdad, no una copia que se quedaria vieja.
    $ruta = Join-Path $KitRoot 'tools\Build-PaqueteAndroid.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ruta, [ref]$null, [ref]$null)
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Remove-PsComments' }, $true)
    . ([scriptblock]::Create($fn.Extent.Text))

    function SinComentarios($Texto) {
        $tk = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($Texto, [ref]$tk, [ref]$null)
        @($tk | Where-Object { $_.Kind -eq [System.Management.Automation.Language.TokenKind]::Comment -and $_.Text -notmatch '(?i)^#requires\b' }).Count -eq 0
    }

    It "quita un comentario de linea entera, con su salto" {
        Remove-PsComments -Texto "# hola`r`n`$x = 1`r`n" | Should Be "`$x = 1`r`n"
    }

    It "quita un comentario al final de una linea y deja el codigo" {
        Remove-PsComments -Texto "`$x = 1   # nota`r`n" | Should Be "`$x = 1`r`n"
    }

    It "quita un bloque <# ... #> de varias lineas" {
        $r = Remove-PsComments -Texto "<#`r`n  ayuda`r`n#>`r`nfunction F {}`r`n"
        $r | Should Be "function F {}`r`n"
    }

    # Lo importante: un '#' dentro de una cadena NO es un comentario.
    It "no toca un # dentro de una cadena" {
        $t = "`$u = 'http://host/#ancla'`r`n`$h = `"color #fff`"`r`n"
        Remove-PsComments -Texto $t | Should Be $t
    }

    # Ni dentro de un here-string: es el caso del script de Gradle que lleva
    # Android.ps1, con comentarios en Groovy (//) que son codigo, no comentarios.
    It "no toca lo que hay dentro de un here-string" {
        $t = "`$g = @'`r`n// esto es Groovy, no un comentario de PowerShell`r`nprintln 'x'  # tampoco esto`r`n'@`r`n"
        Remove-PsComments -Texto $t | Should Be $t
    }

    It "deja el #Requires, que es una directiva" {
        Remove-PsComments -Texto "#Requires -Version 5.1`r`n# fuera`r`n`$x = 1`r`n" | Should Be "#Requires -Version 5.1`r`n`$x = 1`r`n"
    }

    It "lo que devuelve ya no tiene comentarios y se sigue leyendo" {
        $t = "function F {`r`n    <# ayuda #>`r`n    `$x = 1  # uno`r`n    return `$x`r`n}`r`n# final`r`n"
        $r = Remove-PsComments -Texto $t
        SinComentarios $r | Should Be $true
        $e = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($r, [ref]$null, [ref]$e)
        $e | Should BeNullOrEmpty
    }
}

Remove-Item -LiteralPath $RaizTmp -Recurse -Force -ErrorAction SilentlyContinue
