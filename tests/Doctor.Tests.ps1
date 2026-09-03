#Requires -Version 5.1
<#
    La salida JSON de Doctor.

    No se ejecuta Doctor entero: su resultado depende de lo que haya instalado
    en la maquina, asi que una prueba asi diria cosas distintas en cada equipo y
    en el runner del CI. Lo que se prueba es la TUBERIA: que las tres funciones
    de salida acumulen lo que reciben y que el volcado tenga la forma prometida.

    Las funciones se sacan del propio Doctor-Env.ps1 con el analizador de
    sintaxis, no se copian aqui: una copia se queda vieja y la prueba pasaria
    verde comprobando codigo que ya no existe.
#>

$KitRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $KitRoot "lib\Common.ps1")

function Get-TextoDeFunciones {
    <#
        El codigo fuente de unas funciones de Doctor-Env.ps1, tal cual.

        Doctor no se puede cargar entero: al final ejecuta el diagnostico y sale
        con exit, que se llevaria por delante la sesion de Pester.
    #>
    param([string[]]$Nombres)

    $ruta = Resolve-KitScript -Nombre "Doctor-Env.ps1"
    if (-not $ruta) { throw "No se encuentra Doctor-Env.ps1" }

    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ruta, [ref]$null, [ref]$null)
    $partes = @()

    foreach ($n in $Nombres) {
        $fn = $ast.Find({
            param($nodo)
            $nodo -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $nodo.Name -eq $n
        }.GetNewClosure(), $true)

        if (-not $fn) { throw "Doctor-Env.ps1 ya no define $n" }
        $partes += $fn.Extent.Text
    }

    return ($partes -join "`n")
}

# Al ambito del script, para que $script:JsonSections de las funciones y el de
# las pruebas sean el mismo.
. ([scriptblock]::Create((Get-TextoDeFunciones -Nombres @(
    'Add-JsonSection', 'Write-Section', 'Write-Check', 'Write-Detail', 'Save-DoctorJson'
))))

function Reset-Doctor {
    $script:JsonSections = @()
    $script:ReportLines  = @()
    $script:Problems     = 0
    $script:Warnings     = 0
    $script:Fixes        = @()
}

function New-DiagnosticoDeMuestra {
    Reset-Doctor
    Write-Section "Kit"
    Write-Check -Label "Version del kit" -Value $KitVersion -State 'info'
    Write-Check -Label "Archivos" -Value "completos" -State 'ok'
    Write-Section "Java"
    Write-Check -Label "JAVA_HOME vs java" -Value "descuadrados" -State 'warn'
    Write-Detail "primer detalle"
    Write-Detail "segundo detalle"
    Write-Check -Label "Algo roto" -Value "no arranca" -State 'fail'
}

Describe "Doctor -Json" {

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("doctor-prueba-{0}.json" -f [guid]::NewGuid())

    It "Doctor declara -Json y -JsonPath" {
        $txt = Get-Content -LiteralPath (Resolve-KitScript -Nombre "Doctor-Env.ps1") -Raw
        $txt | Should Match '\[switch\]\$Json'
        $txt | Should Match '\[string\]\$JsonPath'
    }

    It "cada comprobacion cae en la seccion que le toca" {
        New-DiagnosticoDeMuestra

        $script:JsonSections.Count | Should Be 2
        $script:JsonSections[0].titulo | Should Be "Kit"
        $script:JsonSections[0].comprobaciones.Count | Should Be 2
        $script:JsonSections[1].titulo | Should Be "Java"
        $script:JsonSections[1].comprobaciones.Count | Should Be 2
    }

    # Lo que hace el JSON legible: en el markdown los detalles son lineas
    # sangradas y hay que adivinar de que check cuelgan.
    It "los detalles cuelgan de su comprobacion, no de la seccion" {
        New-DiagnosticoDeMuestra

        $java = $script:JsonSections[1]
        $java.detalles.Count | Should Be 0
        $java.comprobaciones[0].detalles.Count | Should Be 2
        $java.comprobaciones[0].detalles[0] | Should Be "primer detalle"
        $java.comprobaciones[1].detalles.Count | Should Be 0
    }

    It "un detalle sin comprobacion delante no se pierde" {
        Reset-Doctor
        Write-Section "Suelta"
        Write-Detail "sin check delante"

        $script:JsonSections[0].detalles.Count | Should Be 1
        $script:JsonSections[0].comprobaciones.Count | Should Be 0
    }

    It "una comprobacion sin seccion delante tampoco" {
        Reset-Doctor
        Write-Check -Label "Huerfana" -Value "x" -State 'ok'

        $script:JsonSections.Count | Should Be 1
        $script:JsonSections[0].comprobaciones.Count | Should Be 1
    }

    It "los contadores del resumen son los que se vieron" {
        New-DiagnosticoDeMuestra
        $script:Problems | Should Be 1
        $script:Warnings | Should Be 1
    }

    It "el archivo tiene la forma prometida" {
        New-DiagnosticoDeMuestra
        $ruta = Save-DoctorJson -Destino $tmp
        Test-Path -LiteralPath $ruta | Should Be $true

        $o = Get-Content -LiteralPath $ruta -Raw | ConvertFrom-Json
        $o.version_formato | Should Be 1
        $o.kit.version | Should Be $KitVersion
        $o.resumen.problemas | Should Be 1
        $o.resumen.avisos | Should Be 1
        $o.secciones.Count | Should Be 2
        $o.secciones[1].comprobaciones[0].estado | Should Be 'warn'
        $o.secciones[1].comprobaciones[0].detalles.Count | Should Be 2
    }

    # Con la profundidad por defecto de ConvertTo-Json (2), lo que hay mas abajo
    # se aplana a una CADENA -"@{etiqueta=...; valor=...}"- y el archivo queda
    # inutil sin que nada falle al escribirlo.
    #
    # Se comprueba el tipo despues de volver a leerlo, no el texto: la primera
    # version de esta prueba buscaba el literal "System.Object" y no se enteraba,
    # porque PowerShell aplana los PSCustomObject con esa otra forma.
    It "no aplana las comprobaciones a texto por falta de profundidad" {
        New-DiagnosticoDeMuestra
        $ruta = Save-DoctorJson -Destino $tmp

        $o = Get-Content -LiteralPath $ruta -Raw | ConvertFrom-Json
        $comprobacion = $o.secciones[0].comprobaciones[0]

        ($comprobacion -is [string]) | Should Be $false
        $comprobacion.etiqueta | Should Be "Version del kit"
        ($o.secciones[1].comprobaciones[0].detalles[0] -is [string]) | Should Be $true
    }

    # Lo abre jq o Python, no el propio kit: tres bytes invisibles delante son
    # un error de sintaxis que no explica nada.
    It "se escribe sin BOM" {
        New-DiagnosticoDeMuestra
        $ruta = Save-DoctorJson -Destino $tmp

        $bytes = [IO.File]::ReadAllBytes($ruta)
        @($bytes[0], $bytes[1], $bytes[2]) -join ',' | Should Not Be '239,187,191'
    }

    It "sin -JsonPath lo deja junto a los informes" {
        New-DiagnosticoDeMuestra
        $ruta = Save-DoctorJson -Destino ''

        $ruta | Should Match ([regex]::Escape("CriisDevKit\informes"))
        $ruta | Should Match '\.json$'
        Remove-Item -LiteralPath $ruta -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}
