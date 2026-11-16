#Requires -Version 5.1
<#
    Pruebas de lib\Project.ps1: que pide un proyecto, leido de sus archivos.

    Todo sin red y sin instalar nada: se fabrican carpetas de proyecto con sus
    pyproject.toml, .python-version, package.json o pom.xml, y se comprueba lo
    que se deduce de ellas. Los casos salen de los proyectos reales de quien
    usa el kit: requires-python ">=3.10", ">=3.11" y ">=3.12", un .venv por
    proyecto, y alguno con uv.lock.
#>

$KitRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $KitRoot "lib\Common.ps1")
. (Join-Path $KitRoot "lib\Project.ps1")

$RaizTmp = Join-Path ([IO.Path]::GetTempPath()) ("proyecto-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $RaizTmp -Force | Out-Null

function New-Proyecto {
    param([hashtable]$Archivos = @{})
    $d = Join-Path $RaizTmp ([Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    foreach ($k in $Archivos.Keys) {
        $f = Join-Path $d $k
        New-Item -ItemType Directory -Path (Split-Path -Parent $f) -Force | Out-Null
        [IO.File]::WriteAllText($f, $Archivos[$k])
    }
    return $d
}

Describe "Test-PythonLineSpec" {

    $casos = @(
        @{ L = '3.12'; S = '>=3.11';          E = $true }
        @{ L = '3.10'; S = '>=3.11';          E = $false }
        # Lo que cumple un parche de la linea basta: se instala el ultimo.
        @{ L = '3.11'; S = '>=3.11.4';        E = $true }
        @{ L = '3.12'; S = '>=3.10,<3.12';    E = $false }
        @{ L = '3.11'; S = '>=3.10, <3.12';   E = $true }
        @{ L = '3.12'; S = '<=3.12';          E = $true }
        @{ L = '3.12'; S = '==3.12.*';        E = $true }
        @{ L = '3.13'; S = '==3.12.*';        E = $false }
        @{ L = '3.13'; S = '==3.*';           E = $true }
        @{ L = '3.12'; S = '!=3.12.*';        E = $false }
        @{ L = '3.12'; S = '!=3.12.1';        E = $true }
        @{ L = '3.13'; S = '~=3.11';          E = $true }
        @{ L = '3.12'; S = '~=3.11.2';        E = $false }
        @{ L = '3.11'; S = '~=3.11.2';        E = $true }
    )
    foreach ($c in $casos) {
        It "$($c.L) con '$($c.S)' -> $($c.E)" {
            Test-PythonLineSpec -Linea $c.L -Spec $c.S | Should Be $c.E
        }
    }

    # Mejor decir "no lo entiendo" que adivinar y montar el venv con otra.
    It "lo que no entiende devuelve nulo, no un si o un no" {
        Test-PythonLineSpec -Linea '3.12' -Spec '>=3.11; python_version' | Should BeNullOrEmpty
    }
}

Describe "Select-PythonLine" {

    It "prefiere una ya instalada que lo cumpla: no se descarga nada" {
        Select-PythonLine -Spec '>=3.10' -Instaladas @('3.11', '3.13') | Should Be '3.13'
    }

    It "sin nada instalado, la del kit si lo cumple" {
        Select-PythonLine -Spec '>=3.11' | Should Be '3.12'
    }

    It "si la del kit no lo cumple, la mas baja que si" {
        Select-PythonLine -Spec '>=3.13' | Should Be '3.13'
        Select-PythonLine -Spec '<3.12' | Should Be '3.10'
    }

    It "si nada lo cumple, nulo" {
        Select-PythonLine -Spec '>=4.0' | Should BeNullOrEmpty
    }
}

Describe "Get-PyProjectInfo" {

    $toml = @'
[build-system]
requires = ["setuptools"]

[project]
name = "animusframe"
requires-python = ">=3.12"
dependencies = [
    "requests[security]>=2.31",   # con corchete dentro
    'pillow',
    # comentado = no cuenta
    "customtkinter==5.2.2",
]

[project.optional-dependencies]
dev = ["pytest"]
'@

    It "lee requires-python" {
        (Get-PyProjectInfo -Texto $toml).RequiresPython | Should Be '>=3.12'
    }

    # Una regex que corta en el primer "]" se quedaba en "requests[security".
    It "lee las dependencias enteras, aunque lleven corchetes" {
        ((Get-PyProjectInfo -Texto $toml).Dependencias) -join '|' | Should Be 'requests[security]>=2.31|pillow|customtkinter==5.2.2'
    }

    It "no mezcla las opcionales" {
        (Get-PyProjectInfo -Texto $toml).Dependencias -contains 'pytest' | Should Be $false
    }

    It "reconoce un proyecto de Poetry" {
        (Get-PyProjectInfo -Texto "[tool.poetry]`nname = 'x'").Poetry | Should Be $true
    }
}

Describe "Get-JavaMajorFromBuild" {

    It "Maven: maven.compiler.release" {
        Get-JavaMajorFromBuild -Tipo maven -Texto '<properties><maven.compiler.release>21</maven.compiler.release></properties>' | Should Be 21
    }
    It "Maven: java.version de Spring, tambien con 1.8" {
        Get-JavaMajorFromBuild -Tipo maven -Texto '<java.version>17</java.version>' | Should Be 17
        Get-JavaMajorFromBuild -Tipo maven -Texto '<java.version>1.8</java.version>' | Should Be 8
    }
    It "Gradle: el toolchain" {
        Get-JavaMajorFromBuild -Tipo gradle -Texto 'java { toolchain { languageVersion = JavaLanguageVersion.of(17) } }' | Should Be 17
    }
    It "Gradle: sourceCompatibility" {
        Get-JavaMajorFromBuild -Tipo gradle -Texto 'sourceCompatibility = JavaVersion.VERSION_11' | Should Be 11
    }
    It "sin nada, nulo" {
        Get-JavaMajorFromBuild -Tipo maven -Texto '<project></project>' | Should BeNullOrEmpty
    }
}

Describe "Get-VenvInfo" {

    # El .venv copiado de otra maquina: su pyvenv.cfg apunta a un Python que
    # aqui no esta, y "python" dentro de el falla sin decir eso.
    It "senala un .venv cuyo Python base ya no existe" {
        $p = New-Proyecto @{ '.venv\pyvenv.cfg' = "home = C:\no\existe\python-3.11`r`nversion = 3.11.9`r`n" }
        $v = Get-VenvInfo -Ruta (Join-Path $p '.venv')
        $v.Existe | Should Be $true
        $v.BaseExiste | Should Be $false
        $v.Linea | Should Be '3.11'
    }

    It "lee version_info, que es como lo escribe uv" {
        $p = New-Proyecto @{ '.venv\pyvenv.cfg' = "home = C:\x`r`nversion_info = 3.12.16`r`n" }
        (Get-VenvInfo -Ruta (Join-Path $p '.venv')).Version | Should Be '3.12.16'
    }

    It "sin .venv, Existe es falso" {
        (Get-VenvInfo -Ruta (Join-Path (New-Proyecto) '.venv')).Existe | Should Be $false
    }
}

Describe "Get-ProjectNeeds" {

    It "un proyecto Python con requires-python y requirements.txt" {
        $p = New-Proyecto @{ 'pyproject.toml' = "[project]`nrequires-python = `">=3.11`"`n"; 'requirements.txt' = "requests`n" }
        $n = Get-ProjectNeeds -Ruta $p
        $n.Python.Linea | Should Be '3.12'
        $n.Python.Dependencias | Should Be 'requirements'
        $n.Node | Should BeNullOrEmpty
        $n.Java | Should BeNullOrEmpty
    }

    It ".python-version manda sobre requires-python" {
        $p = New-Proyecto @{ '.python-version' = "3.11.9`n"; 'pyproject.toml' = "[project]`nrequires-python = `">=3.12`"`n" }
        $n = Get-ProjectNeeds -Ruta $p
        $n.Python.Linea | Should Be '3.11'
        $n.Python.Exacta | Should Be '3.11.9'
        $n.Python.Fuente | Should Be '.python-version'
    }

    It "sin requirements.txt, las dependencias de pyproject.toml" {
        $p = New-Proyecto @{ 'pyproject.toml' = "[project]`ndependencies = [`"pillow`", `"numpy>=2`"]`n" }
        $n = Get-ProjectNeeds -Ruta $p
        $n.Python.Dependencias | Should Be 'pyproject'
        ($n.Python.Paquetes -join ',') | Should Be 'pillow,numpy>=2'
    }

    It "avisa de que un uv.lock no se respeta" {
        $p = New-Proyecto @{ 'pyproject.toml' = "[project]`n"; 'uv.lock' = '' }
        ((Get-ProjectNeeds -Ruta $p).Python.Avisos -join ' ') | Should Match 'uv\.lock'
    }

    It "Node: engines de package.json y si hay lock" {
        $p = New-Proyecto @{ 'package.json' = '{ "name": "x", "engines": { "node": ">=20.11" } }'; 'package-lock.json' = '{}' }
        $n = Get-ProjectNeeds -Ruta $p
        $n.Node.Pista.Tipo | Should Be 'rango'
        $n.Node.Pista.Valor | Should Be '>=20.11'
        $n.Node.Lock | Should Be $true
    }

    It "Node: .nvmrc manda sobre engines" {
        $p = New-Proyecto @{ 'package.json' = '{ "engines": { "node": ">=18" } }'; '.nvmrc' = "v22.11.0`n" }
        $h = (Get-ProjectNeeds -Ruta $p).Node.Pista
        $h.Tipo | Should Be 'mayor'
        $h.Valor | Should Be '22'
    }

    It "Java con Maven sin mvnw: hay que poner Maven" {
        $p = New-Proyecto @{ 'pom.xml' = '<project><properties><maven.compiler.release>17</maven.compiler.release></properties></project>' }
        $j = (Get-ProjectNeeds -Ruta $p).Java
        $j.Mayor | Should Be 17
        $j.Maven | Should Be $true
    }

    It "con su propio mvnw no hace falta Maven" {
        $p = New-Proyecto @{ 'pom.xml' = '<project/>'; 'mvnw.cmd' = '' }
        (Get-ProjectNeeds -Ruta $p).Java.Maven | Should Be $false
    }

    It "una carpeta sin nada de esto no pide nada" {
        $n = Get-ProjectNeeds -Ruta (New-Proyecto @{ 'LEEME.md' = 'hola' })
        $n.Python | Should BeNullOrEmpty
        $n.Node | Should BeNullOrEmpty
        $n.Java | Should BeNullOrEmpty
    }
}

Remove-Item -LiteralPath $RaizTmp -Recurse -Force -ErrorAction SilentlyContinue
