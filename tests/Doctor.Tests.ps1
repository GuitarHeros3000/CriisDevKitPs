#Requires -Version 5.1
<#
    La salida JSON de Doctor.

    No se ejecuta Doctor entero: su resultado depende de lo que haya instalado
    en la maquina, asi que una prueba asi diria cosas distintas en cada equipo y
    en el runner del CI. Lo que se prueba es la TUBERIA: que las tres funciones
    de salida acumulen lo que reciben y que el volcado tenga la forma prometida.

    Las funciones son las de lib\Doctor.ps1, cargadas tal cual: una copia aqui
    se quedaria vieja y la prueba pasaria verde comprobando codigo que ya no
    existe.
#>

$KitRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $KitRoot "lib\Common.ps1")
. (Join-Path $PSScriptRoot "Helpers.ps1")

# Al ambito del script, para que $script:JsonSections de las funciones y el de
# las pruebas sean el mismo.
. (Join-Path $KitRoot "lib\Doctor.ps1")

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

Describe "Doctor mas rapido" {

    # Se puede probar porque las comprobaciones viven en lib\Doctor.ps1: antes
    # habia que sacarlas del script con el analizador de sintaxis.

    Context "la version de ng y npm, sin ejecutarlos" {

        $d = Join-Path ([IO.Path]::GetTempPath()) ("npmver-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path (Join-Path $d 'node_modules\@angular\cli'), (Join-Path $d 'node_modules\npm') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'node_modules\@angular\cli\package.json') -Value '{ "name": "@angular/cli", "version": "20.2.0" }'
        Set-Content -LiteralPath (Join-Path $d 'node_modules\npm\package.json') -Value '{ "name": "npm", "version": "11.5.2" }'

        It "lee la de ng de su package.json" {
            Get-NpmScriptVersion -Exe (Join-Path $d 'ng.cmd') | Should Be '20.2.0'
        }

        It "y la de npm" {
            Get-NpmScriptVersion -Exe (Join-Path $d 'npm.cmd') | Should Be '11.5.2'
        }

        It "sin package.json devuelve nulo, y entonces se pregunta como siempre" {
            Get-NpmScriptVersion -Exe (Join-Path $d 'sub\ng.cmd') | Should BeNullOrEmpty
        }

        It "de otros comandos no intenta nada" {
            Get-NpmScriptVersion -Exe (Join-Path $d 'node.exe') | Should BeNullOrEmpty
        }

        Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context "las comprobaciones de red, a la vez" {

        $datos = [Text.Encoding]::ASCII.GetBytes('ok')

        function New-Peticion {
            param($Servidor, [string]$Nombre)
            [PSCustomObject]@{ Name = $Nombre; Params = @{ Uri = $Servidor.Url; UseBasicParsing = $true; TimeoutSec = 10; Method = 'Head' } }
        }

        # Tres servidores que tardan 1,2 s cada uno: en serie serian 3,6 s.
        It "tardan lo que el mas lento, no la suma" {
            $s = @(1..3 | ForEach-Object { Start-ServidorDePrueba -Contenido $datos -Retraso 1200 })
            try {
                $sw = [Diagnostics.Stopwatch]::StartNew()
                $r = @(Invoke-ParallelProbes -Peticiones @($s | ForEach-Object { New-Peticion $_ "s$($s.IndexOf($_))" }))
                $sw.Stop()
                @($r | Where-Object { $_.Ok }).Count | Should Be 3
                $sw.ElapsedMilliseconds | Should BeLessThan 3000
            }
            finally { foreach ($x in $s) { & $x.Parar } }
        }

        It "los resultados salen en el orden en que se pidieron" {
            $lento = Start-ServidorDePrueba -Contenido $datos -Retraso 900
            $rapido = Start-ServidorDePrueba -Contenido $datos
            try {
                $r = @(Invoke-ParallelProbes -Peticiones @((New-Peticion $lento 'primero'), (New-Peticion $rapido 'segundo')))
                ($r | ForEach-Object { $_.Name }) -join ',' | Should Be 'primero,segundo'
            }
            finally { & $lento.Parar; & $rapido.Parar }
        }

        # El error cruza de hilo y se sigue pudiendo traducir: sin eso, Doctor
        # diria "NO alcanzable" sin decir por que.
        It "un fallo trae su error, y se traduce como antes" {
            $s = Start-ServidorDePrueba -Contenido $datos -Estado 404
            try {
                $r = @(Invoke-ParallelProbes -Peticiones @(New-Peticion $s 'roto'))[0]
                $r.Ok | Should Be $false
                Get-DownloadErrorHint -ErrorRecord $r.Error | Should Match '404'
            }
            finally { & $s.Parar }
        }
    }
}
