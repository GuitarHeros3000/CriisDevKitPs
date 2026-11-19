#Requires -Version 5.1
<#
.SYNOPSIS
    Build-PaqueteAndroid.ps1 - Arma el zip de Android para repartir, con solo lo que hace falta.
.DESCRIPTION
    El paquete lleva los comandos de Android y, de la libreria del kit, solo
    lo que esos comandos usan de verdad. Se saca del codigo con el analizador
    de PowerShell: desde los scripts que van dentro se siguen las llamadas a
    funciones del kit, y las variables de libreria que usan, hasta el fondo.
    Se recalcula cada vez, asi que si el kit cambia el paquete sigue llevando
    justo lo necesario.

    Lo demas no va: los otros runtimes, Doctor, Use-Env, Export e Import,
    Install-NoAdmin, Visual C++, Update-Kit, las pruebas y la documentacion.

    Common.ps1 no sirve tal cual: obliga a cargar las 14 librerias, y sin una
    no arranca. El paquete lleva uno generado que carga solo las que van.

    Antes de dar el zip por bueno lo comprueba:
      - que todo .ps1 del paquete se lee sin errores;
      - que toda funcion del kit a la que se llama esta dentro;
      - que no nombra ningun .bat que no este dentro ni lo genere el kit;
      - que arranca: Start-AndroidApp, con una carpeta que no existe, tiene que
        quejarse de eso y no de que le falte algo; y el menu abre y cierra.
.PARAMETER Destino
    Donde dejarlo. Por defecto, dist\ del kit.
.PARAMETER SinZip
    Deja solo la carpeta, sin comprimir.
.EXAMPLE
    .\tools\Build-PaqueteAndroid.ps1
#>

param([string]$Destino, [switch]$SinZip)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $Destino) { $Destino = Join-Path $repo 'dist' }
$version = [regex]::Match([IO.File]::ReadAllText((Join-Path $repo 'lib\Common.ps1')), '(?m)^\$KitVersion\s*=\s*"([^"]+)"').Groups[1].Value
$carpeta = Join-Path $Destino 'CriisDevKit-Android'

# Lo que va tal cual: ruta en el paquete -> ruta en el kit.
$tal = [ordered]@{
    'Android.bat'                             = 'tools\paquete-android\Android.bat'
    'LEEME.md'                                = 'tools\paquete-android\LEEME.md'
    'scripts\kit\Menu-Android.ps1'            = 'tools\paquete-android\Menu-Android.ps1'
    'scripts\start\Start-AndroidApp.ps1'      = 'scripts\start\Start-AndroidApp.ps1'
    'scripts\start\Start-AndroidEmulator.ps1' = 'scripts\start\Start-AndroidEmulator.ps1'
    'scripts\setup\Setup-AndroidEnv.ps1'      = 'scripts\setup\Setup-AndroidEnv.ps1'
    'scripts\setup\Setup-JavaEnv.ps1'         = 'scripts\setup\Setup-JavaEnv.ps1'
    'bin\start\Start-AndroidApp.bat'          = 'bin\start\Start-AndroidApp.bat'
    'bin\start\Start-AndroidEmulator.bat'     = 'bin\start\Start-AndroidEmulator.bat'
}

# Lo que dicen los scripts del kit completo y en el paquete es otra cosa: un
# comando del kit que no va, se cambia por lo que si tiene quien lo recibe.
# La comprobacion de abajo falla si se cuela alguno nuevo sin traduccion.
$cambios = [ordered]@{
    'Menu.bat, opcion 60'                                  = 'Android.bat, opcion 1'
    '.\bin\setup\Setup-AndroidEnv.bat -Emulador'           = 'Android.bat, opcion 1'
    'Diagnostico de la red:  .\bin\kit\Doctor-Env.bat'     = "Mira 'Si algo falla' en LEEME.md (el proxy de la empresa)"
    'el diagnostico:  .\bin\kit\Doctor-Env.bat'            = "mira 'Si algo falla' en LEEME.md"
    'Comprueba con: .\bin\kit\Doctor-Env.bat'              = "Si algo falla: LEEME.md"
    '.\bin\setup\Setup-JavaEnv.bat'                        = 'scripts\setup\Setup-JavaEnv.ps1'
    'Instala uno con:  Setup-JavaEnv.bat'                  = 'Instala uno con:  Android.bat, opcion 1'
    '.\bin\env\Uninstall-Env.bat -Runtime $Label -Version <version>' = 'Android.bat, opcion 3 (quita todo)'
}

function Read-Ast {
    param([string]$Ruta)
    $e = $null
    $a = [System.Management.Automation.Language.Parser]::ParseFile($Ruta, [ref]$null, [ref]$e)
    if ($e) { throw "$Ruta no se lee: $($e[0].Message) (linea $($e[0].Extent.StartLineNumber))" }
    return $a
}

function Get-NombreVariable {
    <# $script:X, $global:X y $X son la misma para esto. #>
    param($Variable)
    return ($Variable.VariablePath.UserPath -replace '^(script|global|local|private):', '').ToLowerInvariant()
}

function Get-Usos {
    <# Las llamadas y las variables de un trozo de codigo, en minusculas. #>
    param($Ast)
    [PSCustomObject]@{
        Llamadas  = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
        Variables = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { Get-NombreVariable $_ })
    }
}

Write-Host ""
Write-Host "Paquete de Android, kit $version" -ForegroundColor Cyan

# --------------------------------------------------------------------------
# La libreria: que hay en cada archivo
# --------------------------------------------------------------------------

$commonAst = Read-Ast (Join-Path $repo 'lib\Common.ps1')
$cargador = @($commonAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.ForEachStatementAst] })[0]
$modulos = @($cargador.Condition.FindAll({ $args[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object Value | Where-Object { $_ -like '*.ps1' })
if ($modulos.Count -lt 10) { throw "No encuentro la lista de librerias que carga lib\Common.ps1 (salen $($modulos.Count))." }
$libs = @($modulos) + @('Android.ps1', 'Project.ps1')

$funciones = @{}; $asignaciones = @{}; $sueltas = @{}; $todas = @{}
foreach ($m in $libs) {
    $sueltas[$m] = @()
    foreach ($st in (Read-Ast (Join-Path $repo "lib\$m")).EndBlock.Statements) {
        if ($st -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            $funciones[$st.Name.ToLowerInvariant()] = [PSCustomObject]@{ Archivo = $m; Ast = $st }
        }
        elseif ($st -is [System.Management.Automation.Language.AssignmentStatementAst] -and $st.Left -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $n = Get-NombreVariable $st.Left
            if (-not $asignaciones.ContainsKey($n)) { $asignaciones[$n] = @() }
            $asignaciones[$n] += [PSCustomObject]@{ Archivo = $m; Ast = $st }
        }
        else { $sueltas[$m] += $st }
    }
}
# Todas las funciones del kit, tambien las de las librerias que se cargan
# aparte (Doctor, KitUpdate): para saber si algo llama a una que no va.
foreach ($f in Get-ChildItem (Join-Path $repo 'lib') -Filter '*.ps1') {
    foreach ($fn in (Read-Ast $f.FullName).FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $todas[$fn.Name.ToLowerInvariant()] = $f.Name }
}

# --------------------------------------------------------------------------
# Lo que se usa, desde los scripts que van, hasta el fondo
# --------------------------------------------------------------------------

$dentro = @{}          # el Ast de lo que va -> $true
$usado = @{}           # archivo de la libreria -> $true
$cola = New-Object System.Collections.Queue
foreach ($rel in $tal.Values | Where-Object { $_ -like '*.ps1' }) { $cola.Enqueue((Read-Ast (Join-Path $repo $rel))) }
$commonSueltas = @($commonAst.EndBlock.Statements | Where-Object { $_ -ne $cargador })
foreach ($st in $commonSueltas) { $cola.Enqueue($st) }

do {
    while ($cola.Count) {
        $u = Get-Usos -Ast $cola.Dequeue()
        foreach ($c in ($u.Llamadas | Select-Object -Unique)) {
            $f = $funciones[$c]
            if ($f -and -not $dentro[$f.Ast]) { $dentro[$f.Ast] = $true; $usado[$f.Archivo] = $true; $cola.Enqueue($f.Ast) }
        }
        foreach ($v in ($u.Variables | Select-Object -Unique)) {
            foreach ($a in @($asignaciones[$v])) {
                if ($a -and -not $dentro[$a.Ast]) { $dentro[$a.Ast] = $true; $usado[$a.Archivo] = $true; $cola.Enqueue($a.Ast) }
            }
        }
    }
    # Lo que un archivo hace al cargarse (UserPath abre el registro) va si el
    # archivo va, y puede tirar de mas cosas.
    foreach ($m in @($usado.Keys)) {
        foreach ($st in $sueltas[$m]) { if (-not $dentro[$st]) { $dentro[$st] = $true; $cola.Enqueue($st) } }
    }
} while ($cola.Count)

# --------------------------------------------------------------------------
# Escribirlo
# --------------------------------------------------------------------------

if (Test-Path -LiteralPath $carpeta) { Remove-Item -LiteralPath $carpeta -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $carpeta 'lib') -Force | Out-Null

function Write-Texto {
    param([string]$Rel, [string]$Texto)
    foreach ($k in $cambios.Keys) { $Texto = $Texto.Replace($k, $cambios[$k]) }
    $ruta = Join-Path $carpeta $Rel
    New-Item -ItemType Directory -Path (Split-Path -Parent $ruta) -Force | Out-Null
    # Los .bat en CRLF siempre: cmd se lia con LF. El resto, como venga.
    if ($Rel -like '*.bat') { $Texto = ($Texto -replace "`r?`n", "`r`n") }
    [IO.File]::WriteAllText($ruta, $Texto, (New-Object System.Text.UTF8Encoding($false)))
}

foreach ($rel in $tal.Keys) { Write-Texto -Rel $rel -Texto ([IO.File]::ReadAllText((Join-Path $repo $tal[$rel]))) }

$cabecera = "#Requires -Version 5.1`r`n# Generado por tools\Build-PaqueteAndroid.ps1 a partir de lib\{0} del kit $version.`r`n# Solo lo que usan los comandos de Android{1}.`r`n`r`n"
$enviadas = @()
$nFunc = 0
foreach ($m in $libs) {
    if (-not $usado[$m]) { continue }
    $piezas = @($sueltas[$m]) + @($funciones.Values | Where-Object { $_.Archivo -eq $m } | ForEach-Object Ast) + @($asignaciones.Values | ForEach-Object { $_ } | Where-Object { $_.Archivo -eq $m } | ForEach-Object Ast)
    $van = @($piezas | Where-Object { $dentro[$_] } | Sort-Object { $_.Extent.StartOffset })
    $f = @($van | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] }).Count
    $total = @($funciones.Values | Where-Object { $_.Archivo -eq $m }).Count
    $nFunc += $f
    Write-Texto -Rel "lib\$m" -Texto (($cabecera -f $m, ": $f de $total funciones") + (($van | ForEach-Object { $_.Extent.Text }) -join "`r`n`r`n") + "`r`n")
    if ($m -notin 'Android.ps1', 'Project.ps1') { $enviadas += $m }
}

$commonTexto = ($cabecera -f 'Common.ps1', '') + (($commonSueltas | ForEach-Object { $_.Extent.Text }) -join "`r`n`r`n") + "`r`n`r`n" +
    "foreach (`$modulo in @(`r`n" + (($enviadas | ForEach-Object { "    '$_'" }) -join ",`r`n") + "`r`n)) {`r`n" +
    "    `$ruta = Join-Path `$PSScriptRoot `$modulo`r`n" +
    "    if (-not (Test-Path -LiteralPath `$ruta)) { throw `"Falta lib\`$modulo. El paquete esta incompleto.`" }`r`n" +
    "    . `$ruta`r`n}`r`n"
Write-Texto -Rel 'lib\Common.ps1' -Texto $commonTexto

# --------------------------------------------------------------------------
# Comprobarlo
# --------------------------------------------------------------------------

$fallos = @()
$definidas = @{}
$ps1 = @(Get-ChildItem -LiteralPath $carpeta -Recurse -Filter '*.ps1' -File)
foreach ($p in $ps1) {
    $e = $null
    $a = [System.Management.Automation.Language.Parser]::ParseFile($p.FullName, [ref]$null, [ref]$e)
    if ($e) { $fallos += "no se lee $($p.Name): $($e[0].Message)"; continue }
    foreach ($fn in $a.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $definidas[$fn.Name.ToLowerInvariant()] = $true }
    if ([IO.File]::ReadAllBytes($p.FullName) | Where-Object { $_ -gt 127 }) { $fallos += "$($p.Name) no es ASCII" }
}
foreach ($p in $ps1) {
    foreach ($c in (Get-Usos -Ast (Read-Ast $p.FullName)).Llamadas | Select-Object -Unique) {
        if ($todas.ContainsKey($c) -and -not $definidas[$c]) { $fallos += "$($p.Name) llama a $c (lib\$($todas[$c])), que no va" }
    }
}
# Que no mande a ejecutar un comando del kit que no va. Solo se miran los
# nombres de los comandos del kit: los .bat que genera al instalar
# (java21-shell.bat, android-shell.bat...) se nombran a trozos y no cuentan.
$comandosKit = @(Get-ChildItem -LiteralPath (Join-Path $repo 'bin') -Recurse -Filter '*.bat' -File) + @(Get-ChildItem -LiteralPath $repo -Filter '*.bat' -File) | ForEach-Object Name
$hay = @(Get-ChildItem -LiteralPath $carpeta -Recurse -Filter '*.bat' -File | ForEach-Object Name)
foreach ($t in Get-ChildItem -LiteralPath $carpeta -Recurse -File -Include '*.ps1', '*.md', '*.bat') {
    foreach ($b in ([regex]::Matches([IO.File]::ReadAllText($t.FullName), '(?<![\w$%-])[\w-]+\.bat\b') | ForEach-Object Value | Select-Object -Unique)) {
        if ($comandosKit -contains $b -and $hay -notcontains $b) { $fallos += "$($t.Name) manda a $b, que no va en el paquete" }
    }
}

# Que arranque de verdad, en un proceso aparte y sin escribir registro.
$previo = $env:CRIISDEVKIT_NOLOG
$env:CRIISDEVKIT_NOLOG = '1'
try {
    $o = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $carpeta 'scripts\start\Start-AndroidApp.ps1') -Path (Join-Path $carpeta 'no-existe') 2>&1 | ForEach-Object { "$_" }
    if (($o -join "`n") -notmatch 'No existe la carpeta') { $fallos += "Start-AndroidApp no arranca: $(($o | Select-Object -Last 3) -join ' | ')" }
    $q = Join-Path ([IO.Path]::GetTempPath()) ("menu-q-" + [Guid]::NewGuid().ToString('N') + '.txt')
    [IO.File]::WriteAllText($q, "q`r`n", [Text.Encoding]::ASCII)
    $o = & cmd.exe /c "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $carpeta 'scripts\kit\Menu-Android.ps1')`" < `"$q`" 2>&1"
    Remove-Item -LiteralPath $q -ErrorAction SilentlyContinue
    if ($LASTEXITCODE -ne 0 -or ($o -join "`n") -notmatch 'Compilar y probar una app') { $fallos += "el menu no abre: $(($o | Select-Object -Last 3) -join ' | ')" }
}
finally { $env:CRIISDEVKIT_NOLOG = $previo }

if ($fallos.Count) {
    Write-Host "El paquete NO esta bien:" -ForegroundColor Red
    $fallos | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

# --------------------------------------------------------------------------

$lineas = (Get-ChildItem -LiteralPath $carpeta -Recurse -File -Include '*.ps1', '*.bat' | Get-Content | Measure-Object -Line).Lines
Write-Host ("  Libreria : {0} funciones de {1}, en {2} archivos (de {3})" -f $nFunc, $funciones.Count, ($enviadas.Count + 3), ($libs.Count + 1))
Write-Host ("  Codigo   : {0:N0} lineas" -f $lineas)
Write-Host "  Comprobado: se lee, no le falta ninguna funcion, no nombra nada que no lleve, y arranca." -ForegroundColor Green

if ($SinZip) { Write-Host "  Carpeta  : $carpeta"; exit 0 }
$zip = Join-Path $Destino "CriisDevKit Android $version.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
# A mano y no con ZipFile.CreateFromDirectory: el de .NET Framework guarda las
# rutas con "\", que el formato zip no admite. El Explorador lo tolera, pero
# otros descompresores lo dejan todo en una carpeta con nombres raros.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$fs = [IO.File]::Open($zip, [IO.FileMode]::CreateNew)
try {
    $za = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($a in Get-ChildItem -LiteralPath $carpeta -Recurse -File) {
            $entrada = 'CriisDevKit-Android/' + ($a.FullName.Substring($carpeta.Length + 1) -replace '\\', '/')
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($za, $a.FullName, $entrada, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    }
    finally { $za.Dispose() }
}
finally { $fs.Dispose() }
Write-Host ("  Zip      : {0}  ({1:N0} KB)" -f $zip, ((Get-Item -LiteralPath $zip).Length / 1KB)) -ForegroundColor Cyan
exit 0
