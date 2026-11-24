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
}

Remove-Item -LiteralPath $RaizTmp -Recurse -Force -ErrorAction SilentlyContinue
