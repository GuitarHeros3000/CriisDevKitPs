#Requires -Version 5.1
<#
.SYNOPSIS
    Doctor-App.ps1 - Por que no arranca un programa: que DLL le faltan y de donde sacarlas.
.DESCRIPTION
    Windows, cuando a un programa le falta una DLL, nombra solo la PRIMERA que
    no encuentra. Se copia esa, y sale la siguiente; y si la copiada era de la
    arquitectura equivocada, sale un 0xc000007b que ya no nombra nada.

    Esto lee el .exe sin ejecutarlo, sigue la cadena de lo que pide (y lo que
    piden sus DLL) buscando cada una donde la buscaria Windows, y dice de una
    vez todo lo que falta, lo que esta pero no le sirve, y de donde sale cada
    cosa. Solo lee: no copia ni cambia nada.
.PARAMETER Path
    El .exe, o una carpeta: entonces, cada .exe que haya en ella.
.PARAMETER Todo
    Ensena tambien lo que esta bien, no solo lo que falla.
.EXAMPLE
    .\Doctor-App.ps1 -Path "C:\SYS\BR\UTILERIAPUENTEBR.EXE"
.EXAMPLE
    .\Doctor-App.ps1 -Path "C:\SYS\BR"
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Path,

    [switch]$Todo
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Common.ps1")

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Doctor-App - Por que no arranca?" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

# "Copiar como ruta" del Explorador la pone entre comillas.
$Path = $Path.Trim().Trim('"')
if (-not (Test-Path -LiteralPath $Path)) {
    Write-Log "No existe: $Path" "ERROR"
    exit 1
}
$Path = (Resolve-Path -LiteralPath $Path).ProviderPath

$exes = if (Test-Path -LiteralPath $Path -PathType Container) {
    @(Get-ChildItem -LiteralPath $Path -Filter *.exe -File | ForEach-Object { $_.FullName })
} else { @($Path) }

if ($exes.Count -eq 0) {
    Write-Log "No hay ningun .exe en $Path" "WARN"
    exit 1
}

$conProblemas = 0
foreach ($exe in $exes) {
    Write-Host ""
    $filas = Test-AppDependencies -Exe $exe
    if ($null -eq $filas) {
        Write-Host "  $exe" -ForegroundColor Cyan
        Write-Host "    No es un ejecutable de Windows." -ForegroundColor Yellow
        continue
    }

    $pe = Get-PeInfo -FilePath $exe
    $bits = switch ($pe.Arquitectura) { 'x86' { '32 bits (x86)' } 'x64' { '64 bits (x64)' } default { $pe.Arquitectura } }
    Write-Host "  $exe" -ForegroundColor Cyan
    Write-Host "    $bits, pide $(@($filas).Count) DLL contando las de sus DLL" -ForegroundColor DarkGray

    if ($pe.EsDotNet) {
        Write-Host "    Es un programa .NET: lo que necesita es el runtime de .NET, no DLL sueltas." -ForegroundColor Yellow
    }

    # Una diferida que falta no impide arrancar: es un aviso, no el motivo.
    $graves = @($filas | Where-Object { $_.Estado -eq 'otra arquitectura' -or ($_.Estado -eq 'falta' -and -not $_.Diferida) })
    $avisos = @($filas | Where-Object { $_.Estado -eq 'falta' -and $_.Diferida })
    $mostrar = if ($Todo) { @($filas) } else { @($graves) + @($avisos) }

    foreach ($f in $mostrar) {
        $marca, $color = switch ($f.Estado) {
            'falta'             { if ($f.Diferida) { '[!]', 'Yellow' } else { '[X]', 'Red' } }
            'otra arquitectura' { '[X]', 'Red' }
            'windows'           { '   ', 'DarkGray' }
            default             { '[ok]', 'Green' }
        }
        $estado = switch ($f.Estado) {
            'falta'   { if ($f.Diferida) { 'FALTA (la carga mas tarde)' } else { 'FALTA' } }
            'windows' { 'de Windows' }
            'ok'      { "en $($f.Origen)" }
            default   { $f.Estado.ToUpper() }
        }
        Write-Host ("    {0,-4} {1,-28} {2}" -f $marca, $f.Dll, $estado) -ForegroundColor $color
        if ($f.Estado -ne 'windows' -and ($Todo -or $f.Estado -ne 'ok')) {
            if ($f.PedidaPor -ne (Split-Path -Leaf $exe)) { Write-Host "           la pide $($f.PedidaPor)" -ForegroundColor DarkGray }
            if ($f.Ruta -and $f.Estado -ne 'ok') { Write-Host "           $($f.Ruta)" -ForegroundColor DarkGray }
        }
        if ($f.Consejo) { Write-Host "           -> $($f.Consejo)" -ForegroundColor Yellow }
    }

    if ($avisos.Count -gt 0) {
        Write-Host "    [!] son de carga diferida: no impiden arrancar. Fallaria al usar lo que las" -ForegroundColor DarkGray
        Write-Host "        necesita, o nunca, si el programa le dice a Windows donde buscarlas." -ForegroundColor DarkGray
    }
    if ($graves.Count -eq 0) {
        Write-Host "    No le falta nada para arrancar." -ForegroundColor Green
        Write-Host "    Si aun asi no arranca, la causa es otra: permisos, un archivo de" -ForegroundColor DarkGray
        Write-Host "    configuracion, o una DLL que carga en marcha (LoadLibrary) y no se ve en el .exe." -ForegroundColor DarkGray
    }
    else {
        $conProblemas++
    }
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
if ($conProblemas -eq 0) {
    Write-Host "  Nada que falte en $($exes.Count) programa(s)." -ForegroundColor Green
}
else {
    Write-Host "  A $conProblemas de $($exes.Count) programa(s) les falta algo." -ForegroundColor Red
}
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

if ($conProblemas -gt 0) { exit 1 }
exit 0
