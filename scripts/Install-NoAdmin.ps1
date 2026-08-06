#Requires -Version 5.1
<#
.SYNOPSIS
    Install-NoAdmin.ps1 - Instala software en el perfil de usuario sin permisos de administrador.
.DESCRIPTION
    NO desbloquea ni modifica el instalador ni el sistema. Detecta con que tecnologia
    esta hecho el instalador y lo invoca con el modo de instalacion "por usuario" que
    ese mismo instalador ya soporta de fabrica (per-user), que no requiere elevacion.

    Flujo:
      1. Detecta el tipo de instalador (MSI / Inno Setup / NSIS / desconocido).
      2. Intenta la instalacion per-user nativa (sin admin).
      3. Verifica, comparando el registro de usuario antes/despues, si realmente aterrizo.
      4. Si no hay modo per-user, ofrece extraer los archivos a una carpeta portable.
      5. Si el software necesita admin de verdad (drivers, servicios, per-machine forzado),
         lo dice con honestidad y para. No intenta elevar privilegios.
.PARAMETER Path
    Ruta al instalador (.msi o .exe).
.PARAMETER DestRoot
    Carpeta donde extraer si se usa el modo portable.
    Por defecto: la carpeta Apps\ hermana de la raiz del kit.
.PARAMETER ExtractOnly
    Omite el intento de instalacion y va directo a extraer los archivos a portable.
.EXAMPLE
    .\Install-NoAdmin.ps1 -Path "C:\Descargas\app.msi"
.EXAMPLE
    .\Install-NoAdmin.ps1 -Path "C:\Descargas\setup.exe" -ExtractOnly
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Path,

    [string]$DestRoot,

    [switch]$ExtractOnly
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

if ([string]::IsNullOrWhiteSpace($DestRoot)) {
    $DestRoot = Join-Path $WorkspaceRoot "Apps"
}

# --------------------------------------------------------------------------
# Deteccion de tipo de instalador
# --------------------------------------------------------------------------

function Test-FileContainsMarker {
    param(
        [string]$FilePath,
        [string[]]$Markers
    )

    # Escanea el archivo por bloques buscando marcadores de texto (ASCII), conservando
    # un pequeno "solape" entre bloques para no perder coincidencias que caigan justo
    # en el limite. Latin1 mapea cada byte a un caracter sin perdidas: ideal para esto.
    $maxLen = ($Markers | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    $overlap = [Math]::Max($maxLen - 1, 0)
    $blockSize = 1048576  # 1 MB
    $enc = [System.Text.Encoding]::GetEncoding('ISO-8859-1')

    $stream = [System.IO.File]::OpenRead($FilePath)
    try {
        $bytes = New-Object byte[] $blockSize
        $tail = ''
        while (($n = $stream.Read($bytes, 0, $blockSize)) -gt 0) {
            $text = $tail + $enc.GetString($bytes, 0, $n)
            foreach ($m in $Markers) {
                if ($text.IndexOf($m, [System.StringComparison]::Ordinal) -ge 0) {
                    return $true
                }
            }
            if ($text.Length -ge $overlap) {
                $tail = $text.Substring($text.Length - $overlap)
            }
            else {
                $tail = $text
            }
        }
    }
    finally {
        $stream.Dispose()
    }
    return $false
}

function Get-PeSectionNames {
    <#
        Lee la tabla de secciones de un ejecutable PE.

        Se usa para reconocer bundles WiX Burn, que anaden una seccion propia
        llamada ".wixburn". Buscar la cadena "Burn" en el binario no sirve:
        es una palabra corriente y aparece por casualidad en casi cualquier
        ejecutable grande.
    #>
    param([string]$FilePath)

    try {
        $fs = [System.IO.File]::OpenRead($FilePath)
        try {
            $br = New-Object System.IO.BinaryReader($fs)

            # La cabecera DOS guarda en 0x3C el desplazamiento de la firma PE.
            $fs.Position = 0x3C
            $peOffset = $br.ReadInt32()
            if ($peOffset -le 0 -or $peOffset -ge ($fs.Length - 24)) { return @() }

            $fs.Position = $peOffset
            if ($br.ReadUInt32() -ne 0x00004550) { return @() }   # "PE\0\0"

            # Cabecera COFF: numero de secciones en +6, tamano de la cabecera
            # opcional en +20. La tabla de secciones empieza tras ambas.
            $fs.Position = $peOffset + 6
            $sectionCount = $br.ReadUInt16()

            $fs.Position = $peOffset + 20
            $optionalHeaderSize = $br.ReadUInt16()

            $names = @()
            $fs.Position = $peOffset + 24 + $optionalHeaderSize
            for ($i = 0; $i -lt $sectionCount; $i++) {
                $raw = $br.ReadBytes(8)
                if ($raw.Length -lt 8) { break }
                $names += ([System.Text.Encoding]::ASCII.GetString($raw)).TrimEnd([char]0)
                $fs.Position += 32    # resto de la cabecera de seccion (40 en total)
            }

            return $names
        }
        finally {
            $fs.Dispose()
        }
    }
    catch {
        return @()
    }
}

function Get-InstallerType {
    param([string]$FilePath)

    $ext = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()

    if ($ext -eq '.msi') {
        return 'MSI'
    }

    if ($ext -eq '.exe') {
        # Burn primero: un bundle puede llevar dentro instaladores de cualquier
        # otra tecnologia, asi que sus marcadores podrian confundir la deteccion.
        if ((Get-PeSectionNames -FilePath $FilePath) -contains '.wixburn') {
            return 'Burn'
        }
        # El resto dejan una huella reconocible en el binario.
        if (Test-FileContainsMarker -FilePath $FilePath -Markers @('Inno Setup')) {
            return 'Inno'
        }
        if (Test-FileContainsMarker -FilePath $FilePath -Markers @('Nullsoft')) {
            return 'NSIS'
        }
        return 'ExeUnknown'
    }

    return 'Unknown'
}

# --------------------------------------------------------------------------
# Verificacion: fotografia del registro de usuario antes/despues
# --------------------------------------------------------------------------

function Get-UserInstalledApps {
    # Las instalaciones per-user se registran bajo HKCU (no HKLM), sin admin.
    $keys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    $apps = @{}
    foreach ($base in $keys) {
        if (Test-Path $base) {
            Get-ChildItem $base -ErrorAction SilentlyContinue | ForEach-Object {
                $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                if ($props -and $props.DisplayName) {
                    $apps[$_.PSChildName] = [PSCustomObject]@{
                        Name     = $props.DisplayName
                        Version  = $props.DisplayVersion
                        Location = $props.InstallLocation
                    }
                }
            }
        }
    }
    return $apps
}

function Show-NewApps {
    param(
        [hashtable]$Before,
        [hashtable]$After
    )

    $newKeys = $After.Keys | Where-Object { -not $Before.ContainsKey($_) }

    if (-not $newKeys) {
        # Señal debil, no un fallo: hay paquetes que se instalan per-user
        # correctamente y no dejan entrada en HKCU. Verificado con 7-Zip.
        Write-Log "  (sin entrada nueva en HKCU; no todos los paquetes la crean)"
        return $false
    }

    foreach ($k in $newKeys) {
        $app = $After[$k]
        Write-Log "Instalado (per-user): $($app.Name) $($app.Version)" "SUCCESS"
        if ($app.Location) {
            Write-Log "  Ubicacion: $($app.Location)"
        }
    }
    return $true
}

# --------------------------------------------------------------------------
# Instalacion per-user por tipo
# --------------------------------------------------------------------------

function Get-MsiExitMeaning {
    param([int]$Code)
    switch ($Code) {
        0     { return @{ Ok = $true;  Msg = "Instalacion correcta" } }
        3010  { return @{ Ok = $true;  Msg = "Correcta; requiere reinicio para completar" } }
        1602  { return @{ Ok = $false; Msg = "Cancelada por el usuario" } }
        1603  { return @{ Ok = $false; Msg = "Error fatal durante la instalacion" } }
        1618  { return @{ Ok = $false; Msg = "Hay otra instalacion en curso; intenta mas tarde" } }
        1625  { return @{ Ok = $false; Msg = "Bloqueada por politica del sistema" } }
        1638  { return @{ Ok = $false; Msg = "Ya hay una version instalada" } }
        1730  { return @{ Ok = $false; Msg = "Requiere permisos de administrador (per-machine)" } }
        1925  { return @{ Ok = $false; Msg = "El MSI solo permite instalar para TODOS los usuarios: necesita admin" } }
        1926  { return @{ Ok = $false; Msg = "No se pudieron aplicar permisos: necesita admin" } }
        default { return @{ Ok = $false; Msg = "Codigo de salida $Code" } }
    }
}

function Install-MsiPerUser {
    param([string]$InstallerPath)

    $logFile = Join-Path $env:TEMP ("msi-" + [System.IO.Path]::GetFileNameWithoutExtension($InstallerPath) + ".log")

    # MSIINSTALLPERUSER=1 + ALLUSERS=2  =>  "instala en mi perfil, no para toda la maquina".
    # /qb = interfaz basica sin preguntas de admin. /l*v = log detallado.
    $msiArgs = @(
        '/i', "`"$InstallerPath`"",
        'MSIINSTALLPERUSER=1',
        'ALLUSERS=2',
        '/qb',
        '/norestart',
        '/l*v', "`"$logFile`""
    )

    Write-Log "Modo per-user MSI..."
    Write-Log "  msiexec $($msiArgs -join ' ')"
    $proc = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
    $meaning = Get-MsiExitMeaning -Code $proc.ExitCode

    if (-not $meaning.Ok) {
        Write-Log $meaning.Msg "ERROR"
        Write-Log "  Log detallado: $logFile"
        return $false
    }

    Write-Log $meaning.Msg "SUCCESS"

    # Verificacion a partir del log de msiexec, no del registro.
    #
    # Antes solo se comparaba HKCU antes/despues, y eso daba FALSOS NEGATIVOS:
    # 7-Zip se instalo per-user correctamente y la comprobacion dijo que no
    # habia pasado nada, porque no todos los paquetes registran su entrada de
    # desinstalacion en HKCU. El log de Windows Installer si dice la verdad.
    if (Test-Path -LiteralPath $logFile) {
        $log = Get-Content -LiteralPath $logFile -Raw -ErrorAction SilentlyContinue

        if ($log -match 'MSI_LUA:.*?Per-User mode') {
            Write-Log "  Windows Installer confirma: modo per-user, sin elevacion" "SUCCESS"
        }
        elseif ($log -match 'MSI_LUA:.*?Per-Machine mode') {
            Write-Log "  OJO: se instalo en modo PER-MACHINE, no solo para ti." "WARN"
            Write-Log "  Ese paquete no admite el modo por usuario." "WARN"
        }

        if ($log -match 'Property\(S\): INSTALLDIR = (.+)') {
            $dir = $Matches[1].Trim()
            Write-Log "  Instalado en: $dir"
            if (Test-Path -LiteralPath $dir) {
                $n = @(Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue).Count
                Write-Log "  $n archivos en destino" "SUCCESS"
            }
        }
    }

    return $true
}

function Get-InnoExitMeaning {
    <#
        Codigos de salida documentados de Inno Setup. Traducirlos importa mucho:
        el 2 no significa que el instalador rechace /CURRENTUSER, sino que se
        cancelo antes de empezar. Y la causa mas frecuente de eso es que salio
        un aviso de administrador y se rechazo.
    #>
    param([int]$Code)
    switch ($Code) {
        0 { return @{ Ok = $true;  Msg = "Instalacion correcta" } }
        1 { return @{ Ok = $false; Msg = "El instalador no pudo inicializarse" } }
        2 { return @{ Ok = $false; Msg = "Cancelado antes de empezar (normalmente: se rechazo el aviso de administrador)" } }
        3 { return @{ Ok = $false; Msg = "Error fatal preparando la instalacion" } }
        4 { return @{ Ok = $false; Msg = "Error fatal durante la instalacion" } }
        5 { return @{ Ok = $false; Msg = "Cancelado durante la instalacion" } }
        6 { return @{ Ok = $false; Msg = "El proceso se termino a la fuerza" } }
        7 { return @{ Ok = $false; Msg = "El instalador decidio que no puede continuar" } }
        8 { return @{ Ok = $false; Msg = "Correcta, pero pide reiniciar el equipo" } }
        default { return @{ Ok = $false; Msg = "Codigo de salida $Code" } }
    }
}

function Install-InnoPerUser {
    param([string]$InstallerPath)

    # Inno Setup: /CURRENTUSER instala para el usuario actual, PERO solo si el
    # script del instalador lo permite (PrivilegesRequiredOverridesAllowed con
    # 'commandline'). Si no, el flag se ignora y pide admin igualmente.
    $innoArgs = @('/CURRENTUSER', '/SILENT', '/NORESTART', '/SP-')

    Write-Log "Modo per-user Inno Setup..."
    Write-Log "  $InstallerPath $($innoArgs -join ' ')"
    $proc = Start-Process $InstallerPath -ArgumentList $innoArgs -Wait -PassThru

    $meaning = Get-InnoExitMeaning -Code $proc.ExitCode

    if ($meaning.Ok) {
        Write-Log $meaning.Msg "SUCCESS"
        return $true
    }

    Write-Log "Inno Setup: $($meaning.Msg)  [codigo $($proc.ExitCode)]" "ERROR"

    if ($proc.ExitCode -eq 2) {
        Write-Log "  Este instalador ignora /CURRENTUSER y pide admin de todas formas." "WARN"
        Write-Log "  Aceptar ese aviso instalaria PARA TODA LA MAQUINA, no solo para ti." "WARN"
    }

    return $false
}

# --------------------------------------------------------------------------
# Fallback: extraer a carpeta portable (sin instalar, sin registro, sin admin)
# --------------------------------------------------------------------------

function Test-ExtractionSupported {
    <#
        Comprueba que sabemos extraer este tipo Y que estan las herramientas
        necesarias. Se llama ANTES de crear la carpeta destino: antes se creaba
        siempre, asi que cada intento fallido dejaba un directorio vacio en Apps\.
    #>
    param([string]$Type)

    switch ($Type) {
        'MSI'  { return $true }
        'Burn' { return $true }
        'NSIS' {
            if (Get-Command '7z.exe' -ErrorAction SilentlyContinue) { return $true }
            Write-Log "Falta 7-Zip (7z.exe) para extraer NSIS." "ERROR"
            Write-Log "  Instalalo sin admin con Scoop:  scoop install 7zip" "WARN"
            return $false
        }
        'Inno' {
            if (Get-Command 'innounp.exe' -ErrorAction SilentlyContinue) { return $true }
            Write-Log "Falta innounp.exe para extraer Inno Setup." "ERROR"
            Write-Log "  Descarga innounp (Inno Setup Unpacker) y ponlo en el PATH." "WARN"
            return $false
        }
        default {
            Write-Log "No hay metodo de extraccion conocido para este instalador." "ERROR"
            return $false
        }
    }
}

function Expand-Installer {
    param(
        [string]$InstallerPath,
        [string]$Type,
        [string]$DestDir
    )

    if (-not (Test-ExtractionSupported -Type $Type)) {
        return $false
    }

    # Se recuerda si la carpeta la creamos nosotros, para poder retirarla si la
    # extraccion falla y no deja nada dentro.
    $weCreatedIt = $false
    if (-not (Test-Path $DestDir)) {
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
        $weCreatedIt = $true
    }

    $ok = $false
    try {
        switch ($Type) {
            'MSI' {
                # Instalacion administrativa: descomprime los archivos sin instalar ni tocar
                # el registro, y NO requiere admin pese al nombre.
                $msiArgs = @('/a', "`"$InstallerPath`"", "TARGETDIR=`"$DestDir`"", '/qb')
                Write-Log "Extrayendo MSI a portable..."
                Write-Log "  msiexec $($msiArgs -join ' ')"
                $proc = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
                $ok = ($proc.ExitCode -eq 0)
            }
            'Burn' {
                # Los bundles Burn (WiX) admiten /layout: copia sus cargas a una
                # carpeta sin instalar nada y sin admin. /quiet evita interfaz.
                #
                # Se usa Start-Process -Wait y no el operador &: los bundles Burn
                # son aplicaciones GUI (subsystem 2), y a esas PowerShell las lanza
                # sin esperarlas, devolviendo un $LASTEXITCODE vacio.
                Write-Log "Extrayendo bundle WiX Burn con /layout..."
                $proc = Start-Process -FilePath $InstallerPath `
                                      -ArgumentList @('/layout', "`"$DestDir`"", '/quiet') `
                                      -Wait -PassThru -WindowStyle Hidden
                $ok = ($proc.ExitCode -eq 0)

                if (-not $ok) {
                    Write-Log "El bundle rechazo /layout (codigo $($proc.ExitCode))" "ERROR"
                }
                else {
                    # Un /layout solo externaliza las cargas que el bundle traiga
                    # SEPARADAS. Si van embebidas (lo habitual en los instaladores
                    # de un solo archivo), lo unico que aparece es una copia del
                    # propio bundle, que no sirve como version portable.
                    $soloElBundle = @(Get-ChildItem -LiteralPath $DestDir -Recurse -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -ne (Split-Path -Leaf $InstallerPath) })

                    if ($soloElBundle.Count -eq 0) {
                        Write-Log "El bundle lleva sus cargas embebidas." "WARN"
                        Write-Log "  /layout solo ha copiado el propio instalador: no hay nada portable." "WARN"
                        Write-Log "  Para sacar los MSI de dentro haria falta 'dark.exe' del WiX Toolset." "WARN"
                    }
                }
            }
            'NSIS' {
                $sevenZip = Get-Command '7z.exe' -ErrorAction SilentlyContinue
                Write-Log "Extrayendo NSIS con 7-Zip..."
                $run = Invoke-NativeCommand -FilePath $sevenZip.Source `
                                            -Arguments @('x', $InstallerPath, "-o$DestDir", '-y') -Quiet
                $ok = ($run.ExitCode -eq 0)
            }
            'Inno' {
                $innounp = Get-Command 'innounp.exe' -ErrorAction SilentlyContinue
                Write-Log "Extrayendo Inno Setup con innounp..."
                Push-Location $DestDir
                try {
                    $run = Invoke-NativeCommand -FilePath $innounp.Source `
                                                -Arguments @('-x', '-y', $InstallerPath) -Quiet
                    $ok = ($run.ExitCode -eq 0)
                }
                finally {
                    Pop-Location
                }
            }
        }
    }
    finally {
        if (-not $ok -and $weCreatedIt) {
            $left = @(Get-ChildItem -LiteralPath $DestDir -Force -ErrorAction SilentlyContinue)
            if ($left.Count -eq 0) {
                Remove-Item -LiteralPath $DestDir -Force -Recurse -ErrorAction SilentlyContinue
            }
        }
    }

    return $ok
}

# --------------------------------------------------------------------------
# Programa principal
# --------------------------------------------------------------------------

Write-Log "========================================" "INFO"
Write-Log "  Install-NoAdmin" "INFO"
Write-Log "  Instalacion sin permisos de admin" "INFO"
Write-Log "========================================" "INFO"
Write-Log ""

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Log "No existe el archivo: $Path" "ERROR"
    exit 1
}

$Path = (Resolve-Path -LiteralPath $Path).Path
$appName = [System.IO.Path]::GetFileNameWithoutExtension($Path)

Write-Log "Instalador: $Path"

$type = Get-InstallerType -FilePath $Path
Write-Log "Tipo detectado: $type"
Write-Log ""

# --- Extraccion directa si se pidio -ExtractOnly ---
if ($ExtractOnly) {
    $destDir = Join-Path $DestRoot $appName
    Write-Log "Modo -ExtractOnly: extrayendo a $destDir"
    $ok = Expand-Installer -InstallerPath $Path -Type $type -DestDir $destDir
    if ($ok) {
        Write-Log "Archivos extraidos en: $destDir" "SUCCESS"
        if ($type -eq 'Burn') {
            # Ya se ha avisado dentro de Expand-Installer si las cargas iban
            # embebidas; no se promete portabilidad que puede no existir.
            Write-Log "Revisa el contenido: un bundle Burn no siempre deja algo ejecutable." "INFO"
        }
        else {
            Write-Log "Es una version portable: ejecuta el binario directamente desde ahi." "INFO"
        }
        exit 0
    }
    else {
        Write-Log "No se pudo extraer el instalador." "ERROR"
        exit 1
    }
}

# --- Aviso sobre UAC antes de ejecutar nada ---
#
# Es el punto mas importante de toda la herramienta y faltaba: un instalador
# puede pedir elevacion aunque le pasemos el modo per-user, porque el flag solo
# funciona si su autor lo permitio. Si el usuario acepta ese aviso, la
# instalacion deja de ser por usuario y pasa a ser de toda la maquina, que es
# justo lo contrario de lo que viene a hacer este script.
if ($type -in @('MSI', 'Inno')) {
    Write-Host ""
    Write-Host "AVISO" -ForegroundColor Yellow
    Write-Host "  Ahora se va a ejecutar el instalador en modo por usuario." -ForegroundColor Yellow
    Write-Host "  Si aun asi aparece el aviso 'Quieres permitir que esta aplicacion" -ForegroundColor Yellow
    Write-Host "  realice cambios en tu dispositivo':" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    Responde NO." -ForegroundColor White
    Write-Host ""
    Write-Host "  Significa que ese instalador ignora el modo por usuario y quiere" -ForegroundColor Gray
    Write-Host "  instalarse para TODA la maquina. Aceptarlo puede modificar o" -ForegroundColor Gray
    Write-Host "  reemplazar una instalacion que ya tuvieras." -ForegroundColor Gray
    Write-Host ""
}

# --- Intento de instalacion per-user segun el tipo ---
$installed = $false

switch ($type) {
    'MSI' {
        $before = Get-UserInstalledApps
        $installed = Install-MsiPerUser -InstallerPath $Path
        if ($installed) {
            $after = Get-UserInstalledApps
            Show-NewApps -Before $before -After $after | Out-Null
        }
    }
    'Inno' {
        $before = Get-UserInstalledApps
        $installed = Install-InnoPerUser -InstallerPath $Path
        if ($installed) {
            $after = Get-UserInstalledApps
            Show-NewApps -Before $before -After $after | Out-Null
        }
    }
    'NSIS' {
        Write-Log "NSIS no tiene un modo per-user estandar y fiable." "WARN"
        Write-Log "La via limpia es extraerlo a portable (fallback)." "INFO"
    }
    'Burn' {
        # Un bundle Burn puede ser per-user o per-machine segun lo decidiera
        # quien lo compilo, y no hay ningun modificador estandar para forzarlo.
        Write-Log "Bundle WiX Burn: no hay un modo per-user estandar que forzar." "WARN"
        Write-Log "Se intentara extraer sus cargas (MSI) con /layout." "INFO"
    }
    default {
        Write-Log "Instalador de tipo desconocido: no hay modo per-user conocido." "WARN"
    }
}

# --- Fallback a extraccion portable si la instalacion no funciono ---
if (-not $installed) {
    Write-Log ""
    Write-Log "Intentando fallback: extraer a portable..." "INFO"
    $destDir = Join-Path $DestRoot $appName
    $extracted = Expand-Installer -InstallerPath $Path -Type $type -DestDir $destDir

    if ($extracted) {
        Write-Log "Archivos extraidos en: $destDir" "SUCCESS"
        if ($type -eq 'Burn') {
            # /layout deja los MSI sueltos, no una app lista para usar.
            Write-Log "Son las cargas del bundle, no una version portable." "WARN"
            Write-Log "Si alguno instala drivers o servicios, seguira necesitando admin." "WARN"
        }
        else {
            Write-Log "Version portable lista: ejecuta el binario desde esa carpeta." "INFO"
        }
        exit 0
    }
    else {
        Write-Log ""
        Write-Log "No se pudo instalar per-user ni extraer a portable." "ERROR"
        Write-Log "Este software probablemente necesita admin de verdad" "WARN"
        Write-Log "(drivers, servicios o MSI forzado a per-machine)." "WARN"
        Write-Log "Opciones honestas: pedir a IT que lo instale, o buscar una version portable oficial." "INFO"
        exit 1
    }
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  INSTALACION COMPLETADA (per-user)" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Se instalo en tu perfil de usuario, sin admin." -ForegroundColor Green
Write-Host "Busca la app en el menu Inicio o en %LOCALAPPDATA%." -ForegroundColor Gray
Write-Host ""
