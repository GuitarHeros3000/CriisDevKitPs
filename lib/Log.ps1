#Requires -Version 5.1
<#
    Registro en archivo y en consola

    Parte de lib\Common.ps1, que es quien carga este archivo. No se toma
    por separado: los scripts siguen haciendo un unico dot-source de
    Common.ps1 y no se enteran de esta division.
#>

# --------------------------------------------------------------------------
# Registro en archivo
# --------------------------------------------------------------------------
#
# Se usa Start-Transcript y no un append dentro de Write-Log por una razon
# concreta: Doctor imprime con Write-Host casi todo (39 llamadas frente a 3 de
# Write-Log), asi que enganchar solo Write-Log dejaria el registro vacio justo en
# el caso que mas importa, que es mandarle el diagnostico a IT. El transcript
# captura toda la salida de consola sin tocar ni una de las 300 llamadas del kit.

$KitLogDir = Join-Path $env:LOCALAPPDATA "AssassinSkipAdm\logs"

# Eran 20, y se quedaba corto de largo. Un solo rato de trabajo -instalar cuatro
# runtimes, comprobar con Doctor, desinstalar- se come esos 20 y borra todo lo
# anterior: al intentar auditar que comandos se habian ejecutado, el historial
# solo cubria los ultimos 25 minutos y no servia para nada.
#
# 200 archivos son unos pocos MB y cubren semanas de uso normal. El limite sigue
# siendo por CANTIDAD y no por antiguedad, para que la carpeta no pueda crecer
# sin tope aunque el kit se use en bucle desde un script.
$script:KitLogsToKeep = 200

function Remove-OldKitLogs {
    try {
        $viejos = @(Get-ChildItem -LiteralPath $KitLogDir -Filter '*.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip $script:KitLogsToKeep)
        foreach ($f in $viejos) {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        # La rotacion nunca debe impedir que el registro se haya abierto.
    }
}

function Start-KitLog {
    <#
    .SYNOPSIS
        Abre el registro en archivo de esta ejecucion. Devuelve la ruta, o $null.
    .DESCRIPTION
        Un archivo por ejecucion, en %LOCALAPPDATA%\AssassinSkipAdm\logs, para
        poder decir "mandame el ultimo" sin mas explicaciones.

        Se llama solo al cargar Common.ps1. Reglas que cumple:

          - NUNCA rompe nada. Disco lleno, permisos, un transcript que el usuario
            ya tenia abierto: todo se traga y la herramienta sigue.
          - Silencioso: el "Transcript started" iria a parar a la salida que leen
            otros procesos.
          - Uno por proceso. Common.ps1 se carga por dot-sourcing desde varios
            sitios y Start-Transcript da error si ya hay uno abierto.
          - Se puede desactivar con ASSASSINSKIPADM_NOLOG.

        La clave del proxy no acaba aqui: todo lo que la imprime pasa antes por
        Format-ProxyForDisplay, asi que al registro llega ya enmascarada.
    #>
    param([string]$Name)

    if ($env:ASSASSINSKIPADM_NOLOG) { return $null }
    if ($env:ASSASSINSKIPADM_LOGFILE) { return $env:ASSASSINSKIPADM_LOGFILE }

    try {
        if ([string]::IsNullOrWhiteSpace($Name)) {
            # El frame mas externo de la pila con nombre de script es el que
            # lanzo el usuario; los de dentro son este archivo y sus funciones.
            $conNombre = @(Get-PSCallStack | Where-Object { $_.ScriptName })
            $Name = if ($conNombre.Count) {
                [IO.Path]::GetFileNameWithoutExtension($conNombre[-1].ScriptName)
            } else { 'kit' }
        }

        if (-not (Test-Path -LiteralPath $KitLogDir)) {
            New-Item -ItemType Directory -Path $KitLogDir -Force | Out-Null
        }

        $file = Join-Path $KitLogDir ("{0}-{1}.log" -f $Name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Start-Transcript -LiteralPath $file -Force | Out-Null
        $env:ASSASSINSKIPADM_LOGFILE = $file

        Remove-OldKitLogs
        return $file
    }
    catch {
        return $null
    }
}

# --------------------------------------------------------------------------
# Log
# --------------------------------------------------------------------------

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "HH:mm:ss"
    $color = switch ($Level) {
        "SUCCESS" { "Green" }
        "ERROR" { "Red" }
        "WARN" { "Yellow" }
        default { "White" }
    }
    # Red de seguridad, no sustituto de enmascarar en origen: la fuga que motivo
    # esto llego dentro de un mensaje de excepcion, o sea desde un sitio donde
    # nadie se habria acordado de llamar a Format-ProxyForDisplay. Sobre un texto
    # ya enmascarado no hace nada.
    Write-Host "[$timestamp] [$Level] $(Protect-ProxySecrets -Text $Message)" -ForegroundColor $color
}
