#Requires -Version 5.1
<#
    Arquitectura: deteccion, nomenclatura por fuente y URLs.

    ESTAS PRUEBAS NO DEMUESTRAN QUE ARM64 FUNCIONE. Demuestran que el kit pide
    lo que hay que pedir. Que un JDK aarch64 descargado arranque de verdad solo
    se puede comprobar en una maquina ARM, y no la hay.

    Lo que si cubren es el fallo mas probable y el mas dificil de ver: cada
    fuente llama a las arquitecturas como le da la gana, y equivocarse da un 404
    -o peor, un binario de la arquitectura que no es- sin explicar nada. Los dos
    nombres raros estan comprobados contra las APIs reales:

      Adoptium   aarch64  y no arm64
      python.org amd64    y no x64
#>

$KitRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $KitRoot "lib\Common.ps1")

Describe "Get-KitArchitecture" {

    AfterEach { $env:CRIISDEVKIT_ARCH = $null }

    It "devuelve x64 o arm64, nunca otra cosa" {
        $env:CRIISDEVKIT_ARCH = $null
        (Get-KitArchitecture) -in @('x64', 'arm64') | Should Be $true
    }

    It "CRIISDEVKIT_ARCH la fuerza" {
        $env:CRIISDEVKIT_ARCH = 'arm64'
        Get-KitArchitecture | Should Be 'arm64'
        $env:CRIISDEVKIT_ARCH = 'x64'
        Get-KitArchitecture | Should Be 'x64'
    }

    It "admite mayusculas y espacios al forzarla" {
        $env:CRIISDEVKIT_ARCH = '  ARM64 '
        Get-KitArchitecture | Should Be 'arm64'
    }

    # Un valor invalido no se ignora: quien lo puso creia estar forzando algo.
    It "un valor invalido es un error, no un silencio" {
        $env:CRIISDEVKIT_ARCH = 'x86'
        { Get-KitArchitecture } | Should Throw
    }
}

Describe "Get-ArchToken" {

    # Los dos que no se llaman igual que los demas. Si alguien los "arregla"
    # para que sean coherentes, el kit se queda sin poder descargar.
    It "Adoptium dice aarch64, no arm64" {
        Get-ArchToken -Fuente adoptium -Arch arm64 | Should Be 'aarch64'
    }

    It "python.org dice amd64, no x64" {
        Get-ArchToken -Fuente python -Arch x64 | Should Be 'amd64'
    }

    It "el resto usa los nombres normales" {
        foreach ($f in @('node', 'dotnet', 'vscode')) {
            Get-ArchToken -Fuente $f -Arch x64   | Should Be 'x64'
            Get-ArchToken -Fuente $f -Arch arm64 | Should Be 'arm64'
        }
        Get-ArchToken -Fuente adoptium -Arch x64   | Should Be 'x64'
        Get-ArchToken -Fuente python   -Arch arm64 | Should Be 'arm64'
    }

    It "sin -Arch usa la de la maquina" {
        $env:CRIISDEVKIT_ARCH = 'arm64'
        try     { Get-ArchToken -Fuente node | Should Be 'arm64' }
        finally { $env:CRIISDEVKIT_ARCH = $null }
    }

    It "una fuente desconocida no cuela" {
        { Get-ArchToken -Fuente 'inventada' -Arch x64 } | Should Throw
    }
}

Describe "Las URLs cambian con la arquitectura" {

    AfterEach { $env:CRIISDEVKIT_ARCH = $null }

    # Se comprueba la URL COMPUESTA y no el token suelto: entre uno y otra hay
    # una plantilla donde es facil dejarse el x64 pegado.
    It "el .NET SDK apunta a win-arm64" {
        $env:CRIISDEVKIT_ARCH = 'arm64'
        $a = Get-BundleArchiveInfo -Clave 'dotnet' -Version '9.0.100'
        $a.Url | Should Match 'win-arm64\.zip$'
        $a.FileName | Should Match 'win-arm64\.zip$'
    }

    It "el .NET SDK sigue apuntando a win-x64 en x64" {
        $env:CRIISDEVKIT_ARCH = 'x64'
        (Get-BundleArchiveInfo -Clave 'dotnet' -Version '9.0.100').Url | Should Match 'win-x64\.zip$'
    }

    It "VS Code apunta al archive de la arquitectura" {
        $env:CRIISDEVKIT_ARCH = 'arm64'
        (Get-BundleArchiveInfo -Clave 'vscode' -Version '1.136.0').Url | Should Match 'win32-arm64-archive'
        $env:CRIISDEVKIT_ARCH = 'x64'
        (Get-BundleArchiveInfo -Clave 'vscode' -Version '1.136.0').Url | Should Match 'win32-x64-archive'
    }

    It "Python pide el embed de la arquitectura" {
        $env:CRIISDEVKIT_ARCH = 'arm64'
        (Get-PythonArchiveInfo -FullVersion '3.12.10').FileName | Should Be 'python-3.12.10-embed-arm64.zip'
        $env:CRIISDEVKIT_ARCH = 'x64'
        (Get-PythonArchiveInfo -FullVersion '3.12.10').FileName | Should Be 'python-3.12.10-embed-amd64.zip'
    }
}

Describe "Carpetas de Node de las dos arquitecturas" {

    # El zip de Node trae dentro una carpeta node-vX-win-<arch>, y ese nombre lo
    # leen Doctor, Uninstall-Env, Export-Env y CorpNet con una expresion regular.
    # Si se quedan en x64, una instalacion arm64 queda INVISIBLE para todos: se
    # instala bien y despues nadie la encuentra ni la puede desinstalar.
    $patron = '^node-v(.+)-win-(?:x64|arm64)$'

    It "el patron reconoce las dos" {
        'node-v22.14.0-win-x64'   | Should Match $patron
        'node-v22.14.0-win-arm64' | Should Match $patron
    }

    It "y saca la misma version de las dos" {
        'node-v22.14.0-win-arm64' -match $patron | Out-Null
        $Matches[1] | Should Be '22.14.0'
    }

    # Solo lib\ y scripts\: en tests\ hay URLs de ejemplo con un node-v...-win-x64
    # literal que son datos de prueba -se esta probando el reescrito de espejos,
    # no el reconocimiento de carpetas- y marcarlas seria un falso positivo.
    It "ningun archivo de lib\ ni scripts\ se quedo con el patron de solo x64" {
        $malos = @()
        $fuentes = @(
            (Get-ChildItem -LiteralPath (Join-Path $KitRoot 'lib') -Filter *.ps1 -File),
            (Get-ChildItem -LiteralPath (Join-Path $KitRoot 'scripts') -Filter *.ps1 -File -Recurse)
        ) | ForEach-Object { $_ }

        foreach ($f in $fuentes) {
            $texto = Get-Content -LiteralPath $f.FullName -Raw
            if (-not $texto) { continue }

            # node-v...-win-x64 sin la alternativa al lado
            foreach ($m in ([regex]::Matches($texto, 'node-v[^\r\n]{0,20}-win-x64'))) {
                if ($m.Value -notmatch 'arm64') { $malos += "$($f.Name): $($m.Value)" }
            }
        }

        if ($malos.Count -gt 0) { throw ("Se quedaron en x64:`n  " + ($malos -join "`n  ")) }
        $malos.Count | Should Be 0
    }
}

Describe "Test-ArchSoportada" {

    # Comprobado contra la API de GitHub: Git for Windows no publica ningun
    # asset arm64. En una maquina ARM se coge el x64 y Windows lo emula.
    It "avisa de que Git no es nativo en arm64" {
        $r = Test-ArchSoportada -Clave 'git' -Arch 'arm64'
        $r.Soportada | Should Be $false
        $r.Motivo | Should Match 'arm64'
    }

    It "en x64 Git no tiene nada que avisar" {
        (Test-ArchSoportada -Clave 'git' -Arch 'x64').Soportada | Should Be $true
    }

    It "los demas runtimes son nativos en las dos" {
        foreach ($e in (Get-RuntimeCatalog | Where-Object { $_.Clave -ne 'git' })) {
            foreach ($a in @('x64', 'arm64')) {
                (Test-ArchSoportada -Clave $e.Clave -Arch $a).Soportada | Should Be $true
            }
        }
    }
}
