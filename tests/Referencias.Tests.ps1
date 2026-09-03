#Requires -Version 5.1
<#
    Que ningun archivo del kit mencione un .bat que no exista donde dice.

    Existe por un fallo concreto: al mover los 29 comandos a bin\, las 211
    menciones del tipo ".\Setup-JavaEnv.bat" se corrigieron con una sustitucion,
    pero Empezar.ps1 los invocaba de otra forma -Join-Path $Kit "X.bat"- y esa
    no la toco nadie. El comando quedo llamando a rutas que ya no existian y
    NINGUNA prueba lo detectaba, porque no hay ninguna que ejecute Empezar.

    Un mensaje que dice "instala con .\X.bat" y manda a un sitio equivocado es
    peor que no decir nada: el usuario cree que hizo lo que le pedian.
#>

$KitRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $KitRoot "lib\Common.ps1")

function Get-ArchivosDelKit {
    # Este mismo archivo queda fuera: habla DE las referencias, asi que sus
    # ejemplos (".\X.bat") no son referencias reales y se senalarian solos.
    #
    # El -Recurse de bin\ no es un detalle: los comandos dejaron de estar
    # sueltos ahi y pasaron a bin\setup\, bin\start\, bin\env\ y bin\kit\, con
    # lo que un Get-ChildItem sin recursion devuelve CERO archivos y esta
    # prueba se quedo mirando una lista vacia sin que nadie lo notara.
    #
    # Los .ejemplo entran porque tambien dicen "ejecuta .\X.bat" y un usuario
    # los copia tal cual: sources.json.ejemplo se quedo apuntando a un
    # Doctor-Env.bat en la raiz que ya no existia.
    return @(
        (Get-ChildItem -LiteralPath $KitRoot -Filter *.bat -File),
        (Get-ChildItem -LiteralPath (Join-Path $KitRoot 'bin') -Filter *.bat -File -Recurse -ErrorAction SilentlyContinue),
        (Get-ChildItem -LiteralPath (Join-Path $KitRoot 'scripts') -Filter *.ps1 -File -Recurse),
        (Get-ChildItem -LiteralPath (Join-Path $KitRoot 'lib') -Filter *.ps1 -File),
        (Get-ChildItem -LiteralPath (Join-Path $KitRoot 'tests') -Filter *.ps1 -File),
        (Get-ChildItem -LiteralPath $KitRoot -Filter *.ejemplo -File),
        (Get-Item -LiteralPath (Join-Path $KitRoot 'README.md'))
    ) | ForEach-Object { $_ } | Where-Object { $_.Name -ne 'Referencias.Tests.ps1' }
}

# Una mencion a un comando del kit, en cualquiera de las formas en que se
# escribe: .\Menu.bat en la raiz y .\bin\setup\Setup-JavaEnv.bat en bin\.
#
# Deliberadamente permisivo con las carpetas -acepta hasta tres niveles
# cualesquiera- y estricto despues, cuando se comprueba con Test-Path. Al reves
# no vale: un patron que solo admitiera las cuatro subcarpetas buenas dejaria
# pasar en silencio un ".\bin\Doctor-Env.bat", que es justo el error a cazar.
$PatronComando = '\.\\((?:[A-Za-z]+\\){0,3}[A-Za-z][A-Za-z-]*\.bat)'

function Get-TextoNormalizado {
    <#
        El texto de un archivo con las barras dobles convertidas en simples.

        Hace falta por los .ejemplo, que son JSON: ahi ".\bin\kit\Doctor-Env.bat"
        se escribe ".\\bin\\kit\\Doctor-Env.bat" y el patron no lo reconoce. Sin
        esto, meter los .ejemplo en la lista de archivos da la sensacion de
        cubrirlos sin cubrir ninguno, que es exactamente el fallo que esta prueba
        tuvo durante toda la reorganizacion de bin\.

        Para el resto de archivos no cambia nada: el kit no escribe rutas con
        barra doble fuera de JSON.
    #>
    param([string]$Texto)

    if (-not $Texto) { return $Texto }
    return ($Texto -replace '\\{2,}', '\')
}

Describe "Referencias a comandos del kit" {

    # Los .bat que el kit genera dentro de las carpetas de los runtimes
    # -java25-shell.bat, post-install.bat- no son comandos del kit y no tienen
    # por que existir en el repositorio.
    $ajenos = @('post-install.bat')

    It "toda mencion del tipo .\algo.bat apunta a un archivo que existe" {
        $rotas = @()

        foreach ($f in (Get-ArchivosDelKit)) {
            $texto = Get-TextoNormalizado -Texto (Get-Content -LiteralPath $f.FullName -Raw)
            if (-not $texto) { continue }

            foreach ($m in ([regex]::Matches($texto, $PatronComando))) {
                $rel = $m.Groups[1].Value
                if ($ajenos -contains (Split-Path -Leaf $rel)) { continue }
                if (-not (Test-Path -LiteralPath (Join-Path $KitRoot $rel))) {
                    $rotas += "$($f.Name) -> .\$rel"
                }
            }
        }

        if ($rotas.Count -gt 0) { throw ("Referencias rotas:`n  " + ($rotas -join "`n  ")) }
        $rotas.Count | Should Be 0
    }

    # El tercer caso que se escapo, y el mas escurridizo: el nombre del comando
    # se COMPONE. En "Instalalo con: .\Setup-$($Runtime)Env.bat" no hay ningun
    # nombre literal que buscar, asi que las dos pruebas de arriba pasan de
    # largo, y ese mensaje llevaba mandando a la raiz desde que los comandos se
    # fueron a bin\setup\. Dos mensajes, en Use-Env y en Doctor.
    #
    # Aqui no se puede comprobar el archivo -depende de una variable- pero si la
    # CARPETA, que es justo lo que se rompe al reorganizar. Y la carpeta vacia no
    # vale: en la raiz solo quedaron Empezar y Menu, que nadie compone.
    It "toda referencia a un comando compuesto apunta a una carpeta de comandos" {
        $validas = @('bin\setup', 'bin\start', 'bin\env', 'bin\kit')

        # Los shells que GENERA el kit -java21-shell.bat, node22-shell.bat- se
        # nombran igual de compuestos, pero no son comandos del kit: viven en la
        # carpeta del runtime, fuera de bin\, y ahi es donde tienen que estar.
        # Se reconocen porque su primer tramo es una carpeta del catalogo.
        $deRuntime = @((Get-RuntimeCatalog).Carpeta)
        $rotas = @()

        foreach ($f in (Get-ArchivosDelKit)) {
            $texto = Get-TextoNormalizado -Texto (Get-Content -LiteralPath $f.FullName -Raw)
            if (-not $texto) { continue }

            foreach ($m in ([regex]::Matches($texto, '\.\\([^\s"'']*\$[^\s"'']*\.bat)'))) {
                $ref = $m.Groups[1].Value
                $carpeta = Split-Path -Parent $ref
                if ($validas -contains $carpeta) { continue }

                $primero = @($ref -split '\\')[0]
                if ($deRuntime -contains $primero) { continue }

                $donde = if ($carpeta) { "la carpeta '$carpeta'" } else { "la raiz" }
                $rotas += "$($f.Name) -> .\$ref  (apunta a $donde)"
            }
        }

        if ($rotas.Count -gt 0) { throw ("Comandos compuestos mal ubicados:`n  " + ($rotas -join "`n  ")) }
        $rotas.Count | Should Be 0
    }

    # El caso que se escapo: invocar por Join-Path en vez de por texto.
    It "toda invocacion por Join-Path apunta a un archivo que existe" {
        $rotas = @()

        foreach ($f in (Get-ArchivosDelKit | Where-Object { $_.Extension -eq '.ps1' })) {
            $texto = Get-Content -LiteralPath $f.FullName -Raw
            if (-not $texto) { continue }

            foreach ($m in ([regex]::Matches($texto, 'Join-Path \$(?:Kit|DevKitRoot) "([^"]+\.bat)"'))) {
                $rel = $m.Groups[1].Value
                if ($ajenos -contains (Split-Path -Leaf $rel)) { continue }
                if (-not (Test-Path -LiteralPath (Join-Path $KitRoot $rel))) {
                    $rotas += "$($f.Name) -> $rel"
                }
            }
        }

        if ($rotas.Count -gt 0) { throw ("Invocaciones rotas:`n  " + ($rotas -join "`n  ")) }
        $rotas.Count | Should Be 0
    }

    # Cada .bat de bin\ tiene que llevar al .ps1 que le toca, y desde
    # bin\<grupo>\ hay que subir DOS niveles. Olvidar un ..\ deja el comando sin
    # arrancar.
    #
    # %~dp0 es la carpeta del PROPIO .bat, asi que la ruta se resuelve contra
    # $b.DirectoryName y no contra bin\: con los comandos repartidos en cuatro
    # subcarpetas, componerla contra bin\ daba una ruta que no existe ni cuando
    # el enlace es correcto.
    It "cada .bat de bin apunta a un .ps1 que existe" {
        $rotas = @()
        $bats = @(Get-ChildItem -LiteralPath (Join-Path $KitRoot 'bin') -Filter *.bat -File -Recurse)

        # Sin esto la prueba pasa en verde con la lista vacia, que es como se
        # quedo al mover los comandos a subcarpetas.
        $bats.Count | Should Not Be 0

        foreach ($b in $bats) {
            $texto = Get-Content -LiteralPath $b.FullName -Raw
            $m = [regex]::Match($texto, '-File "%~dp0([^"]+)"')
            if (-not $m.Success) { $rotas += "$($b.Name): no invoca ningun .ps1"; continue }

            $destino = Join-Path $b.DirectoryName $m.Groups[1].Value
            if (-not (Test-Path -LiteralPath $destino)) { $rotas += "$($b.Name) -> $($m.Groups[1].Value)" }
        }

        if ($rotas.Count -gt 0) { throw ("Enlaces rotos:`n  " + ($rotas -join "`n  ")) }
        $rotas.Count | Should Be 0
    }

    # La prueba anterior comprueba que cada .bat llegue a SU .ps1, pero no que
    # esten todos: si un comando se pierde al reorganizar carpetas, nadie se
    # entera hasta que alguien lo busca. Cada .ps1 de scripts\ tiene su .bat,
    # salvo Menu y Empezar, cuyos comandos se quedaron en la raiz.
    It "todo script de scripts\ tiene su comando en bin\ o en la raiz" {
        $faltan = @()

        foreach ($s in (Get-ChildItem -LiteralPath (Join-Path $KitRoot 'scripts') -Filter *.ps1 -File -Recurse)) {
            $bat = [IO.Path]::ChangeExtension($s.Name, '.bat')
            if (-not (Resolve-KitCommand -Nombre $bat)) { $faltan += "$($s.Name) -> falta $bat" }
        }

        if ($faltan.Count -gt 0) { throw ("Scripts sin comando:`n  " + ($faltan -join "`n  ")) }
        $faltan.Count | Should Be 0
    }

    # Los scripts pasaron a vivir dos niveles bajo la raiz (scripts\setup\ y
    # companeros). Si alguno se queda contando un solo nivel, no encuentra la
    # libreria y el comando muere al arrancar, antes de imprimir nada.
    It "todos los scripts encuentran lib\Common.ps1 desde donde estan" {
        $rotos = @()

        foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $KitRoot 'scripts') -Filter *.ps1 -File -Recurse)) {
            $texto = Get-Content -LiteralPath $f.FullName -Raw
            $m = [regex]::Match($texto, '\.\s*\(Join-Path (.+?) "lib\\Common\.ps1"\)')
            if (-not $m.Success) { $rotos += "$($f.Name): no carga la libreria"; continue }

            # Se cuentan los Split-Path para saber cuantos niveles sube, y se
            # compara con los que hay de verdad hasta la raiz del kit.
            $sube = ([regex]::Matches($m.Groups[1].Value, 'Split-Path')).Count
            $real = ($f.FullName.Substring($KitRoot.Length).Trim('\') -split '\\').Count - 1
            if ($sube -ne $real) { $rotos += "$($f.Name): sube $sube niveles y hay $real" }
        }

        if ($rotos.Count -gt 0) { throw ("Carga de la libreria rota:`n  " + ($rotos -join "`n  ")) }
        $rotos.Count | Should Be 0
    }

    # El fallo que la version anterior de esta prueba NO cazaba: comprobaba que
    # "bin\X.bat" existiera desde la raiz -y existia- pero no que la VARIABLE
    # con la que el script compone esa ruta apuntara de verdad a la raiz.
    # Empezar.ps1 hacia $Kit = Split-Path -Parent $PSScriptRoot, y al bajar un
    # nivel eso paso a valer scripts\, dejando sus cinco llamadas en el aire.
    It "ningun script calcula la raiz del kit contando carpetas" {
        $rotos = @()

        foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $KitRoot 'scripts') -Filter *.ps1 -File -Recurse)) {
            foreach ($l in (Get-Content -LiteralPath $f.FullName)) {
                # La linea que carga la libreria es la excepcion: es la unica que
                # puede contar, porque se ejecuta antes de que exista $DevKitRoot.
                if ($l -match 'lib\\Common\.ps1') { continue }
                if ($l -match '^\s*#') { continue }
                if ($l -match '\$\w+\s*=\s*Split-Path -Parent \$PSScriptRoot') {
                    $rotos += "$($f.Name): $($l.Trim())"
                }
            }
        }

        if ($rotos.Count -gt 0) {
            throw ("Deben usar `$DevKitRoot:`n  " + ($rotos -join "`n  "))
        }
        $rotos.Count | Should Be 0
    }

    # El catalogo guarda el nombre pelado del script; si el resolutor no lo
    # encuentra, Restore-Env se queda sin poder instalar ese runtime.
    It "el resolutor encuentra el script de cada runtime del catalogo" {
        foreach ($e in (Get-RuntimeCatalog)) {
            $p = Resolve-KitScript -Nombre $e.Script
            if (-not $p) { throw "Resolve-KitScript no encuentra $($e.Script) ($($e.Nombre))" }
            Test-Path -LiteralPath $p | Should Be $true
        }
    }

    It "los dos .bat de la raiz tambien llegan a su .ps1" {
        foreach ($b in (Get-ChildItem -LiteralPath $KitRoot -Filter *.bat -File)) {
            $m = [regex]::Match((Get-Content -LiteralPath $b.FullName -Raw), '-File "%~dp0([^"]+)"')
            $m.Success | Should Be $true
            Test-Path -LiteralPath (Join-Path $KitRoot $m.Groups[1].Value) | Should Be $true
        }
    }
}
