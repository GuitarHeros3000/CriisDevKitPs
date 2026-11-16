#Requires -Version 5.1
<#
    Actualizar el propio kit desde sus releases de GitHub

    NO lo carga Common.ps1: solo Update-Kit y sus pruebas.

    Antes, para tener la version nueva en el equipo del trabajo habia que
    llevarla a mano. Las releases las crea el flujo de .github\workflows\
    publicar.yml al subir una etiqueta vX.Y.Z: pasa la suite, empaqueta el kit
    y publica el zip con su SHA-256 al lado.
#>

# El repositorio de donde sale el kit. CRIISDEVKIT_REPO lo cambia para una
# copia propia (un fork, o el espejo interno de la empresa).
$KitRepo = if ($env:CRIISDEVKIT_REPO) { $env:CRIISDEVKIT_REPO.Trim().TrimEnd('/') } else { 'GuitarHeros3000/CriisDevKitPs' }

# Las carpetas que son ENTERAS del kit: tras actualizar quedan exactamente como
# en la version nueva. En la raiz, en cambio, solo se sobrescribe lo que trae la
# version nueva: alli estan tambien sources.json y los bundles de Export-Env.
$KitFolders = @('bin', 'scripts', 'lib', 'tests', 'docs', '.github')

$KitBackupDir = Join-Path $env:LOCALAPPDATA "CriisDevKit\kit-anterior"

function Get-KitLatestRelease {
    <#
        La ultima release publicada, sin gastar una consulta de la API:
        github.com redirige releases/latest a releases/tag/vX.Y.Z. Sin
        ninguna publicada, redirige a la lista, y entonces devuelve $null.
        Devuelve Tag y Version.
    #>
    $uri = Resolve-KitUrl -Uri "https://github.com/$KitRepo/releases/latest" -Quiet
    $params = @{ Uri = $uri; Method = 'Head'; UseBasicParsing = $true; TimeoutSec = 30 }
    Add-ProxyToRequest -Params $params -Uri ([Uri]$uri)
    try {
        $r = Invoke-WebRequest @params
        $final = [string]$r.BaseResponse.ResponseUri
    }
    catch { return $null }

    if ($final -match '/releases/tag/(v?(\d+\.\d+\.\d+))/?$') {
        return [PSCustomObject]@{ Tag = $Matches[1]; Version = $Matches[2] }
    }
    return $null
}

function Get-KitReleaseFiles {
    <# Las URL del zip de una version y de su SHA-256, como las publica el flujo. #>
    param([Parameter(Mandatory=$true)][string]$Tag)
    $v = $Tag.TrimStart('v')
    $base = "https://github.com/$KitRepo/releases/download/$Tag"
    return [PSCustomObject]@{
        Zip      = "$base/CriisDevKitPs-$v.zip"
        Sha256   = "$base/CriisDevKitPs-$v.zip.sha256"
        FileName = "CriisDevKitPs-$v.zip"
    }
}

function Get-KitVersionFromFolder {
    <# El $KitVersion que declara el Common.ps1 de una copia del kit. #>
    param([Parameter(Mandatory=$true)][string]$Raiz)
    $common = Join-Path $Raiz 'lib\Common.ps1'
    if (-not (Test-Path -LiteralPath $common)) { return $null }
    $m = Select-String -LiteralPath $common -Pattern '^\s*\$KitVersion\s*=\s*"([^"]+)"' | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value }
    return $null
}

function Test-KitFolderLooksComplete {
    <#
        Si una carpeta tiene pinta de ser el kit entero, y no un zip a medias o
        cualquier otra cosa: sin esto, "actualizar" con un zip equivocado
        dejaria el kit sin sus comandos.
    #>
    param([Parameter(Mandatory=$true)][string]$Raiz)
    foreach ($f in @('lib\Common.ps1', 'Menu.bat', 'scripts\kit\Update-Kit.ps1', 'bin\kit\Update-Kit.bat')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Raiz $f))) { return $false }
    }
    return $true
}

function Update-KitFiles {
    <#
    .SYNOPSIS
        Pone en -Destino el kit de -Nuevo. Devuelve lo que hizo.
    .DESCRIPTION
        - Las carpetas del kit (bin, scripts, lib...) quedan EXACTAMENTE como en
          -Nuevo: lo que ya no trae, se borra. Un script que cambio de carpeta
          dejaba si no una copia vieja que Resolve-KitScript podia encontrar
          antes que la buena.
        - En la raiz solo se escribe lo que trae -Nuevo, y no se borra nada:
          ahi viven tambien sources.json y los bundles de Export-Env.
        - Los .bat que cambian NO se escriben aqui: se devuelven en
          BatsPendientes. cmd lee un .bat a trozos mientras lo ejecuta, y
          sobrescribir el que esta corriendo (Update-Kit.bat, o Menu.bat si se
          llego desde el menu) le hace ejecutar lineas que no son. Quien llama
          los pone cuando el .bat ya haya terminado.
        - Antes de tocar nada, copia lo que va a cambiar en -Respaldo.

        Devuelve Escritos, Borrados y BatsPendientes (pares Origen/Destino).
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Nuevo,
        [Parameter(Mandatory=$true)][string]$Destino,
        [Parameter(Mandatory=$true)][string]$Respaldo,
        # Se anota en el respaldo ANTES de tocar nada: si algo falla a mitad,
        # -Revertir tiene que poder deshacer lo que si se hizo.
        [string]$VersionAnterior = $KitVersion
    )

    $nuevo = (Resolve-Path -LiteralPath $Nuevo).ProviderPath.TrimEnd('\')
    $destino = (Resolve-Path -LiteralPath $Destino).ProviderPath.TrimEnd('\')

    $archivosNuevos = @(Get-ChildItem -LiteralPath $nuevo -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($nuevo.Length + 1) })
    $setNuevos = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($a in $archivosNuevos) { [void]$setNuevos.Add($a) }

    # Lo que sobra: archivos de las carpetas del kit que la version nueva no trae.
    $sobran = @()
    foreach ($c in $KitFolders) {
        $d = Join-Path $destino $c
        if (-not (Test-Path -LiteralPath $d)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $d -Recurse -File -Force)) {
            $rel = $f.FullName.Substring($destino.Length + 1)
            if (-not $setNuevos.Contains($rel)) { $sobran += $rel }
        }
    }

    # Lo que cambia: lo que es distinto o no estaba.
    $cambian = @()
    foreach ($rel in $archivosNuevos) {
        $actual = Join-Path $destino $rel
        if (-not (Test-Path -LiteralPath $actual)) { $cambian += $rel; continue }
        if ((Get-FileSha256 -FilePath $actual) -ne (Get-FileSha256 -FilePath (Join-Path $nuevo $rel))) { $cambian += $rel }
    }

    # Respaldo de lo que se va a tocar: lo que cambia y lo que se borra.
    if (Test-Path -LiteralPath $Respaldo) { Remove-Item -LiteralPath $Respaldo -Recurse -Force }
    New-Item -ItemType Directory -Path $Respaldo -Force | Out-Null
    foreach ($rel in @($cambian) + @($sobran)) {
        $actual = Join-Path $destino $rel
        if (-not (Test-Path -LiteralPath $actual)) { continue }
        $copia = Join-Path $Respaldo $rel
        New-Item -ItemType Directory -Path (Split-Path -Parent $copia) -Force | Out-Null
        Copy-Item -LiteralPath $actual -Destination $copia -Force
    }
    # Lo que es NUEVO en esta version se apunta, para que revertir lo quite.
    $nuevosDeVerdad = @($cambian | Where-Object { -not (Test-Path -LiteralPath (Join-Path $destino $_)) })
    Set-Content -LiteralPath (Join-Path $Respaldo '.criisdevkit-anadidos.txt') -Value $nuevosDeVerdad -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $Respaldo '.criisdevkit-version') -Value $VersionAnterior -Encoding ASCII

    $pendientes = @()
    $escritos = 0
    foreach ($rel in $cambian) {
        $origen = Join-Path $nuevo $rel
        $dest = Join-Path $destino $rel
        if ($rel -like '*.bat' -and (Test-Path -LiteralPath $dest)) {
            $pendientes += [PSCustomObject]@{ Origen = $origen; Destino = $dest }
            continue
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
        Copy-Item -LiteralPath $origen -Destination $dest -Force
        $escritos++
    }

    foreach ($rel in $sobran) {
        Remove-Item -LiteralPath (Join-Path $destino $rel) -Force -ErrorAction SilentlyContinue
    }
    # Las carpetas que queden vacias tambien sobran.
    foreach ($c in $KitFolders) {
        $d = Join-Path $destino $c
        if (-not (Test-Path -LiteralPath $d)) { continue }
        Get-ChildItem -LiteralPath $d -Recurse -Directory -Force | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
            if (@(Get-ChildItem -LiteralPath $_.FullName -Force).Count -eq 0) { Remove-Item -LiteralPath $_.FullName -Force }
        }
    }

    return [PSCustomObject]@{ Escritos = $escritos; Borrados = @($sobran).Count; BatsPendientes = $pendientes }
}

function Restore-KitBackup {
    <#
        Deshace la ultima actualizacion con lo que guardo Update-KitFiles:
        vuelve a poner lo que cambio o se borro, y quita lo que la version
        nueva anadio. Devuelve lo mismo que Update-KitFiles.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Respaldo,
        [Parameter(Mandatory=$true)][string]$Destino
    )

    $respaldo = (Resolve-Path -LiteralPath $Respaldo).ProviderPath.TrimEnd('\')
    $destino = (Resolve-Path -LiteralPath $Destino).ProviderPath.TrimEnd('\')
    $marcas = @('.criisdevkit-anadidos.txt', '.criisdevkit-version')

    $pendientes = @(); $escritos = 0; $borrados = 0
    foreach ($f in (Get-ChildItem -LiteralPath $respaldo -Recurse -File -Force)) {
        $rel = $f.FullName.Substring($respaldo.Length + 1)
        if ($marcas -contains $rel) { continue }
        $dest = Join-Path $destino $rel
        if ($rel -like '*.bat' -and (Test-Path -LiteralPath $dest)) {
            $pendientes += [PSCustomObject]@{ Origen = $f.FullName; Destino = $dest }
            continue
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
        Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
        $escritos++
    }

    $lista = Join-Path $respaldo '.criisdevkit-anadidos.txt'
    if (Test-Path -LiteralPath $lista) {
        foreach ($rel in (Get-Content -LiteralPath $lista | Where-Object { $_.Trim() })) {
            # Solo dentro del kit, por si alguien toca la lista a mano.
            if ($rel -match '(^|\\)\.\.(\\|$)' -or [IO.Path]::IsPathRooted($rel)) { continue }
            $f = Join-Path $destino $rel
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force; $borrados++ }
        }
    }
    return [PSCustomObject]@{ Escritos = $escritos; Borrados = $borrados; BatsPendientes = $pendientes }
}

function Start-DeferredCopy {
    <#
        Copia unos archivos unos segundos DESPUES de que termine este proceso,
        desde un cmd aparte y oculto. Es para los .bat que cambian: el que
        esta en marcha no se puede sobrescribir mientras cmd lo lee.
    #>
    param(
        [Parameter(Mandatory=$true)][object[]]$Pares,
        [int]$Segundos = 3
    )
    if ($Pares.Count -eq 0) { return }

    # Los nuevos se dejan en una carpeta temporal propia: la del zip se borra
    # al terminar este proceso.
    $espera = Join-Path ([IO.Path]::GetTempPath()) ("criisdevkit-bats-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $espera -Force | Out-Null
    $lineas = @('@echo off', "ping -n $($Segundos + 1) 127.0.0.1 >nul")
    $i = 0
    foreach ($p in $Pares) {
        $tmp = Join-Path $espera "$i.bat"
        Copy-Item -LiteralPath $p.Origen -Destination $tmp -Force
        $lineas += "copy /y `"$tmp`" `"$($p.Destino)`" >nul"
        $i++
    }
    $lineas += "rd /s /q `"$espera`""
    $script = Join-Path ([IO.Path]::GetTempPath()) ("criisdevkit-bats-" + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.cmd')
    Set-Content -LiteralPath $script -Value $lineas -Encoding ASCII
    # El script se borra a si mismo al final (del de una linea, que cmd ya leyo).
    Add-Content -LiteralPath $script -Value "(goto) 2>nul & del `"%~f0`"" -Encoding ASCII
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList @('/c', "`"$script`"") -WindowStyle Hidden
}
