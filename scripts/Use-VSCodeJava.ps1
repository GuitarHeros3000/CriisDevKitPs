#Requires -Version 5.1
<#
.SYNOPSIS
    Use-VSCodeJava.ps1 - Que VS Code conozca los JDK del kit.
.DESCRIPTION
    La extension de Java de VS Code no lee la version de Java del proyecto por
    arte de magia: usa el JAVA_HOME del proceso, que es uno solo para todas las
    ventanas y solo cambia al reiniciar el editor.

    Lo que si sabe hacer es elegir un JDK POR PROYECTO si le dices cuales tienes.
    Eso es java.configuration.runtimes, y es lo que escribe este comando con los
    JDK del kit. A partir de ahi, un proyecto que declara Java 21 compila con el
    21 y uno que declara 25 con el 25, en el mismo VS Code y sin tocar ningun
    archivo de los proyectos.

    Es aditivo: los JDK que ya tuvieras registrados a mano no se pierden, solo se
    reemplazan los que apuntan a la carpeta Java del kit.

    NO toca java.jdt.ls.java.home, que es el JDK con el que arranca el propio
    servidor de la extension. Ese ya lo resuelve ella sola, y cambiarlo puede
    dejar sin Java a un editor que funcionaba.
    El ajuste solo hace algo si ese VS Code tiene la extension de Java. El
    portable del kit viene sin ninguna, asi que se comprueba y se dice; con
    -InstallExtension se instala, que tampoco pide admin.
.PARAMETER Default
    Linea del JDK que se usara en un proyecto que no declare ninguno (ej: 21).
    Si se omite, el mas alto instalado por el kit.
.PARAMETER InstallExtension
    Instala el pack de Java en el VS Code que no lo tenga. Se descarga del
    marketplace, asi que necesita red (y usa el proxy del kit si lo hay).
.PARAMETER Path
    settings.json concreto. Si se omite, todos los VS Code que se encuentren.
.PARAMETER Remove
    Quita los JDK del kit del settings.json y deja los demas.
.PARAMETER Force
    No pregunta antes de escribir.
.PARAMETER WhatIf
    Ensena que cambiaria y no toca nada.
.EXAMPLE
    .\Use-VSCodeJava.ps1 -WhatIf
.EXAMPLE
    .\Use-VSCodeJava.ps1 -Default 21
.EXAMPLE
    .\Use-VSCodeJava.ps1 -Remove
#>

param(
    [string]$Default,

    [string]$Path,

    [switch]$InstallExtension,

    [switch]$Remove,

    [switch]$Force,

    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

$JavaRoot = Join-Path $WorkspaceRoot "Java"
$Clave    = 'java.configuration.runtimes'

# La que lee java.configuration.runtimes es redhat.java; el pack la arrastra
# junto al depurador, las pruebas, Maven y Gradle, que es lo que se espera al
# decir "quiero Java en VS Code".
$ExtLenguaje = 'redhat.java'
$ExtPack     = 'vscjava.vscode-java-pack'

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Los JDK del kit, dentro de VS Code" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# --- Que JDK hay ---

$lineas = @(Get-KitJdkLines)
if ($lineas.Count -eq 0 -and -not $Remove) {
    Write-Log "El kit no tiene ningun JDK instalado." "ERROR"
    Write-Log "  Instala uno con:  .\Setup-JavaEnv.bat" "WARN"
    exit 1
}

if ($Default -and $lineas -notcontains $Default) {
    Write-Log "El kit no tiene instalado el JDK $Default." "ERROR"
    Write-Log "  Instalado: $(if ($lineas.Count) { $lineas -join ', ' } else { '(ninguno)' })" "WARN"
    exit 1
}

# Sin -Default manda el mas alto, que es el mismo criterio que sigue el resto del
# kit cuando hay que elegir uno.
$porDefecto = if ($Default) { $Default } elseif ($lineas.Count -gt 0) { $lineas[-1] } else { $null }
$delKit     = @(Get-KitJavaRuntimeEntries -Default $porDefecto)

if (-not $Remove) {
    Write-Log "JDK del kit: $($lineas -join ', ')   (por defecto: $porDefecto)" "SUCCESS"
    Write-Host ""
}

# --- Donde escribir ---

if ($Path) {
    $targets = @([PSCustomObject]@{ Etiqueta = "settings.json indicado"; Ruta = $Path; DelKit = $false })
}
else {
    $targets = @(Get-VSCodeSettingsTargets)
}

if ($targets.Count -eq 0) {
    Write-Log "No se ha encontrado ningun VS Code en este equipo." "ERROR"
    Write-Log "  Instala el portable del kit:  .\Setup-VSCodeEnv.bat" "WARN"
    Write-Log "  O indica el settings.json a mano:  -Path <ruta>" "WARN"
    exit 1
}

# --- Que cambiaria en cada uno ---

$planes = @()

foreach ($t in $targets) {
    Write-Host "--- $($t.Etiqueta)" -ForegroundColor Cyan
    Write-Host "    $($t.Ruta)" -ForegroundColor DarkGray

    $ajustes = $null
    if (Test-Path -LiteralPath $t.Ruta) {
        $texto = Get-Content -LiteralPath $t.Ruta -Raw
        if ([string]::IsNullOrWhiteSpace($texto)) {
            $ajustes = [PSCustomObject]@{}
        }
        else {
            try { $ajustes = $texto | ConvertFrom-Json }
            catch {
                # settings.json admite comentarios y ConvertFrom-Json no. Aqui se
                # para en vez de reescribirlo: perder los comentarios de alguien
                # por un comando que iba de otra cosa no es aceptable.
                Write-Host ""
                Write-Log "Ese settings.json no es JSON puro (lleva comentarios o una coma de mas)." "WARN"
                Write-Log "  No se toca. Anade esto a mano dentro de las llaves:" "WARN"
                Write-Host ""
                Write-Host ("  ""$Clave"": " + (ConvertTo-Json $delKit -Depth 5)) -ForegroundColor White
                Write-Host ""
                continue
            }
        }
    }
    else {
        # No tenerlo es normal: se crea al cambiar el primer ajuste.
        Write-Host "    (aun no existe; se creara)" -ForegroundColor DarkGray
        $ajustes = [PSCustomObject]@{}
    }

    $actual = @()
    if ($ajustes.PSObject.Properties[$Clave]) { $actual = @($ajustes.$Clave) }

    $resultado = @(Merge-VSCodeJavaRuntimes -Actual $actual -DelKit $delKit -RaizJava $JavaRoot -Quitar:$Remove)

    $antes   = ($actual    | ForEach-Object { "$($_.name)=$($_.path)" }) -join '|'
    $despues = ($resultado | ForEach-Object { "$($_.name)=$($_.path)" }) -join '|'
    $defAntes   = @($actual    | Where-Object { $_.default }).name -join ','
    $defDespues = @($resultado | Where-Object { $_.default }).name -join ','

    $cambia = -not ($antes -eq $despues -and $defAntes -eq $defDespues)

    # Sin la extension de Java, este ajuste no lo lee nadie. El portable del kit
    # viene sin ninguna extension, asi que es el caso normal y no una rareza.
    # Se mira ANTES de descartar un settings.json que ya estaba al dia: si no, la
    # segunda ejecucion diria "ya esta" sobre un VS Code que no puede usarlo.
    $faltaJava = $false
    if (-not $Remove) {
        $faltaJava = @(Get-VSCodeExtensions -SettingsPath $t.Ruta) -notcontains $ExtLenguaje
    }

    if (-not $cambia -and -not $faltaJava) {
        Write-Host "    ya estaba al dia" -ForegroundColor Green
        Write-Host ""
        continue
    }

    if ($cambia) {
        foreach ($r in $resultado) {
            $esDelKit = ([string]$r.path).StartsWith($JavaRoot, [StringComparison]::OrdinalIgnoreCase)
            $marca = if ($r.default) { "   <- por defecto" } else { "" }
            $quien = if ($esDelKit) { "" } else { "   (ya estaba, no es del kit)" }
            Write-Host ("    + {0,-14} {1}{2}{3}" -f $r.name, $r.path, $marca, $quien) -ForegroundColor White
        }
        foreach ($r in $actual) {
            $sigue = @($resultado | Where-Object { $_.path -eq $r.path }).Count -gt 0
            if (-not $sigue) {
                Write-Host ("    - {0,-14} {1}" -f $r.name, $r.path) -ForegroundColor DarkYellow
            }
        }
        if ($resultado.Count -eq 0) { Write-Host "    (queda sin ningun runtime registrado)" -ForegroundColor DarkYellow }
    }
    else {
        Write-Host "    los JDK ya estaban registrados" -ForegroundColor Green
    }

    if ($faltaJava) {
        if ($InstallExtension) {
            Write-Host "    falta la extension de Java: se instalara $ExtPack" -ForegroundColor Yellow
        }
        else {
            Write-Host "    OJO: este VS Code no tiene la extension de Java," -ForegroundColor Yellow
            Write-Host "         asi que el ajuste no hara nada hasta instalarla." -ForegroundColor Yellow
            Write-Host "         Anade -InstallExtension y se instala aqui mismo." -ForegroundColor Gray
        }
    }
    Write-Host ""

    $planes += [PSCustomObject]@{
        Target    = $t
        Ajustes   = $ajustes
        Runtimes  = $resultado
        Cambia    = $cambia
        FaltaJava = $faltaJava
    }
}

if ($planes.Count -eq 0) {
    Write-Log "No hay nada que cambiar." "SUCCESS"
    Write-Host ""
    exit 0
}

Write-Host "Se hara una copia del settings.json antes de escribirlo." -ForegroundColor DarkGray
Write-Host "La extension de Java lo relee al reiniciar VS Code." -ForegroundColor DarkGray
Write-Host ""

if ($WhatIf) {
    Write-Host "-WhatIf: no se ha tocado nada." -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

if (-not $Force) {
    $answer = Read-Host "Escribo? (escribe SI)"
    if ($answer -ne 'SI') {
        Write-Host "Cancelado. No se ha tocado nada." -ForegroundColor Yellow
        exit 0
    }
    Write-Host ""
}

# --- Escribir ---

$fallos = 0

foreach ($p in $planes) {
    $ruta = $p.Target.Ruta

    if ($p.FaltaJava -and $InstallExtension) {
        $cli = Get-VSCodeCli -SettingsPath $ruta
        if (-not $cli) {
            Write-Log "No se encontro el code.cmd de $($p.Target.Etiqueta); no se instala la extension" "WARN"
        }
        else {
            Write-Log "Instalando $ExtPack en $($p.Target.Etiqueta)..." "INFO"
            Write-Log "  (se descarga del marketplace; tarda un rato)" "INFO"
            $r = Install-VSCodeExtension -CodeCmd $cli -Id $ExtPack
            if ($r.Ok) {
                Write-Log "Extension instalada" "SUCCESS"
            }
            else {
                Write-Log "No se pudo instalar la extension" "ERROR"
                $r.Salida | Select-Object -Last 3 | ForEach-Object { Write-Log "  $_" "WARN" }
                # El ajuste se escribe igual: cuando la instalen a mano, ya esta.
                $fallos++
            }
        }
    }

    if (-not $p.Cambia) { continue }

    try {
        $carpeta = Split-Path -Parent $ruta
        if (-not (Test-Path -LiteralPath $carpeta)) {
            New-Item -ItemType Directory -Path $carpeta -Force | Out-Null
        }

        if (Test-Path -LiteralPath $ruta) {
            $copia = "$ruta.bak"
            Copy-Item -LiteralPath $ruta -Destination $copia -Force
            Write-Log "Copia: $copia" "INFO"
        }

        # Se reconstruye el objeto entero para no depender de que la propiedad ya
        # exista: si no estaba, Add-Member; si estaba, asignar. Componerlo de
        # nuevo hace lo mismo en los dos casos.
        $salida = [ordered]@{}
        foreach ($prop in $p.Ajustes.PSObject.Properties) {
            if ($prop.Name -ne $Clave) { $salida[$prop.Name] = $prop.Value }
        }
        if ($p.Runtimes.Count -gt 0) { $salida[$Clave] = $p.Runtimes }

        ([PSCustomObject]$salida | ConvertTo-Json -Depth 10) |
            Set-Content -LiteralPath $ruta -Encoding UTF8

        Write-Log "Escrito: $ruta" "SUCCESS"
    }
    catch {
        Write-Log "No se pudo escribir $ruta : $($_.Exception.Message)" "ERROR"
        $fallos++
    }
}

Write-Host ""
if ($fallos -gt 0) { exit 1 }

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  LISTO" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
if ($Remove) {
    Write-Host "Los JDK del kit ya no constan en VS Code." -ForegroundColor Green
}
else {
    Write-Host "VS Code ya conoce los JDK del kit." -ForegroundColor Green
    Write-Host ""
    Write-Host "Reinicia VS Code para que la extension lo lea." -ForegroundColor Yellow
    Write-Host "Para comprobarlo, en la paleta (Ctrl+Shift+P):" -ForegroundColor Gray
    Write-Host "  Java: Configure Java Runtime" -ForegroundColor White
    Write-Host ""
    Write-Host "Cada proyecto usara el JDK que pida su nivel de compilacion;" -ForegroundColor Gray
    Write-Host "el que no pida ninguno usara el $porDefecto." -ForegroundColor Gray
}
Write-Host ""
