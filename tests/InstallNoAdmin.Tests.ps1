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
foreach ($nombre in @('Get-InstallScope', 'Show-InstallResult', 'Test-LayoutUseful')) {
    Invoke-Expression (($funciones | Where-Object { $_.Name -eq $nombre }).Extent.Text)
}

function NuevaApp($nombre, $ubicacion = '') {
    return [PSCustomObject]@{ Name = $nombre; Version = '1.0'; Location = $ubicacion }
}
$Perfil       = [Environment]::GetFolderPath('UserProfile').TrimEnd('\')
$ProgramFiles = $env:ProgramFiles.TrimEnd('\')

Describe "Get-InstallScope" {

    Context "lo que declara el instalador manda" {

        # Para un MSI, el log de Windows Installer dice "MSI_LUA: Per-User mode".
        # Es la unica fuente autoritativa y gana a cualquier deduccion.
        It "respeta el veredicto per-user aunque la entrada quedara en HKLM" {
            # Este es EXACTAMENTE el caso de 7-Zip: se instala en %LOCALAPPDATA%
            # pero registra en HKLM. Una version anterior lo declaraba 'maquina'.
            $r = Get-InstallScope -Declarado 'usuario' `
                                  -UserBefore @{} -UserAfter @{} `
                                  -MachineBefore @{} -MachineAfter @{ '7zip' = (NuevaApp '7-Zip') }
            $r.Ambito | Should Be 'usuario'
            $r.Fuente | Should Be 'el instalador'
        }

        It "respeta el veredicto per-machine" {
            $r = Get-InstallScope -Declarado 'maquina' `
                                  -UserBefore @{} -UserAfter @{ 'X' = (NuevaApp 'X') } `
                                  -MachineBefore @{} -MachineAfter @{}
            $r.Ambito | Should Be 'maquina'
        }
    }

    Context "sin veredicto, se deduce por DONDE aterrizaron los archivos" {

        It "bajo el perfil del usuario es per-user" {
            $r = Get-InstallScope -UserBefore @{} `
                                  -UserAfter @{ 'A' = (NuevaApp 'App' "$Perfil\AppData\Local\Programs\App") } `
                                  -MachineBefore @{} -MachineAfter @{}
            $r.Ambito | Should Be 'usuario'
            $r.Fuente | Should Be 'la ruta de instalacion'
        }

        # EL CASO QUE MOTIVA TODO ESTO: el instalador de Git se elevo y aterrizo
        # en Program Files, y el kit lo anuncio como per-user.
        It "bajo Program Files es de maquina" {
            $r = Get-InstallScope -UserBefore @{} -UserAfter @{} `
                                  -MachineBefore @{} `
                                  -MachineAfter @{ 'Git_is1' = (NuevaApp 'Git' "$ProgramFiles\Git") }
            $r.Ambito | Should Be 'maquina'
            $r.Claves -contains 'Git_is1' | Should Be $true
        }

        # La rama del registro NO indica el ambito: 7-Zip lo demostro.
        It "una entrada en HKLM sin ruta NO basta para decir maquina" {
            $r = Get-InstallScope -UserBefore @{} -UserAfter @{} `
                                  -MachineBefore @{} -MachineAfter @{ '7zip' = (NuevaApp '7-Zip') }
            $r.Ambito | Should Be 'desconocido'
        }
    }

    Context "casos sin informacion suficiente" {

        It "no confunde lo que ya estaba instalado con algo nuevo" {
            $previas = @{ 'Vieja' = (NuevaApp 'Ya estaba' "$ProgramFiles\Vieja") }
            $r = Get-InstallScope -UserBefore $previas -UserAfter $previas `
                                  -MachineBefore $previas -MachineAfter $previas
            $r.Ambito | Should Be 'desconocido'
        }

        It "devuelve desconocido cuando no hay rastro en ningun registro" {
            $r = Get-InstallScope -UserBefore @{} -UserAfter @{} -MachineBefore @{} -MachineAfter @{}
            $r.Ambito | Should Be 'desconocido'
        }

        It "solo cuenta lo que NO estaba antes" {
            $r = Get-InstallScope -UserBefore @{ 'A' = (NuevaApp 'A') } `
                                  -UserAfter  @{ 'A' = (NuevaApp 'A'); 'B' = (NuevaApp 'B' "$Perfil\B") } `
                                  -MachineBefore @{} -MachineAfter @{}
            $r.Claves.Count | Should Be 1
            $r.Claves[0] | Should Be 'B'
        }
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

Describe "Test-LayoutUseful" {

    # Un bundle WiX Burn responde 0 a /layout aunque no externalice nada. Con
    # windowsdesktop-runtime-10.0.10 lo comprobado fue exactamente eso: 0, y en
    # la carpeta destino una unica copia de 57 MB del propio instalador. El kit
    # lo anunciaba como "Archivos extraidos" y salia con 0.
    #
    # Se prueba con carpetas de verdad y no con dobles: la funcion solo mira el
    # sistema de archivos, asi que montar el caso cuesta menos que simularlo.

    $bundle = 'windowsdesktop-runtime-10.0.10-win-x64.exe'

    function NuevaCarpeta {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ("layout-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        return $d
    }
    function Tocar($dir, $nombre) {
        $p = Join-Path $dir $nombre
        $padre = Split-Path -Parent $p
        if (-not (Test-Path -LiteralPath $padre)) { New-Item -ItemType Directory -Path $padre -Force | Out-Null }
        Set-Content -LiteralPath $p -Value 'x'
    }

    It "solo la copia del propio bundle NO es un resultado util" {
        $d = NuevaCarpeta
        try {
            Tocar $d $bundle
            Test-LayoutUseful -DestDir $d -InstallerPath "C:\descargas\$bundle" | Should Be $false
        }
        finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "una carga externalizada junto al bundle SI es util" {
        $d = NuevaCarpeta
        try {
            Tocar $d $bundle
            Tocar $d 'windowsdesktop-runtime.msi'
            Test-LayoutUseful -DestDir $d -InstallerPath "C:\descargas\$bundle" | Should Be $true
        }
        finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "encuentra las cargas aunque queden en subcarpetas" {
        $d = NuevaCarpeta
        try {
            Tocar $d $bundle
            Tocar $d 'packages\dotnet\dotnet.msi'
            Test-LayoutUseful -DestDir $d -InstallerPath "C:\descargas\$bundle" | Should Be $true
        }
        finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "una carpeta vacia tampoco es un resultado util" {
        $d = NuevaCarpeta
        try {
            Test-LayoutUseful -DestDir $d -InstallerPath "C:\descargas\$bundle" | Should Be $false
        }
        finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
