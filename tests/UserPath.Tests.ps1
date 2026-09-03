#Requires -Version 5.1
<#
    Pruebas de Add-UserPathEntry y Remove-UserPathEntry, que son las funciones
    mas delicadas del kit: un fallo aqui corrompe el PATH del usuario.

    SEGURIDAD DE LAS PRUEBAS: nunca tocan el registro. Se sustituyen las dos
    unicas puertas al mundo real, Get-RawUserPath (lectura) y Save-UserPath
    (escritura + copia de seguridad + notificacion a Windows), asi que lo que se
    ejercita es la logica de seleccion y ordenacion, en memoria.

    Si alguien elimina esos mocks, estas pruebas reescribirian el PATH de quien
    las ejecute. Por eso hay un test que comprueba que el mock esta puesto.
#>

. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

Describe "Add-UserPathEntry" {

    BeforeEach {
        $script:pathSimulado = 'C:\Windows;C:\Windows\System32'
        $script:guardado     = $null
        $script:vecesGuardado = 0

        Mock Get-RawUserPath { return $script:pathSimulado }
        Mock Save-UserPath {
            $script:guardado = $Updated
            $script:vecesGuardado++
            return 'C:\backup-simulado.txt'
        }
        # El PATH del proceso tambien se toca; se aisla para no ensuciar la sesion.
        $script:envPrevio = $env:Path
    }

    AfterEach { $env:Path = $script:envPrevio }

    It "no escribe en el registro de verdad" {
        Add-UserPathEntry -Path 'C:\nuevo'
        Assert-MockCalled Save-UserPath -Times 1 -Scope It
        Assert-MockCalled Get-RawUserPath -Scope It
    }

    It "coloca la ruta nueva AL PRINCIPIO" {
        # Windows resuelve el PATH de izquierda a derecha. Anadir al final hacia
        # que, con varias versiones instaladas, respondiera la primera instalada
        # y no la que el usuario acababa de instalar.
        Add-UserPathEntry -Path 'C:\nuevo'
        $script:guardado | Should Be 'C:\nuevo;C:\Windows;C:\Windows\System32'
    }

    It "con -Append la coloca al final" {
        Add-UserPathEntry -Path 'C:\nuevo' -Append
        $script:guardado | Should Be 'C:\Windows;C:\Windows\System32;C:\nuevo'
    }

    It "mueve al principio una ruta que ya estaba al final" {
        # Solo anadir no bastaba: una ruta ya presente seguia perdiendo prioridad.
        Add-UserPathEntry -Path 'C:\Windows\System32'
        $script:guardado | Should Be 'C:\Windows\System32;C:\Windows'
    }

    It "no duplica al ejecutarlo dos veces" {
        Add-UserPathEntry -Path 'C:\nuevo'
        $script:pathSimulado = $script:guardado
        Add-UserPathEntry -Path 'C:\nuevo'

        @(Split-UserPath -Value $script:pathSimulado | Where-Object { $_ -eq 'C:\nuevo' }).Count |
            Should Be 1
    }

    It "no reescribe si el PATH ya estaba correcto" {
        $script:pathSimulado = 'C:\nuevo;C:\Windows'
        Add-UserPathEntry -Path 'C:\nuevo'
        Assert-MockCalled Save-UserPath -Times 0 -Scope It
    }

    # El fallo original: la deteccion de duplicados usaba -like "*$ruta*", que
    # interpreta la ruta como PATRON de comodines. Con corchetes en el nombre,
    # nunca casaba y se anadia una entrada nueva en cada ejecucion.
    It "no duplica rutas con corchetes en el nombre" {
        $conCorchetes = 'C:\Users\test\Angular [v20]'
        $script:pathSimulado = "$conCorchetes;C:\Windows"
        Add-UserPathEntry -Path $conCorchetes
        Assert-MockCalled Save-UserPath -Times 0 -Scope It
    }

    It "admite varias rutas de golpe y conserva su orden" {
        Add-UserPathEntry -Path @('C:\uno', 'C:\dos')
        $script:guardado | Should Be 'C:\uno;C:\dos;C:\Windows;C:\Windows\System32'
    }

    It "ignora la barra final al comparar" {
        $script:pathSimulado = 'C:\nuevo\;C:\Windows'
        Add-UserPathEntry -Path 'C:\nuevo'
        @(Split-UserPath -Value $script:guardado | Where-Object { $_ -like 'C:\nuevo*' }).Count |
            Should Be 1
    }
}

Describe "Remove-UserPathEntry" {

    BeforeEach {
        $script:pathSimulado = 'C:\Windows;C:\kit\Python\python-3.12;C:\kit\Python\python-3.12\Scripts;C:\otra'
        $script:guardado     = $null

        Mock Get-RawUserPath { return $script:pathSimulado }
        Mock Save-UserPath {
            $script:guardado = $Updated
            return 'C:\backup-simulado.txt'
        }
    }

    It "quita todo lo que cuelga de una carpeta" {
        # Es como desinstala el kit: no depende de acertar la ruta exacta que se
        # anadio, sino de la carpeta raiz que va a borrar.
        $n = Remove-UserPathEntry -UnderFolder 'C:\kit\Python\python-3.12'
        $n | Should Be 2
        $script:guardado | Should Be 'C:\Windows;C:\otra'
    }

    It "quita una ruta exacta" {
        $n = Remove-UserPathEntry -Path @('C:\otra')
        $n | Should Be 1
        $script:guardado | Should Be 'C:\Windows;C:\kit\Python\python-3.12;C:\kit\Python\python-3.12\Scripts'
    }

    It "devuelve 0 y no escribe si no hay nada que quitar" {
        $n = Remove-UserPathEntry -UnderFolder 'C:\no\existe'
        $n | Should Be 0
        Assert-MockCalled Save-UserPath -Times 0 -Scope It
    }

    # Una carpeta que empiece igual NO debe caer: borrar C:\kit\Python\python-3.1
    # no puede llevarse por delante python-3.12.
    It "no se lleva carpetas que solo comparten prefijo" {
        $script:pathSimulado = 'C:\kit\Python\python-3.1;C:\kit\Python\python-3.12'
        $n = Remove-UserPathEntry -UnderFolder 'C:\kit\Python\python-3.1'
        $n | Should Be 1
        $script:guardado | Should Be 'C:\kit\Python\python-3.12'
    }

    It "conserva las entradas con %VAR% sin expandirlas al guardar" {
        # Expandirlas al escribir degradaria el PATH del usuario en cada pasada,
        # congelando %USERPROFILE% como ruta absoluta.
        $script:pathSimulado = '%USERPROFILE%\bin;C:\kit\Python\python-3.12'
        Remove-UserPathEntry -UnderFolder 'C:\kit\Python\python-3.12' | Out-Null
        $script:guardado | Should Be '%USERPROFILE%\bin'
    }
}

Describe "Split-UserPath" {

    It "descarta entradas vacias y solo-espacios" {
        (Split-UserPath -Value 'C:\a;;C:\b;   ;C:\c').Count | Should Be 3
    }

    It "devuelve coleccion vacia para un PATH vacio" {
        (Split-UserPath -Value '').Count | Should Be 0
    }
}
