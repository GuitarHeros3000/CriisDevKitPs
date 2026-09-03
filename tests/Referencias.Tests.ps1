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
    return @(
        (Get-ChildItem -LiteralPath $KitRoot -Filter *.bat -File),
        (Get-ChildItem -LiteralPath (Join-Path $KitRoot 'bin') -Filter *.bat -File -ErrorAction SilentlyContinue),
        (Get-ChildItem -LiteralPath (Join-Path $KitRoot 'scripts') -Filter *.ps1 -File -Recurse),
        (Get-ChildItem -LiteralPath (Join-Path $KitRoot 'lib') -Filter *.ps1 -File),
        (Get-ChildItem -LiteralPath (Join-Path $KitRoot 'tests') -Filter *.ps1 -File),
        (Get-Item -LiteralPath (Join-Path $KitRoot 'README.md'))
    ) | ForEach-Object { $_ } | Where-Object { $_.Name -ne 'Referencias.Tests.ps1' }
}

Describe "Referencias a comandos del kit" {

    # Los .bat que el kit genera dentro de las carpetas de los runtimes
    # -java25-shell.bat, post-install.bat- no son comandos del kit y no tienen
    # por que existir en el repositorio.
    $ajenos = @('post-install.bat')

    It "toda mencion del tipo .\algo.bat apunta a un archivo que existe" {
        $rotas = @()

        foreach ($f in (Get-ArchivosDelKit)) {
            $texto = Get-Content -LiteralPath $f.FullName -Raw
            if (-not $texto) { continue }

            foreach ($m in ([regex]::Matches($texto, '\.\\((?:bin\\)?[A-Za-z][A-Za-z-]*\.bat)'))) {
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

    # Cada .bat de bin\ tiene que llevar al .ps1 que le toca, y desde bin\ hay
    # que subir un nivel. Olvidar el ..\ deja el comando sin arrancar.
    It "cada .bat de bin apunta a un .ps1 que existe" {
        $rotas = @()

        foreach ($b in (Get-ChildItem -LiteralPath (Join-Path $KitRoot 'bin') -Filter *.bat -File)) {
            $texto = Get-Content -LiteralPath $b.FullName -Raw
            $m = [regex]::Match($texto, '-File "%~dp0([^"]+)"')
            if (-not $m.Success) { $rotas += "$($b.Name): no invoca ningun .ps1"; continue }

            $destino = Join-Path (Join-Path $KitRoot 'bin') $m.Groups[1].Value
            if (-not (Test-Path -LiteralPath $destino)) { $rotas += "$($b.Name) -> $($m.Groups[1].Value)" }
        }

        if ($rotas.Count -gt 0) { throw ("Enlaces rotos:`n  " + ($rotas -join "`n  ")) }
        $rotas.Count | Should Be 0
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
