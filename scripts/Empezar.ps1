#Requires -Version 5.1
<#
.SYNOPSIS
    Empezar.ps1 - Poner en marcha el kit en un equipo nuevo, en orden.
.DESCRIPTION
    Los comandos del kit ya existen todos y Doctor te dice cual falta en cada
    caso. Lo que no habia era el ORDEN, y en un portatil recien formateado eso
    es justo lo que no se sabe.

    Esto no instala nada por su cuenta: llama a los mismos .bat de siempre, en
    la secuencia que tiene sentido, preguntando antes de cada paso.

        1. Como esta la red      (proxy, interceptacion TLS)
        2. La CA de la empresa   si hace falta
        3. Las herramientas      desde tu devenv.json, o desde el menu
        4. VS Code               que conozca los JDK
        5. Use-Env               si algo del equipo tapa a lo del kit
        6. Doctor                para ver como quedo

    Cada paso se puede saltar. No hay ninguno obligatorio.
.PARAMETER Path
    devenv.json a reproducir. Si se omite, se busca en la carpeta actual.
.PARAMETER Force
    No pregunta: hace los pasos que puede sin intervencion y salta el resto.
    Pensado para probarlo, no para el uso normal.
.EXAMPLE
    .\Empezar.ps1
.EXAMPLE
    .\Empezar.ps1 -Path C:\proyectos\mi-app\devenv.json
#>

param(
    [string]$Path,

    [switch]$Force
)

$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

$Kit = Split-Path -Parent $PSScriptRoot
$env:ASSASSINSKIPADM_NOPAUSE = "1"

function Confirmar {
    <#
        Con -Force no se pregunta y se responde que NO: los pasos que tocan el
        perfil o descargan cosas no deben dispararse solos por probar esto.
    #>
    param([string]$Pregunta)

    if ($Force) {
        Write-Host "  $Pregunta  -> (con -Force se salta)" -ForegroundColor DarkGray
        return $false
    }
    Write-Host ""
    $r = Read-Host "  $Pregunta (s/N)"
    return ($r -match '^(s|si|y|yes)$')
}

function Write-Dato {
    param([string]$Etiqueta, [string]$Valor)
    Write-Host ("  {0,-20} {1}" -f $Etiqueta, $Valor)
}

function Paso {
    param([int]$Numero, [string]$Titulo)
    Write-Host ""
    Write-Host "------------------------------------------------" -ForegroundColor Cyan
    Write-Host "  $Numero. $Titulo" -ForegroundColor Cyan
    Write-Host "------------------------------------------------" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  AssassinSkipAdm v$KitVersion - puesta en marcha" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Todo se instala en:  $WorkspaceRoot" -ForegroundColor Gray
Write-Host "Nada de esto pide permisos de administrador." -ForegroundColor Gray

# --------------------------------------------------------------------------
Paso 1 "Como esta tu red"
# --------------------------------------------------------------------------

$proxy = Resolve-DownloadProxy -Uri ([Uri]"https://api.adoptium.net")
if ($proxy) {
    $limpio = (Split-ProxyCredential -Proxy $proxy).Direccion
    Write-Dato "Proxy" $limpio
}
else {
    Write-Dato "Proxy" "ninguno; se sale directo a internet"
}

$jdks = @(Get-KitJdkLines)
$interceptado = $null
if ($jdks.Count -eq 0) {
    Write-Dato "Interceptacion TLS" "no se puede saber todavia (hace falta un JDK con que comparar)"
}
else {
    $hallazgo = Find-CorpCa
    $interceptado = $hallazgo
    if ($hallazgo.Interceptado) {
        Write-Dato "Interceptacion TLS" "SI - $($hallazgo.Motivo)"
    }
    else {
        Write-Dato "Interceptacion TLS" "no - $($hallazgo.Motivo)"
    }
}

# --------------------------------------------------------------------------
Paso 2 "La CA de tu empresa"
# --------------------------------------------------------------------------

$yaHayCa = Test-Path -LiteralPath $CorpCaFile

if ($yaHayCa) {
    Write-Host "  Ya hay una CA guardada; se reaplica sola a lo que instales." -ForegroundColor Green
}
elseif ($jdks.Count -eq 0) {
    Write-Host "  Se mira despues de instalar, cuando haya un JDK con que comparar." -ForegroundColor Gray
}
elseif ($interceptado -and $interceptado.Interceptado) {
    Write-Host "  Tu red abre el HTTPS. Sin la CA, Maven fallara con PKIX path" -ForegroundColor Yellow
    Write-Host "  building failed, pip con SSLCertVerificationError y git con" -ForegroundColor Yellow
    Write-Host "  'SSL certificate problem', aunque el navegador vaya bien." -ForegroundColor Yellow
    if (Confirmar "Se la pongo a las herramientas del kit?") {
        & (Join-Path $Kit "Use-CorpCert.bat") -Force
    }
}
else {
    Write-Host "  No hace falta: tu red no esta abriendo el HTTPS." -ForegroundColor Green
}

# --------------------------------------------------------------------------
Paso 3 "Las herramientas"
# --------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = Join-Path (Get-Location).Path "devenv.json"
}

$instalado = @('Python','Java','Node','Angular','Git','Maven','Gradle','Dotnet','VSCode' |
               Where-Object { Test-Path (Join-Path $WorkspaceRoot $_) })

if ($instalado.Count -gt 0) {
    Write-Host "  Ya tienes: $($instalado -join ', ')" -ForegroundColor Green
}

if (Test-Path -LiteralPath $Path) {
    Write-Host "  Hay un manifiesto: $Path" -ForegroundColor Green
    Write-Host "  Reproducirlo instala de golpe lo que pide ese proyecto." -ForegroundColor Gray
    if (Confirmar "Lo reproduzco?") {
        & (Join-Path $Kit "Restore-Env.bat") -Path $Path -Force
    }
}
else {
    Write-Host "  No hay devenv.json en $((Get-Location).Path)" -ForegroundColor Gray
    Write-Host "  Se instala a mano desde el menu, o con los Setup-*Env.bat." -ForegroundColor Gray
    if ($instalado.Count -eq 0 -and (Confirmar "Abro el menu para elegir?")) {
        & (Join-Path $Kit "Menu.bat")
    }
}

# --------------------------------------------------------------------------
Paso 4 "VS Code y los JDK"
# --------------------------------------------------------------------------

$targets = @(Get-VSCodeSettingsTargets)
$jdks = @(Get-KitJdkLines)

if ($jdks.Count -eq 0) {
    Write-Host "  No hay ningun JDK del kit; nada que registrar." -ForegroundColor Gray
}
elseif ($targets.Count -eq 0) {
    Write-Host "  No se ha encontrado ningun VS Code." -ForegroundColor Gray
}
else {
    foreach ($t in $targets) { Write-Host "  Encontrado: $($t.Etiqueta)" -ForegroundColor Green }
    Write-Host "  Registrarlos deja que cada proyecto compile con el JDK que pide." -ForegroundColor Gray
    if (Confirmar "Se los registro al VS Code portable del kit?") {
        & (Join-Path $Kit "Use-VSCodeJava.bat") -Force
    }
}

# --------------------------------------------------------------------------
Paso 5 "Lo que el equipo tapa"
# --------------------------------------------------------------------------

Write-Host "  El PATH de Windows pone primero lo que instalo tu empresa, asi que" -ForegroundColor Gray
Write-Host "  un java o un git suyos responden antes que los del kit. Use-Env lo" -ForegroundColor Gray
Write-Host "  resuelve enganchandose a tu perfil de PowerShell y al AutoRun de cmd." -ForegroundColor Gray
Write-Host ""
Write-Host "  Es el unico paso que sale de las carpetas del kit." -ForegroundColor Yellow
Write-Host "  Se revierte entero con:  .\Use-Env.bat -Off" -ForegroundColor Gray
Write-Host ""
Write-Host "  Doctor te dira abajo si de verdad hace falta. Si no aparece ningun" -ForegroundColor Gray
Write-Host "  'NO es la del kit', dejalo como esta." -ForegroundColor Gray

# --------------------------------------------------------------------------
Paso 6 "Como ha quedado"
# --------------------------------------------------------------------------

& (Join-Path $Kit "Doctor-Env.bat") -SkipNetwork

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  Listo" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "A partir de aqui:" -ForegroundColor Yellow
Write-Host "  .\Menu.bat        todo lo que sabe hacer el kit" -ForegroundColor White
Write-Host "  .\Doctor-Env.bat  que esta mal y como arreglarlo" -ForegroundColor White
Write-Host ""
