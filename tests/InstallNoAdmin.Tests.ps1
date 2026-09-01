#Requires -Version 5.1
<#
    Pruebas de Get-InstallScope, que decide DONDE aterrizo de verdad una
    instalacion.

    Existe por un fallo real: con el instalador de Git, el kit lo ejecuto con
    /CURRENTUSER, el instalador lo ignoro, pidio permiso de administrador, se le
    concedio y se instalo para toda la maquina. El instalador devolvio 0 y el kit
    anuncio "INSTALACION COMPLETADA (per-user) - sin admin". Falso, y justo lo
    contrario del proposito del kit.

    La logica es pura -compara dos fotos del registro-, asi que se puede probar
    el caso de la elevacion sin instalar nada con admin.
#>

$KitRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $KitRoot "lib\Common.ps1")

# Install-NoAdmin.ps1 es un script ejecutable: se extrae solo la funcion por AST
# para no disparar su programa principal.
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $KitRoot "scripts\Install-NoAdmin.ps1"), [ref]$null, [ref]$null)
$funciones = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true)
foreach ($nombre in @('Get-InstallScope', 'Show-InstallResult')) {
    Invoke-Expression (($funciones | Where-Object { $_.Name -eq $nombre }).Extent.Text)
}

function NuevaApp($nombre) {
    return [PSCustomObject]@{ Name = $nombre; Version = '1.0'; Location = "C:\algun\sitio" }
}

Describe "Get-InstallScope" {

    It "detecta una instalacion per-user" {
        $r = Get-InstallScope -UserBefore @{} -UserAfter @{ 'App1' = (NuevaApp 'App Uno') } `
                              -MachineBefore @{} -MachineAfter @{}
        $r.Ambito | Should Be 'usuario'
        $r.Claves.Count | Should Be 1
    }

    # EL CASO QUE MOTIVA TODO ESTO: el instalador se elevo y aterrizo en HKLM.
    # Antes esto era indistinguible de "instalo bien y no dejo entrada".
    It "detecta que se instalo para toda la maquina" {
        $r = Get-InstallScope -UserBefore @{} -UserAfter @{} `
                              -MachineBefore @{} -MachineAfter @{ 'Git_is1' = (NuevaApp 'Git') }
        $r.Ambito | Should Be 'maquina'
        $r.Claves -contains 'Git_is1' | Should Be $true
    }

    It "no confunde lo que ya estaba instalado con algo nuevo" {
        $previas = @{ 'Vieja' = (NuevaApp 'Ya estaba') }
        $r = Get-InstallScope -UserBefore $previas -UserAfter $previas `
                              -MachineBefore $previas -MachineAfter $previas
        $r.Ambito | Should Be 'desconocido'
    }

    It "devuelve desconocido cuando no hay rastro en ningun registro" {
        # Pasa de verdad: hay paquetes que no se registran. No es un fallo, pero
        # tampoco se puede afirmar que fuera per-user.
        $r = Get-InstallScope -UserBefore @{} -UserAfter @{} -MachineBefore @{} -MachineAfter @{}
        $r.Ambito | Should Be 'desconocido'
    }

    # Si aparece en los dos, mandar el de maquina: significa que hubo elevacion,
    # que es lo que el usuario necesita saber. Decir "usuario" ahi seria repetir
    # el fallo original con otra cara.
    It "prioriza maquina cuando aparecen entradas en ambos" {
        $r = Get-InstallScope -UserBefore @{} -UserAfter @{ 'U' = (NuevaApp 'EnUsuario') } `
                              -MachineBefore @{} -MachineAfter @{ 'M' = (NuevaApp 'EnMaquina') }
        $r.Ambito | Should Be 'maquina'
    }

    It "solo cuenta lo que NO estaba antes" {
        $r = Get-InstallScope -UserBefore @{ 'A' = (NuevaApp 'A') } `
                              -UserAfter  @{ 'A' = (NuevaApp 'A'); 'B' = (NuevaApp 'B') } `
                              -MachineBefore @{} -MachineAfter @{}
        $r.Ambito | Should Be 'usuario'
        $r.Claves.Count | Should Be 1
        $r.Claves[0] | Should Be 'B'
    }
}

Describe "Show-InstallResult" {

    # Se prueba el mensaje Y el codigo de salida de los tres caminos sin instalar
    # nada. El camino 'maquina' es el que fallaba, y sin poder ejercitarlo asi
    # habria que elevar de verdad para comprobarlo, que es lo que impidio verlo.
    # Se captura por REDIRECCION del flujo de informacion (6), que es donde
    # escribe Write-Host desde PowerShell 5. Nada de sustituir Write-Host por una
    # funcion global: un primer intento lo hizo y la sustitucion se filtro a los
    # demas archivos de prueba, tumbando 13 tests del PATH. Y el Remove-Item que
    # debia deshacerlo usaba una ruta invalida con -ErrorAction SilentlyContinue,
    # asi que fallaba en silencio.
    function Codigo($scope) { return (Show-InstallResult -Scope $scope 6>$null) }
    function Texto($scope)  { return ((Show-InstallResult -Scope $scope 6>&1) | Out-String) }

    It "per-user: dice que se evito el admin y sale con 0" {
        $scope = [PSCustomObject]@{ Ambito = 'usuario'; Claves = @(); Registro = @{} }
        (Codigo $scope) | Should Be 0
        (Texto $scope)  | Should Match 'sin admin'
    }

    # El fallo original: aqui se anunciaba "per-user, sin admin".
    It "maquina: NO dice que fuera per-user, y sale con 2" {
        $scope = [PSCustomObject]@{
            Ambito = 'maquina'
            Claves = @('Git_is1')
            Registro = @{ 'Git_is1' = (NuevaApp 'Git') }
        }
        (Codigo $scope) | Should Be 2

        $texto = Texto $scope
        $texto | Should Match 'TODA LA MAQUINA'
        $texto | Should Match 'NO se ha evitado el admin'
        $texto | Should Match 'Git'
        # Lo que NUNCA debe decir en este caso:
        $texto | Should Not Match 'INSTALACION COMPLETADA \(per-user\)'
        $texto | Should Not Match 'Se instalo en tu perfil de usuario, sin admin'
    }

    It "desconocido: no afirma nada, y sale con 0" {
        $scope = [PSCustomObject]@{ Ambito = 'desconocido'; Claves = @(); Registro = @{} }
        (Codigo $scope) | Should Be 0
        $texto = Texto $scope
        $texto | Should Match 'SIN CONFIRMAR'
        $texto | Should Not Match 'sin admin'
    }

    It "sin informacion de ambito, tampoco afirma que fuera per-user" {
        (Codigo $null) | Should Be 0
        (Texto $null)  | Should Not Match 'Se instalo en tu perfil de usuario'
    }
}
