#Requires -Version 5.1
<#
.SYNOPSIS
    Common.ps1 - Funciones compartidas por todas las herramientas del kit.
.DESCRIPTION
    Se carga con dot-sourcing desde los scripts de la carpeta scripts\:

        . (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

    Expone:
      $DevKitRoot            Carpeta raiz del kit (la que contiene lib\ y scripts\).
      $WorkspaceRoot         Carpeta madre, donde viven Angular\, Python\ y Apps\.

      Write-Log              Log con timestamp y color.
      Invoke-Download        Descarga con proxy corporativo, TLS 1.2, reintentos,
                             verificacion SHA-256 y diagnostico de errores.
      Get-FileSha256         SHA-256 de un archivo local.
      Get-Sha256FromShasums  Lee un SHASUMS256.txt remoto (formato de nodejs.org).
      Test-ZipIntegrity      Comprueba que un .zip no llego truncado.
      Add-UserPathEntry      Agrega rutas al PATH de usuario sin duplicar ni romper.
#>

# --------------------------------------------------------------------------
# Rutas base
# --------------------------------------------------------------------------

# lib\ vive dentro del kit, y el kit vive al lado de las carpetas que crea
# (Angular\, Python\, Apps\). Estas dos rutas son el unico punto donde se
# decide "donde se instala todo": los scripts no vuelven a calcularlo.
$DevKitRoot    = Split-Path -Parent $PSScriptRoot
$WorkspaceRoot = Split-Path -Parent $DevKitRoot

# Version del kit. No es lo mismo que $ManifestVersion de Export-Env: aquella
# describe el FORMATO del env.json y decide si un bundle se puede importar; esta
# identifica el kit que lo genero y sirve para diagnosticar ("que version tienes"
# en un informe) y para saber con que se creo un bundle.
#
# Subela al cambiar comportamiento visible; Doctor la muestra y Export-Env la
# anota en el manifiesto.
#
# 2.0.0 y no 1.x: se quedo en 1.0.0 durante mucho tiempo mientras el kit pasaba
# de 4 runtimes a 9, ganaba seis comandos y cambiaba el formato del bundle. Eso
# no es cosmetico: Export-Env estampa este numero en cada bundle e Import-Env
# avisa si no coincide con el suyo, asi que un bundle de hoy y uno de hace meses
# decian ser lo mismo y ese aviso no podia funcionar.
$KitVersion = "2.0.0"

# Windows PowerShell 5.1 negocia TLS 1.0 por defecto, y python.org y nodejs.org
# ya lo rechazan. Sin esto, las descargas fallan con un error de "conexion cerrada"
# que no dice nada.
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
catch {
    # .NET demasiado antiguo para TLS 1.2: seguimos con lo que haya disponible.
}

# --------------------------------------------------------------------------
# Los modulos
# --------------------------------------------------------------------------
#
# Esto era un solo archivo de 4783 lineas y 132 funciones. Se partio por
# responsabilidad, pero SIN convertirlo en un modulo de PowerShell (.psm1) a
# proposito: un modulo crea un ambito propio, y los scripts del kit cuentan
# con que $WorkspaceRoot, $CorpCaFile y las funciones lleguen a SU ambito por
# dot-source. Doctor-Env depende de eso de forma explicita -sus bloques de
# reparacion fallan si se ejecutan en un ambito de modulo- y ya nos costo un
# fallo en su dia.
#
# Asi que se sigue con dot-source, y quien usa la libreria no se entera: los
# 25 scripts siguen cargando Common.ps1 y nada mas.
#
# El ORDEN importa poco -PowerShell resuelve las llamadas cuando se ejecutan,
# no cuando se carga- salvo por las variables de modulo, que si tienen que
# existir antes de que alguien las lea al cargar. Las de arriba (rutas,
# version) ya estan definidas a estas alturas.

foreach ($modulo in @(
    'Log.ps1',        # registro en archivo y en consola
    'Proxy.ps1',      # proxy corporativo y espejo interno
    'Download.ps1',   # descargas, checksums, firmas
    'Semver.ps1',     # rangos de version de npm
    'Shells.ps1',     # los .bat que genera el kit
    'Tools.ps1',      # 7z, innoextract, Node
    'Runtimes.ps1',   # Git, Maven, Gradle, .NET, VS Code
    'CorpNet.ps1',    # la CA de la empresa y el proxy por herramienta
    'VSCode.ps1',     # ajustes y extensiones de VS Code
    'Catalog.ps1',    # catalogo, devenv.json y lockfile
    'UserPath.ps1'    # PATH de usuario
)) {
    $ruta = Join-Path $PSScriptRoot $modulo
    if (-not (Test-Path -LiteralPath $ruta)) {
        throw "Falta lib\$modulo. La instalacion del kit esta incompleta."
    }
    . $ruta
}
