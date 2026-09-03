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

function Get-ArchivosDelKit {
    # Este mismo archivo queda fuera: habla DE las referencias, asi que sus
    # ejemplos (".\X.bat") no son referencias reales y se senalarian solos.
    return @(
        (Get-ChildItem -LiteralPath $KitRoot -Filter *.bat -File),
        (Get-ChildItem -LiteralPath (Join-Path $KitRoot 'bin') -Filter *.bat -File -ErrorAction SilentlyContinue),
        (Get-ChildItem -LiteralPath (Join-Path $KitRoot 'scripts') -Filter *.ps1 -File),
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

    It "los dos .bat de la raiz tambien llegan a su .ps1" {
        foreach ($b in (Get-ChildItem -LiteralPath $KitRoot -Filter *.bat -File)) {
            $m = [regex]::Match((Get-Content -LiteralPath $b.FullName -Raw), '-File "%~dp0([^"]+)"')
            $m.Success | Should Be $true
            Test-Path -LiteralPath (Join-Path $KitRoot $m.Groups[1].Value) | Should Be $true
        }
    }
}
