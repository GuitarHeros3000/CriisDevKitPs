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

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Common.ps1")

# Los comandos se invocan con Resolve-KitCommand y no componiendo rutas a mano.
# Este archivo y los .bat se han movido de sitio dos veces, y las dos veces las
# rutas escritas a mano se quedaron apuntando a donde ya no habia nada.
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

function Invoke-PasoCa {
    <#
        Mira si la red intercepta el HTTPS y, si hace falta, ofrece poner la CA.

        Devuelve $true si ya se ha resuelto la cuestion, y $false si NO SE HA
        PODIDO MIRAR todavia por no haber ningun JDK con que comparar.

        Ese $false es el motivo de que esto sea una funcion y no codigo suelto:
        en un equipo recien formateado no hay JDK, asi que la primera vez no se
        puede decidir, y hay que volver a preguntarlo despues de instalar. Sin
        eso, el caso para el que existe este comando -portatil nuevo- se quedaba
        sin comprobar la CA en silencio, y el primer 'mvn install' fallaba con
        PKIX sin que nada lo hubiera avisado.
    #>
    if (Test-Path -LiteralPath $CorpCaFile) {
        Write-Host "  Ya hay una CA guardada; se reaplica sola a lo que instales." -ForegroundColor Green
        return $true
    }

    if (@(Get-KitJdkLines).Count -eq 0) { return $false }

    $hallazgo = Find-CorpCa
    if (-not $hallazgo.Interceptado) {
        Write-Host "  No hace falta: $($hallazgo.Motivo)." -ForegroundColor Green
        return $true
    }

    Write-Host "  Tu red abre el HTTPS: $($hallazgo.Motivo)." -ForegroundColor Yellow
    Write-Host "  Sin la CA, Maven fallara con PKIX path building failed, pip con" -ForegroundColor Yellow
    Write-Host "  SSLCertVerificationError y git con 'SSL certificate problem'," -ForegroundColor Yellow
    Write-Host "  aunque el navegador vaya bien." -ForegroundColor Yellow
    if (Confirmar "Se la pongo a las herramientas del kit?") {
        & (Resolve-KitCommand -Nombre "Use-CorpCert.bat") -Force
    }
    return $true
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
if ($jdks.Count -eq 0) {
    Write-Dato "Interceptacion TLS" "aun no se puede saber (hace falta un JDK con que comparar)"
}

# --------------------------------------------------------------------------
Paso 2 "La CA de tu empresa"
# --------------------------------------------------------------------------

$caResuelta = Invoke-PasoCa
if (-not $caResuelta) {
    Write-Host "  Se mira despues de instalar, cuando haya un JDK con que comparar." -ForegroundColor Gray
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
        & (Resolve-KitCommand -Nombre "Restore-Env.bat") -Path $Path -Force
    }
}
else {
    Write-Host "  No hay devenv.json en $((Get-Location).Path)" -ForegroundColor Gray
    Write-Host "  Se instala a mano desde el menu, o con los Setup-*Env.bat." -ForegroundColor Gray
    if ($instalado.Count -eq 0 -and (Confirmar "Abro el menu para elegir?")) {
        & (Resolve-KitCommand -Nombre "Menu.bat")
    }
}

# La pregunta de la CA que quedo en el aire por no haber JDK. Si ahora si lo
# hay, se resuelve aqui; si no, se dice para que no se quede en el olvido.
if (-not $caResuelta) {
    Write-Host ""
    Write-Host "  Vuelvo a lo de la CA, que antes no se podia mirar:" -ForegroundColor Cyan
    if (-not (Invoke-PasoCa)) {
        Write-Host "  Sigue sin haber ningun JDK. Cuando instales uno:" -ForegroundColor Gray
        Write-Host "    .\bin\env\Use-CorpCert.bat" -ForegroundColor White
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
        & (Resolve-KitCommand -Nombre "Use-VSCodeJava.bat") -Force
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
Write-Host "  Se revierte entero con:  .\bin\env\Use-Env.bat -Off" -ForegroundColor Gray
Write-Host ""
Write-Host "  Doctor te dira abajo si de verdad hace falta. Si no aparece ningun" -ForegroundColor Gray
Write-Host "  'NO es la del kit', dejalo como esta." -ForegroundColor Gray

# --------------------------------------------------------------------------
Paso 6 "Como ha quedado"
# --------------------------------------------------------------------------

& (Resolve-KitCommand -Nombre "Doctor-Env.bat") -SkipNetwork

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  Listo" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "A partir de aqui:" -ForegroundColor Yellow
Write-Host "  .\Menu.bat        todo lo que sabe hacer el kit" -ForegroundColor White
Write-Host "  .\bin\kit\Doctor-Env.bat  que esta mal y como arreglarlo" -ForegroundColor White
Write-Host ""
