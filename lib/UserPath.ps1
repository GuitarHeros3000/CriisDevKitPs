#Requires -Version 5.1
<#
    PATH de usuario

    Parte de lib\Common.ps1, que es quien carga este archivo. No se toma
    por separado: los scripts siguen haciendo un unico dot-source de
    Common.ps1 y no se enteran de esta division.
#>

# --------------------------------------------------------------------------
# PATH de usuario
# --------------------------------------------------------------------------

function Get-RawUserPath {
    <#
        Lee el PATH de usuario SIN expandir variables.

        [Environment]::GetEnvironmentVariable("Path","User") expande %USERPROFILE%
        y similares al leer; si luego se vuelve a escribir el resultado, esas
        variables quedan congeladas como rutas absolutas y el PATH del usuario
        se degrada en cada ejecucion. Por eso se lee del registro en crudo.
    #>
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
    if (-not $key) { return '' }
    try {
        $value = $key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($null -eq $value) { return '' }
        return [string]$value
    }
    finally {
        $key.Dispose()
    }
}

function Set-RawUserPath {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Value)

    # Si el PATH contiene %VAR%, tiene que guardarse como REG_EXPAND_SZ o Windows
    # dejaria de resolverlas.
    $kind = if ($Value -like '*%*') {
        [Microsoft.Win32.RegistryValueKind]::ExpandString
    } else {
        [Microsoft.Win32.RegistryValueKind]::String
    }

    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    if (-not $key) { throw "No se pudo abrir HKCU:\Environment para escritura." }
    try {
        $key.SetValue('Path', $Value, $kind)
    }
    finally {
        $key.Dispose()
    }
}

$script:PathBackupsToKeep = 10

function Backup-UserPath {
    <#
        Copia de seguridad del PATH antes de tocarlo. Barato, y convierte un
        posible desastre en un copy/paste. Se guarda fuera del kit.

        Rotacion: se conservan las ultimas $PathBackupsToKeep y, SIEMPRE, la
        primera de todas. Esa primera es el PATH de antes de que el kit tocara
        nada, o sea la que de verdad importa en un desastre; un tope ingenuo del
        tipo "conserva las N ultimas" seria justo la que borraria.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Value)

    try {
        $dir = Join-Path $env:LOCALAPPDATA "AssassinSkipAdm\path-backups"
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"

        # Si no hay ninguna marcada como original, esta lo es. El prefijo
        # distinto la deja fuera de la rotacion para siempre.
        $original = @(Get-ChildItem -LiteralPath $dir -Filter 'path-ORIGINAL-*.txt' -ErrorAction SilentlyContinue)
        $name = if ($original.Count -eq 0) { "path-ORIGINAL-$stamp.txt" } else { "path-$stamp.txt" }

        $file = Join-Path $dir $name
        Set-Content -LiteralPath $file -Value $Value -Encoding UTF8

        Remove-OldPathBackups -Directory $dir

        return $file
    }
    catch {
        return $null
    }
}

function Remove-OldPathBackups {
    param([Parameter(Mandatory=$true)][string]$Directory)

    try {
        $rotables = @(Get-ChildItem -LiteralPath $Directory -Filter 'path-*.txt' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike 'path-ORIGINAL-*' } |
            Sort-Object LastWriteTime -Descending)

        if ($rotables.Count -le $script:PathBackupsToKeep) { return }

        foreach ($old in ($rotables | Select-Object -Skip $script:PathBackupsToKeep)) {
            Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        # La rotacion nunca debe impedir que la copia se haya guardado.
    }
}

function Publish-EnvironmentChange {
    <#
        Avisa a Windows de que las variables de entorno cambiaron, para que las
        ventanas nuevas lo vean sin cerrar sesion. Escribir en el registro por si
        solo no lo notifica (SetEnvironmentVariable si lo hace, pero no podemos
        usarlo aqui por el problema de expansion de Get-RawUserPath).
    #>
    if (-not ('NativeEnvBroadcast' -as [type])) {
        Add-Type -Namespace '' -Name 'NativeEnvBroadcast' -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(
    System.IntPtr hWnd, uint Msg, System.IntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);
'@ -ErrorAction SilentlyContinue
    }

    try {
        $HWND_BROADCAST   = [IntPtr]0xffff
        $WM_SETTINGCHANGE = 0x1A
        $SMTO_ABORTIFHUNG = 0x0002
        $result = [UIntPtr]::Zero
        [NativeEnvBroadcast]::SendMessageTimeout(
            $HWND_BROADCAST, $WM_SETTINGCHANGE, [IntPtr]::Zero, "Environment",
            $SMTO_ABORTIFHUNG, 5000, [ref]$result) | Out-Null
    }
    catch {
        # No es critico: los shells generados fijan su propio PATH igualmente.
    }
}

function Split-UserPath {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Value)
    return @($Value -split ';' | Where-Object { $_.Trim() -ne '' })
}

function Save-UserPath {
    <#
        Escribe el PATH de usuario dejando antes una copia, y avisa a Windows.
        Devuelve la ruta del respaldo.
    #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Previous,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Updated
    )

    $backup = Backup-UserPath -Value $Previous
    Set-RawUserPath -Value $Updated
    Publish-EnvironmentChange
    return $backup
}

function Add-UserPathEntry {
    <#
    .SYNOPSIS
        Agrega una o varias rutas al PATH de usuario, sin duplicar.
    .DESCRIPTION
        Compara entrada por entrada con igualdad exacta. Una version anterior
        usaba -like "*$ruta*", que interpreta la ruta como patron comodin: con
        corchetes en el nombre de carpeta la deteccion fallaba y se anadia una
        entrada duplicada en cada ejecucion.

        Por defecto las rutas van AL PRINCIPIO. Windows resuelve el PATH de
        izquierda a derecha, asi que anadirlas al final hacia que, con varias
        versiones instaladas, respondiera siempre la primera que se instalo y no
        la que el usuario acababa de instalar. Con -Append se conserva el orden
        antiguo para casos en que no se quiera cambiar lo que ya responde.
    #>
    param(
        [Parameter(Mandatory=$true)][string[]]$Path,
        [switch]$Append
    )

    $current = Get-RawUserPath
    $entries = Split-UserPath -Value $current
    $wanted  = @($Path | ForEach-Object { $_.TrimEnd('\') })

    if ($Append) {
        $updated = @($entries)
        foreach ($w in $wanted) {
            $exists = $updated | Where-Object { $_.TrimEnd('\') -ieq $w }
            if (-not $exists) { $updated += $w }
        }
    }
    else {
        # Se retiran las apariciones previas y se reinsertan delante: si solo se
        # anadiera, una ruta ya presente al final seguiria perdiendo la prioridad.
        $rest = @($entries | Where-Object {
            $e = $_.TrimEnd('\')
            -not ($wanted | Where-Object { $_ -ieq $e })
        })
        $updated = @($wanted) + $rest
    }

    if (($updated -join ';') -ceq ($entries -join ';')) {
        Write-Log "PATH de usuario ya estaba correcto" "SUCCESS"
        return
    }

    $backup = Save-UserPath -Previous $current -Updated ($updated -join ';')

    # Tambien en la sesion actual, para que el resto del script pueda usarlo ya.
    $env:Path = ($wanted -join ';') + ';' + $env:Path

    foreach ($w in $wanted) {
        Write-Log "PATH: $w" "SUCCESS"
    }
    if (-not $Append) {
        Write-Log "  Colocadas al principio: son las que responden ahora."
    }
    if ($backup) {
        Write-Log "  Copia del PATH anterior: $backup"
    }
}

function Get-RawMachinePath {
    <#
        Lee el PATH de maquina sin expandir. Solo lectura: el kit nunca escribe
        aqui (haria falta admin, y ese es justo el punto del proyecto).
    #>
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
        'SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $false)
    if (-not $key) { return '' }
    try {
        $value = $key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($null -eq $value) { return '' }
        return [string]$value
    }
    finally {
        $key.Dispose()
    }
}

function Get-ActivationPaths {
    <#
        Rutas que antepone Use-Env al abrir cada terminal, leidas del activate.cmd
        que genera. Van por delante de todo, incluido el PATH de maquina, porque
        se aplican DESPUES de que Windows componga el PATH del proceso.
        Vacio si no hay activacion.
    #>
    $activateCmd = Join-Path $env:LOCALAPPDATA "AssassinSkipAdm\activate.cmd"
    if (-not (Test-Path -LiteralPath $activateCmd)) { return @() }

    foreach ($line in (Get-Content -LiteralPath $activateCmd -ErrorAction SilentlyContinue)) {
        if ($line -match '^\s*set\s+"PATH=(.+?);?%PATH%"\s*$') {
            return @($Matches[1] -split ';' | Where-Object { $_.Trim() -ne '' })
        }
    }
    return @()
}

function Get-EffectivePathEntries {
    <#
    .SYNOPSIS
        Devuelve las entradas del PATH en el orden real en que Windows las busca.
    .DESCRIPTION
        Windows compone el PATH de un proceso nuevo como MAQUINA + USUARIO, en
        ese orden. Es decisivo: una entrada de usuario NUNCA puede ganar a una de
        maquina, por mucho que se coloque la primera dentro del bloque de usuario.

        Si Use-Env esta activado, sus rutas van DELANTE de ambos bloques: el
        enganche de arranque de terminal corre despues de esa composicion.

        Cada elemento trae la ruta cruda, la expandida y de que ambito viene.
    #>
    $result = @()

    foreach ($block in @(
        @{ Scope = 'activado'; Value = ((Get-ActivationPaths) -join ';') },
        @{ Scope = 'maquina';  Value = (Get-RawMachinePath) },
        @{ Scope = 'usuario';  Value = (Get-RawUserPath) }
    )) {
        foreach ($entry in (Split-UserPath -Value $block.Value)) {
            $result += [PSCustomObject]@{
                Raw   = $entry
                Path  = [Environment]::ExpandEnvironmentVariables($entry).TrimEnd('\')
                Scope = $block.Scope
            }
        }
    }

    return $result
}

function Find-CommandInPath {
    <#
        Busca un ejecutable recorriendo el PATH en su orden real y devuelve todas
        las carpetas que lo contienen. La primera es la que responde.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$FileName,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Entries
    )

    $hits = @()
    foreach ($e in $Entries) {
        if ([string]::IsNullOrWhiteSpace($e.Path)) { continue }

        # Se concatena a mano en vez de usar Join-Path: Join-Path pasa por el
        # proveedor de PSDrive y lanza un error NO TERMINANTE si la unidad no
        # existe (una unidad de red desconectada en el PATH, por ejemplo). Al no
        # ser terminante, try/catch no lo captura y ensucia toda la salida.
        $candidate = $e.Path.TrimEnd('\') + '\' + $FileName

        try {
            if (Test-Path -LiteralPath $candidate -ErrorAction SilentlyContinue) { $hits += $e }
        }
        catch {
            # Rutas con caracteres invalidos: se ignoran.
        }
    }
    return $hits
}

function Show-PathConflicts {
    <#
        Avisa si en el PATH ya hay otras versiones del mismo runtime instaladas
        por el kit. Con varias, solo responde una: conviene decir cual y por que.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$Keep,
        [Parameter(Mandatory=$true)][string]$Label
    )

    $rootExpanded = [Environment]::ExpandEnvironmentVariables($Root).TrimEnd('\')
    $keepExpanded = [Environment]::ExpandEnvironmentVariables($Keep).TrimEnd('\')

    $others = @(Split-UserPath -Value (Get-RawUserPath) | Where-Object {
        $e = [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\')
        $e.StartsWith($rootExpanded + '\', [StringComparison]::OrdinalIgnoreCase) -and
        -not $e.StartsWith($keepExpanded, [StringComparison]::OrdinalIgnoreCase)
    })

    if ($others.Count -eq 0) { return }

    Write-Log "Ya habia otras versiones de $Label en el PATH:" "WARN"
    foreach ($o in $others) { Write-Log "  $o" "WARN" }
    Write-Log "  La que se acaba de instalar queda primera y es la que responde." "WARN"
    Write-Log "  Para retirar las demas:  .\Uninstall-Env.bat -Runtime $Label -Version <version>" "WARN"
}

function Remove-UserPathEntry {
    <#
    .SYNOPSIS
        Quita rutas del PATH de usuario. Devuelve cuantas quito.
    .PARAMETER Path
        Rutas exactas a eliminar.
    .PARAMETER UnderFolder
        Elimina cualquier entrada que cuelgue de esta carpeta. Es lo que usa el
        desinstalador: no depende de acertar la ruta exacta que se anadio.
    #>
    param(
        [string[]]$Path,
        [string]$UnderFolder
    )

    $current = Get-RawUserPath
    $entries = Split-UserPath -Value $current

    $targets = @($Path | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') })

    $folder = $null
    if (-not [string]::IsNullOrWhiteSpace($UnderFolder)) {
        $folder = [Environment]::ExpandEnvironmentVariables($UnderFolder).TrimEnd('\')
    }

    $removed = @()
    $kept    = @()

    foreach ($e in $entries) {
        # Las entradas pueden llevar %VAR%: se expanden solo para comparar,
        # nunca para guardar.
        $expanded = [Environment]::ExpandEnvironmentVariables($e).TrimEnd('\')

        $hit = [bool]($targets | Where-Object { $_ -ieq $expanded -or $_ -ieq $e.TrimEnd('\') })

        if (-not $hit -and $folder) {
            $hit = ($expanded -ieq $folder) -or ($expanded.StartsWith($folder + '\', [StringComparison]::OrdinalIgnoreCase))
        }

        if ($hit) { $removed += $e } else { $kept += $e }
    }

    if ($removed.Count -eq 0) {
        return 0
    }

    $backup = Save-UserPath -Previous $current -Updated ($kept -join ';')

    foreach ($r in $removed) {
        Write-Log "PATH -= $r" "SUCCESS"
    }
    if ($backup) {
        Write-Log "  Copia del PATH anterior: $backup"
    }

    return $removed.Count
}

# El registro se abre al cargar la libreria, para que capture desde la primera
# linea del script que la cargo. Silencioso y nunca fatal (ver Start-KitLog).
Start-KitLog | Out-Null
