#Requires -Version 5.1
<#
    Que la documentacion no contradiga al codigo.

    Existe por dos desfases que estuvieron a la vista durante semanas y se
    encontraron leyendo, de casualidad:

      - La maqueta del menu en el README anunciaba v2.0.0 cuando el kit iba por
        la 2.1.0, y le faltaban tres opciones (Empezar, los JDK a VS Code y la
        CA de la empresa). Alguien la dibujo a mano y el menu siguio creciendo.
      - "El kit tiene 21 comandos", cuando hay 29. El propio README decia 29
        catorce lineas mas abajo.

    Es el mismo problema que el catalogo resuelve para los runtimes: un solo
    sitio que sabe, y una prueba que se pone roja si alguien lo contradice. La
    diferencia es que aqui el "otro sitio" es prosa, que no falla al ejecutarse.

    NO comprueba que el README este bien escrito: solo que los datos que repite
    del codigo sigan siendo ciertos.
#>

$KitRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $KitRoot "lib\Common.ps1")

function Get-DocumentosDelKit {
    # Todos los .md, no solo README.md: si algun dia la documentacion se parte
    # en docs\, estas pruebas siguen encontrandola sin que nadie las toque.
    return @(Get-ChildItem -LiteralPath $KitRoot -Filter *.md -File -Recurse |
        Where-Object { $_.FullName -notlike "*\softwares_locked\*" })
}

function Get-MaquetaDelMenu {
    <#
        El bloque de codigo donde la documentacion dibuja el menu, venga del
        archivo que venga. Se reconoce por la cabecera que pinta Show-Menu.
        Devuelve $null si no hay ninguno.
    #>
    foreach ($d in (Get-DocumentosDelKit)) {
        $texto = Get-Content -LiteralPath $d.FullName -Raw
        if (-not $texto) { continue }

        foreach ($m in ([regex]::Matches($texto, '(?s)```(.*?)```'))) {
            if ($m.Groups[1].Value -match 'CriisDevKit v') {
                return [PSCustomObject]@{ Archivo = $d.Name; Texto = $m.Groups[1].Value }
            }
        }
    }
    return $null
}

function Get-OpcionesDelMenu {
    <#
        Las opciones REALES, sacadas de Menu.ps1.

        No se puede hacer dot-source del script entero: al final tiene el bucle
        que pinta y pide una tecla, y la prueba se quedaria colgada. Asi que se
        localiza la funcion con el analizador de sintaxis y se define solo ella.

        Ejecutar la funcion y no leer su texto con una expresion regular es
        deliberado: los Setup no estan escritos ahi, los numera un bucle sobre el
        catalogo. Una prueba que leyera el texto no veria esas nueve opciones, que
        son justo las que cambian al anadir un runtime.
    #>
    $ruta = Resolve-KitScript -Nombre "Menu.ps1"
    if (-not $ruta) { throw "No se encuentra Menu.ps1" }

    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ruta, [ref]$null, [ref]$null)
    $fn = $ast.Find({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-Opciones'
    }, $true)

    if (-not $fn) { throw "Menu.ps1 ya no define Get-Opciones" }

    . ([scriptblock]::Create($fn.Extent.Text))
    return @(Get-Opciones)
}

Describe "La documentacion no contradice al codigo" {

    $maqueta = Get-MaquetaDelMenu

    It "la documentacion dibuja el menu en alguna parte" {
        if (-not $maqueta) { throw "Ningun .md tiene la maqueta del menu (se busca 'CriisDevKit v')" }
        $maqueta.Texto.Length | Should BeGreaterThan 100
    }

    It "la version de la maqueta es la del kit" {
        $m = [regex]::Match($maqueta.Texto, 'CriisDevKit v([\d\.]+)')
        $m.Success | Should Be $true

        if ($m.Groups[1].Value -ne $KitVersion) {
            throw ("$($maqueta.Archivo) dibuja el menu con la version " +
                   "$($m.Groups[1].Value), y el kit va por la $KitVersion.")
        }
    }

    It "la maqueta dibuja exactamente las opciones que hay" {
        $reales = Get-OpcionesDelMenu
        $reales.Count | Should BeGreaterThan 5

        # Un numero de opcion en la maqueta: al principio de linea o en la
        # segunda columna, y siempre con dos espacios antes del texto.
        $dibujados = @([regex]::Matches($maqueta.Texto, '(?m)(?:^|\s{2})\s*(\d{1,2})\s{2}\S') |
            ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Unique)

        $esperados = @($reales.Num | Sort-Object -Unique)

        $faltan = @($esperados | Where-Object { $dibujados -notcontains $_ })
        $sobran = @($dibujados | Where-Object { $esperados -notcontains $_ })

        if ($faltan.Count -gt 0 -or $sobran.Count -gt 0) {
            $msg = "$($maqueta.Archivo) no coincide con Get-Opciones."
            if ($faltan.Count -gt 0) { $msg += "`n  Faltan en la maqueta: $($faltan -join ', ')" }
            if ($sobran.Count -gt 0) { $msg += "`n  Sobran en la maqueta: $($sobran -join ', ')" }
            throw $msg
        }
    }

    It "el texto de cada opcion es el que pinta el menu" {
        foreach ($o in (Get-OpcionesDelMenu)) {
            # Los Setup se dibujan con el nombre del runtime recortado a dos
            # columnas, asi que solo se exige el nombre; el resto va entero.
            if ($maqueta.Texto -notmatch [regex]::Escape($o.Texto)) {
                throw "$($maqueta.Archivo) no dibuja la opcion $($o.Num) '$($o.Texto)'"
            }
        }
    }

    # "El kit tiene N comandos" aparece en el README y en la cabecera de
    # Menu.ps1, y las dos se quedaron en 21 mientras bin\ crecia hasta 29.
    It "el numero de comandos que se anuncia es el que hay" {
        $reales = @(Get-ChildItem -LiteralPath (Join-Path $KitRoot 'bin') -Filter *.bat -File -Recurse).Count
        $reales | Should BeGreaterThan 0

        $fuentes = @(Get-DocumentosDelKit) + @(Get-Item -LiteralPath (Resolve-KitScript -Nombre "Menu.ps1"))
        $mal = @()

        foreach ($f in $fuentes) {
            $texto = Get-Content -LiteralPath $f.FullName -Raw
            if (-not $texto) { continue }

            foreach ($m in ([regex]::Matches($texto, 'kit tiene (\d+) comandos'))) {
                if ([int]$m.Groups[1].Value -ne $reales) {
                    $mal += "$($f.Name) dice $($m.Groups[1].Value) y hay $reales"
                }
            }
        }

        if ($mal.Count -gt 0) { throw ("Cuenta de comandos desfasada:`n  " + ($mal -join "`n  ")) }
        $mal.Count | Should Be 0
    }
}
