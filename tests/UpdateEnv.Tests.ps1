#Requires -Version 5.1
<#
    Update-Env -Apply.

    Lo que se prueba es la TUBERIA entre "aqui tienes el comando" y "ejecutalo",
    que es donde -Apply puede fallar en silencio: si el .bat no se resuelve o
    los argumentos se parten mal, el comando que se imprime y el que se ejecuta
    dejan de ser el mismo, y eso no se ve mirando la pantalla.

    No se ejecutan actualizaciones de verdad: descargarian cientos de MB y
    dependerian de lo que haya instalado en la maquina.
#>

$KitRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $KitRoot "lib\Common.ps1")
. (Join-Path $PSScriptRoot "Helpers.ps1")

. ([scriptblock]::Create((Get-TextoDeFunciones -Script "Update-Env.ps1" -Nombres @('Add-Fila'))))

function Reset-Filas {
    $script:Filas  = @()
    $script:SinRed = $false
}

Describe "Update-Env -Apply" {

    It "Update-Env declara -Apply y -Force" {
        $txt = Get-Content -LiteralPath (Resolve-KitScript -Nombre "Update-Env.ps1") -Raw
        $txt | Should Match '\[switch\]\$Apply'
        $txt | Should Match '\[switch\]\$Force'
    }

    # Lo que de verdad importa: el comando que se IMPRIME y el que se EJECUTA
    # tienen que salir de la misma cadena.
    It "el comando impreso se resuelve a un .bat que existe" {
        Reset-Filas
        Add-Fila -Que "Java 21" -Instalado "21.0.1" -Disponible "21.0.2" `
                 -Comando ".\bin\setup\Setup-JavaEnv.bat -JavaVersion 21 -Force"

        $f = $script:Filas[0]
        $f.Estado | Should Be 'actualizable'
        $f.Bat | Should Not BeNullOrEmpty
        Test-Path -LiteralPath $f.Bat | Should Be $true
        (Split-Path -Leaf $f.Bat) | Should Be 'Setup-JavaEnv.bat'
    }

    It "los argumentos se conservan en orden y sin el .bat delante" {
        Reset-Filas
        Add-Fila -Que "Java 21" -Instalado "21.0.1" -Disponible "21.0.2" `
                 -Comando ".\bin\setup\Setup-JavaEnv.bat -JavaVersion 21 -Force"

        $args_ = @($script:Filas[0].Argumentos)
        $args_.Count | Should Be 3
        $args_[0] | Should Be '-JavaVersion'
        $args_[1] | Should Be '21'
        $args_[2] | Should Be '-Force'
    }

    # Resolve-KitCommand y no la ruta literal: es el mismo resolutor que usa el
    # menu, asi que mover los comandos de carpeta no rompe -Apply.
    It "se resuelve por el nombre, no por la ruta escrita en el comando" {
        Reset-Filas
        Add-Fila -Que "Java 21" -Instalado "21.0.1" -Disponible "21.0.2" `
                 -Comando ".\una\ruta\que\no\existe\Setup-JavaEnv.bat -JavaVersion 21"

        Test-Path -LiteralPath $script:Filas[0].Bat | Should Be $true
    }

    It "una fila al dia no se marca como actualizable" {
        Reset-Filas
        Add-Fila -Que "Java 21" -Instalado "21.0.2" -Disponible "21.0.2" `
                 -Comando ".\bin\setup\Setup-JavaEnv.bat -JavaVersion 21 -Force"

        $script:Filas[0].Estado | Should Be 'al dia'
    }

    It "sin red la fila queda en desconocido y no se aplicaria" {
        Reset-Filas
        Add-Fila -Que "Java 21" -Instalado "21.0.1" -Disponible $null `
                 -Comando ".\bin\setup\Setup-JavaEnv.bat -JavaVersion 21 -Force"

        $script:Filas[0].Estado | Should Be 'desconocido'
        $script:SinRed | Should Be $true
    }

    It "un comando vacio no revienta el parseo" {
        Reset-Filas
        Add-Fila -Que "Algo" -Instalado "1" -Disponible "2" -Comando ""

        $script:Filas[0].Bat | Should BeNullOrEmpty
        @($script:Filas[0].Argumentos).Count | Should Be 0
    }

    # Un .bat que no se resuelve tiene que parar la tanda entera: aplicar la
    # mitad deja el entorno en un estado que nadie pidio y que no se ve.
    It "un comando que no se resuelve deja Bat vacio, para poder pararlo" {
        Reset-Filas

        # El nombre se compone en vez de escribirlo entero, y no por gusto: si
        # aparece completo en este archivo -aunque sea dentro de un comentario,
        # que es como fallo el primer intento- la prueba de referencias lo lee
        # como un comando roto de verdad, y tendria razon. Excluir el archivo
        # entero la dejaria ciega para las referencias que si importan.
        $inventado = "Setup-" + "NoExiste" + "Env.bat"

        Add-Fila -Que "Fantasma" -Instalado "1" -Disponible "2" `
                 -Comando ".\bin\setup\$inventado -Force"

        $script:Filas[0].Bat | Should BeNullOrEmpty
    }

    It "Update-Env se para si algo no se resuelve, en vez de aplicar a medias" {
        $txt = Get-Content -LiteralPath (Resolve-KitScript -Nombre "Update-Env.ps1") -Raw
        $txt | Should Match 'sinResolver'
        $txt | Should Match 'No se aplica nada'
    }

    # El aviso tiene que salir ANTES de confirmar y nombrando las versiones
    # afectadas: enterrado al final de la lista no lo leia nadie, y perder los
    # paquetes pip no tiene vuelta atras.
    It "avisa de los paquetes pip antes de pedir confirmacion" {
        $txt = Get-Content -LiteralPath (Resolve-KitScript -Nombre "Update-Env.ps1") -Raw

        $posAviso   = $txt.IndexOf('BORRA sus paquetes pip')
        $posConfirm = $txt.IndexOf('Confirmas?')

        $posAviso | Should Not Be -1
        $posConfirm | Should Not Be -1
        ($posAviso -lt $posConfirm) | Should Be $true
    }

    It "restaura CRIISDEVKIT_NOPAUSE al terminar" {
        $txt = Get-Content -LiteralPath (Resolve-KitScript -Nombre "Update-Env.ps1") -Raw
        $txt | Should Match 'pausePrevio'
        $txt | Should Match 'finally'
    }
}
