#Requires -Version 5.1
<#
    Ayudas compartidas por las pruebas. No es un *.Tests.ps1 a proposito:
    Run-Tests solo recoge esos, asi que este archivo se carga pero no se ejecuta
    como si tuviera pruebas dentro.
#>

function Get-TextoDeFunciones {
    <#
        El codigo fuente de unas funciones de un script del kit, tal cual.

        Existe porque varios comandos (Doctor, Menu, Update-Env) no se pueden
        cargar enteros: al final ejecutan lo suyo y salen con exit, que en medio
        de Pester se lleva por delante la sesion. Con esto se saca solo la
        funcion que interesa y se prueba la de verdad, no una copia pegada aqui
        que se quedaria vieja sin que nadie se entere.

        Quien llama hace el dot-source en SU ambito:

            . ([scriptblock]::Create((Get-TextoDeFunciones -Script X.ps1 -Nombres @('Y'))))
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Script,
        [Parameter(Mandatory=$true)][string[]]$Nombres
    )

    $ruta = Resolve-KitScript -Nombre $Script
    if (-not $ruta) { throw "No se encuentra $Script" }

    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ruta, [ref]$null, [ref]$null)
    $partes = @()

    foreach ($n in $Nombres) {
        $fn = $ast.Find({
            param($nodo)
            $nodo -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $nodo.Name -eq $n
        }.GetNewClosure(), $true)

        if (-not $fn) { throw "$Script ya no define $n" }
        $partes += $fn.Extent.Text
    }

    return ($partes -join "`n")
}
