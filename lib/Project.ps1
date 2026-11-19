#Requires -Version 5.1
<#
    Que necesita un proyecto: leerlo de sus archivos, sin ejecutar nada

    NO lo carga Common.ps1: solo Setup-Project y sus pruebas, igual que
    lib\Doctor.ps1. Aqui solo se LEE; instalar es cosa del script.

    Existe porque instalar Python no bastaba. Despues habia que saber que
    version pedia el proyecto, crear su .venv con ESA y meterle sus
    dependencias, y cada paso tiene su trampa: un .venv copiado de otra maquina
    apunta a un Python que aqui no existe, un requires-python ">=3.11" no dice
    cual instalar, y el Python embeddable de antes no sabia crear un venv.
#>

# Las lineas de Python entre las que se elige cuando el proyecto solo pone un
# rango. La 3.12 es la que instala el kit por defecto.
$ProjectPythonLines = @('3.10', '3.11', '3.12', '3.13', '3.14')
$ProjectPythonDefault = '3.12'

function Test-PythonLineSpec {
    <#
    .SYNOPSIS
        Si alguna version de una linea (3.12) cumple un requires-python.
    .DESCRIPTION
        Se razona por lineas, no por versiones sueltas: lo que se instala es
        "la ultima 3.12", asi que la pregunta es si esa linea sirve. ">=3.11.4"
        la cumple la 3.11 (su ultimo parche es mayor), y "<3.12" no la cumple
        la 3.12.

        Entiende las clausulas de PEP 440 que aparecen en la practica (>=, >,
        <=, <, ==, !=, ~= y el comodin .*). Devuelve $null si encuentra una que
        no entiende: quien llama lo dice, en vez de adivinar.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Linea,
        [Parameter(Mandatory=$true)][string]$Spec
    )

    $l = [version]$Linea
    # El primer y el ultimo parche posibles de la linea.
    $minimo = [version]"$($l.Major).$($l.Minor).0"
    $maximo = [version]"$($l.Major).$($l.Minor).9999"

    foreach ($c in ($Spec -split ',')) {
        $c = $c.Trim()
        if (-not $c) { continue }
        $m = [regex]::Match($c, '^(~=|===|==|!=|<=|>=|<|>)\s*(\d+(?:\.\d+){0,2})(\.\*)?$')
        if (-not $m.Success) { return $null }
        $op = $m.Groups[1].Value
        $partes = $m.Groups[2].Value.Split('.')
        $comodin = $m.Groups[3].Success
        while ($partes.Count -lt 3) { $partes += '0' }
        $v = [version]($partes -join '.')
        $deLinea = ($v.Major -eq $l.Major -and $v.Minor -eq $l.Minor)

        $ok = switch ($op) {
            '>='  { $maximo -ge $v }
            '>'   { $maximo -gt $v }
            '<='  { $minimo -le $v }
            '<'   { $minimo -lt $v }
            '=='  { if ($comodin -and $m.Groups[2].Value.Split('.').Count -lt 2) { $v.Major -eq $l.Major } else { $deLinea } }
            '===' { $deLinea }
            '!='  { if ($comodin -or $m.Groups[2].Value.Split('.').Count -le 2) { -not $deLinea } else { $true } }
            '~='  {
                if ($m.Groups[2].Value.Split('.').Count -ge 3) { $deLinea -and $maximo -ge $v }
                else { $l.Major -eq $v.Major -and $maximo -ge $v }
            }
        }
        if (-not $ok) { return $false }
    }
    return $true
}

function Select-PythonLine {
    <#
        Que linea de Python usar para un proyecto que da un rango:
          1. la mas alta que ya este instalada y lo cumpla: no se baja nada;
          2. la que instala el kit por defecto, si lo cumple;
          3. la MAS BAJA que lo cumpla: es la que el proyecto dice soportar
             seguro, y la que menos sorpresas da con sus dependencias.
        Devuelve $null si ninguna lo cumple, o si el rango no se entiende.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Spec,
        [AllowEmptyCollection()][string[]]$Instaladas = @(),
        [string[]]$Lineas = $ProjectPythonLines,
        [string]$PorDefecto = $ProjectPythonDefault
    )

    $cumple = { param($x) Test-PythonLineSpec -Linea $x -Spec $Spec }
    if ($null -eq (& $cumple $PorDefecto)) { return $null }

    $inst = @($Instaladas | Where-Object { & $cumple $_ } | Sort-Object { [version]$_ } -Descending)
    if ($inst.Count -gt 0) { return $inst[0] }
    if (& $cumple $PorDefecto) { return $PorDefecto }
    return @($Lineas | Where-Object { & $cumple $_ } | Sort-Object { [version]$_ })[0]
}

function Get-PyProjectInfo {
    <#
        Del texto de un pyproject.toml: requires-python y las dependencias de
        [project], sin un lector de TOML. Basta con lo que se escribe a mano en
        la practica; lo raro se deja en paz.

        Las dependencias se leen caracter a caracter y no con una expresion
        regular: "requests[security]>=2" lleva un corchete DENTRO de la cadena,
        y una regex que corta en el primer "]" se quedaba a medias.

        Tambien dice si el proyecto es de Poetry, que pone sus dependencias en
        otra seccion con otro formato.
    #>
    param([AllowEmptyString()][string]$Texto)

    $info = [PSCustomObject]@{ RequiresPython = $null; Dependencias = @(); Poetry = $false }
    if ([string]::IsNullOrWhiteSpace($Texto)) { return $info }

    $info.Poetry = $Texto -match '(?m)^\s*\[tool\.poetry'

    $seccion = [regex]::Match($Texto, '(?ms)^\s*\[project\]\s*$(.*?)(?=^\s*\[|\z)')
    if (-not $seccion.Success) { return $info }
    $p = $seccion.Groups[1].Value

    $rp = [regex]::Match($p, '(?m)^\s*requires-python\s*=\s*["'']([^"'']+)["'']')
    if ($rp.Success) { $info.RequiresPython = $rp.Groups[1].Value.Trim() }

    $inicio = [regex]::Match($p, '(?m)^\s*dependencies\s*=\s*\[')
    if ($inicio.Success) {
        $deps = @()
        $i = $inicio.Index + $inicio.Length
        while ($i -lt $p.Length) {
            $ch = $p[$i]
            if ($ch -eq ']') { break }
            if ($ch -eq '#') { while ($i -lt $p.Length -and $p[$i] -ne "`n") { $i++ }; continue }
            if ($ch -eq '"' -or $ch -eq "'") {
                $fin = $p.IndexOf($ch, $i + 1)
                if ($fin -lt 0) { break }
                $deps += $p.Substring($i + 1, $fin - $i - 1)
                $i = $fin + 1
                continue
            }
            $i++
        }
        $info.Dependencias = @($deps | Where-Object { $_.Trim() })
    }
    return $info
}

function Get-JavaMajorFromBuild {
    <#
        La version de Java que pide un pom.xml o un build.gradle. Se mira lo
        que se usa de verdad, en orden: release, la de Spring (java.version),
        source; en Gradle, el toolchain y despues sourceCompatibility.
    #>
    param(
        [AllowEmptyString()][string]$Texto,
        [ValidateSet('maven', 'gradle')][string]$Tipo
    )
    if ([string]::IsNullOrWhiteSpace($Texto)) { return $null }

    $patrones = if ($Tipo -eq 'maven') {
        @('<maven\.compiler\.release>\s*(\d+)', '<release>\s*(\d+)\s*</release>', '<java\.version>\s*(?:1\.)?(\d+)',
          '<maven\.compiler\.source>\s*(?:1\.)?(\d+)', '<source>\s*(?:1\.)?(\d+)\s*</source>')
    } else {
        @('JavaLanguageVersion\.of\(\s*(\d+)\s*\)', 'JavaVersion\.VERSION_(?:1_)?(\d+)',
          'sourceCompatibility\s*=\s*[''"]?(?:1\.)?(\d+)')
    }
    foreach ($pt in $patrones) {
        $m = [regex]::Match($Texto, $pt)
        if ($m.Success) { return [int]$m.Groups[1].Value }
    }
    return $null
}

function Get-AndroidProjectInfo {
    <#
        Si es un proyecto Android, y con que compila: Agp (la version del
        plugin), CompileSdk, MinSdk, BuildTools (solo si lo dice) y Fuente.
        $null si no es Android.

        El plugin se aplica en el modulo (app\build.gradle), no en el de la
        raiz, y en las plantillas de ahora va por el catalogo de versiones:
        alias(libs.plugins.android.application). Los numeros se buscan en el
        modulo y, si alli van por variable, en gradle\libs.versions.toml.
        compileSdk se escribe de cuatro maneras segun la epoca del proyecto:
        compileSdkVersion 34, compileSdk 34, compileSdk = 34 y, desde AGP 9,
        compileSdk { version = release(36) }.
    #>
    param([Parameter(Mandatory=$true)][string]$Ruta)

    $candidatos = @()
    foreach ($d in @(@(Get-Item -LiteralPath $Ruta) + @(Get-ChildItem -LiteralPath $Ruta -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^(\.|build$|gradle$|node_modules$)' }))) {
        foreach ($n in @('build.gradle', 'build.gradle.kts')) {
            $f = Join-Path $d.FullName $n
            if (Test-Path -LiteralPath $f) { $candidatos += $f }
        }
    }
    $plugin = 'com\.android\.(application|library)|libs\.plugins\.android\.(application|library)\b'
    $modulo = $null; $texto = $null
    foreach ($f in $candidatos) {
        $t = Get-Content -LiteralPath $f -Raw
        # El de la raiz suele declararlo con "apply false": ese no es el modulo.
        if ($t -match $plugin -and $t -match '(?m)^\s*android\s*\{') { $modulo = $f; $texto = $t; break }
    }
    if (-not $modulo) { return $null }

    $toml = Join-Path $Ruta 'gradle\libs.versions.toml'
    $cat = if (Test-Path -LiteralPath $toml) { Get-Content -LiteralPath $toml -Raw } else { '' }

    $num = {
        param([string[]]$Patrones, [string]$Clave)
        foreach ($pt in $Patrones) { $m = [regex]::Match($texto, $pt); if ($m.Success) { return $m.Groups[1].Value } }
        if ($cat -and $Clave) {
            $m = [regex]::Match($cat, "(?m)^\s*$Clave\s*=\s*[`"']([\d.]+)[`"']")
            if ($m.Success) { return $m.Groups[1].Value }
        }
        return $null
    }

    # La version de AGP, que decide con que JDK corre Gradle y que build-tools
    # usa: en el classpath de la raiz (los de antes), en el bloque plugins de la
    # raiz o de settings.gradle, o en el catalogo, por version.ref.
    $agp = $null
    $textos = @($candidatos + @('settings.gradle', 'settings.gradle.kts' | ForEach-Object { Join-Path $Ruta $_ }) |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique | ForEach-Object { Get-Content -LiteralPath $_ -Raw })
    foreach ($t in $textos) {
        $m = [regex]::Match($t, 'com\.android\.tools\.build:gradle:(\d+\.\d+[\w.-]*)')
        if (-not $m.Success) { $m = [regex]::Match($t, 'id\s*\(?\s*[''"]com\.android\.(?:application|library)[''"]\s*\)?\s*version\s*[''"](\d+\.\d+[\w.-]*)[''"]') }
        if ($m.Success) { $agp = $m.Groups[1].Value; break }
    }
    if (-not $agp -and $cat) {
        $linea = [regex]::Match($cat, '(?m)^.*(?:com\.android\.(?:application|library)|com\.android\.tools\.build:gradle).*$').Value
        $directa = [regex]::Match($linea, '\bversion\s*=\s*"(\d+\.\d+[\w.-]*)"')
        $ref = [regex]::Match($linea, 'version\.ref\s*=\s*"([^"]+)"')
        if ($directa.Success) { $agp = $directa.Groups[1].Value }
        elseif ($ref.Success) {
            $m = [regex]::Match($cat, "(?m)^\s*$([regex]::Escape($ref.Groups[1].Value))\s*=\s*`"(\d+\.\d+[\w.-]*)`"")
            if ($m.Success) { $agp = $m.Groups[1].Value }
        }
    }

    $rel = $modulo.Substring($Ruta.TrimEnd('\').Length).TrimStart('\')
    return [PSCustomObject]@{
        Agp        = $agp
        CompileSdk = (& $num @('compileSdk\s*\{[^}]*?release\(\s*(\d+)', '\bcompileSdk(?:Version)?\s*(?:=\s*)?[''"]?(?:android-)?(\d+)\b') 'compileSdk')
        MinSdk     = (& $num @('minSdk\s*\{[^}]*?release\(\s*(\d+)', '\bminSdk(?:Version)?\s*(?:=\s*)?(\d+)\b') 'minSdk')
        BuildTools = (& $num @('\bbuildToolsVersion\s*(?:=\s*)?[''"](\d+\.\d+\.\d+)[''"]') 'buildTools')
        Fuente     = $rel
    }
}

function Get-NodeVersionHint {
    <#
        La Node que pide un proyecto: .nvmrc o .node-version (una version o una
        mayor), o el engines.node de package.json (un rango). Devuelve Tipo
        (mayor, rango, lts) y Valor, o $null.
    #>
    param([Parameter(Mandatory=$true)][string]$Ruta)

    foreach ($a in @('.nvmrc', '.node-version')) {
        $f = Join-Path $Ruta $a
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $t = (Get-Content -LiteralPath $f -TotalCount 1).Trim().TrimStart('v')
        if ($t -match '^lts/') { return [PSCustomObject]@{ Tipo = 'lts'; Valor = $t; Fuente = $a } }
        if ($t -match '^(\d+)') { return [PSCustomObject]@{ Tipo = 'mayor'; Valor = $Matches[1]; Fuente = $a } }
    }

    $pkg = Join-Path $Ruta 'package.json'
    if (Test-Path -LiteralPath $pkg) {
        try {
            $j = Get-Content -LiteralPath $pkg -Raw | ConvertFrom-Json
            if ($j.engines -and $j.engines.node) {
                return [PSCustomObject]@{ Tipo = 'rango'; Valor = [string]$j.engines.node; Fuente = 'package.json (engines)' }
            }
        }
        catch { }
    }
    return $null
}

function Get-VenvInfo {
    <#
        Como esta el .venv de un proyecto. El caso que motiva esto: un .venv
        copiado de otra maquina (o de antes de reinstalar Python) apunta en su
        pyvenv.cfg a un Python que aqui no existe, y "python" dentro de el falla
        con un error que no dice eso.

        Devuelve Existe, Python (su python.exe), Base (el home de pyvenv.cfg),
        BaseExiste, Version (la de pyvenv.cfg) y Linea.
    #>
    param([Parameter(Mandatory=$true)][string]$Ruta)

    $cfg = Join-Path $Ruta 'pyvenv.cfg'
    $r = [PSCustomObject]@{ Existe = (Test-Path -LiteralPath $cfg); Python = (Join-Path $Ruta 'Scripts\python.exe'); Base = $null; BaseExiste = $false; Version = $null; Linea = $null }
    if (-not $r.Existe) { return $r }

    foreach ($l in (Get-Content -LiteralPath $cfg)) {
        if ($l -match '^\s*home\s*=\s*(.+?)\s*$') { $r.Base = $Matches[1] }
        elseif ($l -match '^\s*(?:version|version_info)\s*=\s*(\d+\.\d+(?:\.\d+)?)') { $r.Version = $Matches[1] }
    }
    if ($r.Base) { $r.BaseExiste = Test-Path -LiteralPath (Join-Path $r.Base 'python.exe') }
    if ($r.Version -match '^(\d+\.\d+)') { $r.Linea = $Matches[1] }
    return $r
}

function Get-ProjectNeeds {
    <#
    .SYNOPSIS
        Todo lo que pide un proyecto, leido de sus archivos.
    .DESCRIPTION
        Devuelve Python, Node y Java (cada uno $null si el proyecto no lo usa) y
        DevEnv (si trae un devenv.json, que es la receta del kit y manda).

          Python  Linea o Exacta, Fuente, Dependencias (requirements | pyproject
                  | $null), Paquetes (los de pyproject) y Avisos
          Node    Pista (Get-NodeVersionHint) y Lock (package-lock.json)
          Java    Mayor, Fuente, Maven/Gradle si hay que instalarlos (sin su
                  propio lanzador mvnw/gradlew)
          Android CompileSdk, MinSdk, BuildTools y Fuente (Get-AndroidProjectInfo)
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Ruta,
        [AllowEmptyCollection()][string[]]$PythonInstaladas = @()
    )

    $r = [PSCustomObject]@{ Python = $null; Node = $null; Java = $null; Android = $null; DevEnv = $null; Avisos = @() }
    $en = { param($n) Join-Path $Ruta $n }

    $devenv = $null
    if (Test-Path -LiteralPath (& $en 'devenv.json')) {
        $r.DevEnv = & $en 'devenv.json'
        try { $devenv = Get-Content -LiteralPath $r.DevEnv -Raw | ConvertFrom-Json } catch { }
    }

    # --- Python ---
    $pyproject = & $en 'pyproject.toml'
    $req = & $en 'requirements.txt'
    $pv = & $en '.python-version'
    $hayPy = (Test-Path -LiteralPath $pyproject) -or (Test-Path -LiteralPath $req) -or (Test-Path -LiteralPath $pv) -or
             ($devenv -and $devenv.runtimes -and $devenv.runtimes.python)
    if ($hayPy) {
        $py = [PSCustomObject]@{ Linea = $null; Exacta = $null; Fuente = $null; Dependencias = $null; Paquetes = @(); Avisos = @() }
        $info = if (Test-Path -LiteralPath $pyproject) { Get-PyProjectInfo -Texto (Get-Content -LiteralPath $pyproject -Raw) } else { $null }

        if (Test-Path -LiteralPath $pv) {
            $t = (Get-Content -LiteralPath $pv -TotalCount 1).Trim()
            if ($t -match '^(\d+\.\d+)(\.\d+)?$') {
                $py.Linea = $Matches[1]
                if ($Matches[2]) { $py.Exacta = $t }
                $py.Fuente = '.python-version'
            }
        }
        if (-not $py.Linea -and $devenv -and $devenv.runtimes.python) {
            $t = [string]$devenv.runtimes.python
            if ($t -match '^(\d+\.\d+)') { $py.Linea = $Matches[1]; $py.Fuente = 'devenv.json' }
        }
        if (-not $py.Linea -and $info -and $info.RequiresPython) {
            $l = Select-PythonLine -Spec $info.RequiresPython -Instaladas $PythonInstaladas
            if ($l) { $py.Linea = $l; $py.Fuente = "pyproject.toml (requires-python $($info.RequiresPython))" }
            else { $py.Avisos += "requires-python `"$($info.RequiresPython)`" no se entiende o ninguna linea lo cumple." }
        }
        if (-not $py.Linea) {
            $inst = @($PythonInstaladas | Sort-Object { [version]$_ } -Descending)
            $py.Linea = if ($inst.Count) { $inst[0] } else { $ProjectPythonDefault }
            $py.Fuente = 'no lo dice; la que hay o la del kit'
        }

        if (Test-Path -LiteralPath $req) { $py.Dependencias = 'requirements' }
        elseif ($info -and $info.Dependencias.Count -gt 0) { $py.Dependencias = 'pyproject'; $py.Paquetes = $info.Dependencias }

        if ($info -and $info.Poetry) { $py.Avisos += 'Usa Poetry: sus dependencias van en otra seccion. Para esas, poetry install.' }
        if (Test-Path -LiteralPath (& $en 'uv.lock')) { $py.Avisos += 'Trae uv.lock: se instalan las dependencias de pyproject.toml, no las versiones fijadas del lock.' }
        $r.Python = $py
    }

    # --- Node ---
    if (Test-Path -LiteralPath (& $en 'package.json')) {
        $r.Node = [PSCustomObject]@{
            Pista = (Get-NodeVersionHint -Ruta $Ruta)
            Lock  = (Test-Path -LiteralPath (& $en 'package-lock.json'))
        }
    }

    # --- Java ---
    $pom = & $en 'pom.xml'
    $gradle = @('build.gradle', 'build.gradle.kts') | ForEach-Object { & $en $_ } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ((Test-Path -LiteralPath $pom) -or $gradle) {
        $j = [PSCustomObject]@{ Mayor = $null; Fuente = $null; Maven = $false; Gradle = $false }
        if (Test-Path -LiteralPath $pom) {
            $j.Mayor = Get-JavaMajorFromBuild -Texto (Get-Content -LiteralPath $pom -Raw) -Tipo maven
            $j.Fuente = 'pom.xml'
            $j.Maven = -not (Test-Path -LiteralPath (& $en 'mvnw.cmd'))
        }
        elseif ($gradle) {
            $j.Mayor = Get-JavaMajorFromBuild -Texto (Get-Content -LiteralPath $gradle -Raw) -Tipo gradle
            $j.Fuente = Split-Path -Leaf $gradle
            $j.Gradle = -not (Test-Path -LiteralPath (& $en 'gradlew.bat'))
        }
        $r.Java = $j
        $r.Android = Get-AndroidProjectInfo -Ruta $Ruta
    }

    return $r
}
