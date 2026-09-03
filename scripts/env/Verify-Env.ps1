#Requires -Version 5.1
<#
.SYNOPSIS
    Verify-Env.ps1 - Comprueba que lo instalado sigue siendo lo que se instalo.
.DESCRIPTION
    Doctor mira la maquina entera y por encima. Esto mira UN runtime y mas
    hondo: si su firma sigue siendo la de siempre, si la instalacion esta
    completa, si la version que hay dentro es la que dice la carpeta, y si el
    shell y el PATH siguen en su sitio.

    Es de solo lectura. No descarga, no repara y no toca nada; cuando encuentra
    algo, dice con que comando se arregla.

    LO QUE NO PUEDE COMPROBAR, y conviene saberlo: el SHA-256 de los archivos
    instalados. Los Setup verifican el checksum al descargar y luego borran el
    archivo, asi que no queda contra que comparar. La unica excepcion es Python,
    que si anota el suyo. Para los demas se dice "no consta" en vez de callarlo:
    dar a entender una garantia que no existe es peor que no darla.

    Contra eso, lo que si detecta un binario cambiado despues de instalar es la
    firma Authenticode, que es lo que comprueba este comando.
.PARAMETER Runtime
    Cual verificar. Sin este parametro, todos los que haya instalados.
.PARAMETER Version
    Solo esa linea (ej: -Runtime Java -Version 21). Sin ella, todas.
.EXAMPLE
    .\Verify-Env.ps1
.EXAMPLE
    .\Verify-Env.ps1 -Runtime Java
.EXAMPLE
    .\Verify-Env.ps1 -Runtime Java -Version 21
#>

param(
    [ValidateSet('Python', 'Java', 'Node', 'Angular', 'Git', 'Maven', 'Gradle', 'Dotnet', 'VSCode')]
    [string]$Runtime,

    [string]$Version
)

$ProgressPreference = "SilentlyContinue"

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "lib\Common.ps1")

$script:Problemas = 0
$script:Avisos    = 0

function Write-Verify {
    param(
        [string]$Etiqueta,
        [string]$Valor,
        [ValidateSet('ok', 'warn', 'fail', 'info')][string]$Estado = 'info'
    )

    $marca, $color = switch ($Estado) {
        'ok'    { '[ok]  ', 'Green' }
        'warn'  { '[!]   ', 'Yellow' }
        'fail'  { '[X]   ', 'Red' }
        default { '      ', 'Gray' }
    }

    if ($Estado -eq 'fail') { $script:Problemas++ }
    if ($Estado -eq 'warn') { $script:Avisos++ }

    Write-Host $marca -ForegroundColor $color -NoNewline
    Write-Host ("{0,-24}" -f $Etiqueta) -NoNewline
    Write-Host $Valor -ForegroundColor $color
}

function Write-VerifyDetail {
    param([string]$Texto)
    Write-Host "        $Texto" -ForegroundColor DarkGray
}

function Test-RuntimeLinea {
    <#
        Las comprobaciones de UNA linea instalada. Todo lo que necesita saber
        sale del catalogo, asi que un runtime nuevo queda cubierto por existir.
    #>
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$Entrada,
        [Parameter(Mandatory=$true)][string]$Linea
    )

    $dir = Get-RuntimeInstallPath -Entrada $Entrada -Linea $Linea
    $etiqueta = Get-RuntimeFolderName -Entrada $Entrada -Linea $Linea

    Write-Host ""
    Write-Host "  $($Entrada.Nombre) $Linea" -ForegroundColor Cyan
    Write-Host "  $dir" -ForegroundColor DarkGray

    if (-not (Test-Path -LiteralPath $dir)) {
        Write-Verify $etiqueta "la carpeta no existe" 'fail'
        return
    }

    # --- Que la instalacion este entera ---
    #
    # Se pregunta por la version en vez de contar archivos: cada runtime la
    # guarda en un sitio distinto y Get-InstalledRuntimeVersion ya lo sabe, asi
    # que si devuelve algo es que sus piezas clave estan. Una extraccion a
    # medias -o un antivirus que se llevo un binario- se ve justo aqui.
    $instalada = Get-InstalledRuntimeVersion -Entrada $Entrada -Linea $Linea

    if (-not $instalada) {
        Write-Verify $etiqueta "no se puede leer la version" 'fail'
        Write-VerifyDetail "La instalacion parece incompleta: falta algo dentro de la carpeta."
        Write-VerifyDetail "Reinstala:  .\bin\setup\Setup-$($Entrada.Carpeta)Env.bat -Force"
        return
    }

    Write-Verify "version" $instalada 'ok'

    # Que lo de dentro sea de la linea que dice la carpeta. Se descuadra al
    # renombrar una carpeta a mano, que es mas comun de lo que parece.
    if (-not $instalada.StartsWith($Linea)) {
        Write-Verify "coherencia" "la carpeta dice $Linea y dentro hay $instalada" 'warn'
        Write-VerifyDetail "Alguien renombro la carpeta, o se instalo otra version encima."
    }

    # --- Firma ---
    if ($Entrada.ExeFirma) {
        $exe = Join-Path $dir $Entrada.ExeFirma

        if (-not (Test-Path -LiteralPath $exe)) {
            Write-Verify "firma" "falta $($Entrada.ExeFirma)" 'fail'
        }
        else {
            $f = Get-FileSignerInfo -FilePath $exe

            # La lista de esperados admite varias formas: un mismo proveedor
            # firma con nombres distintos segun la epoca (Temurin lo hace).
            $esperados = @($Entrada.FirmanteEsperado | Where-Object { $_ })
            $encaja = ($esperados.Count -eq 0) -or
                      @($esperados | Where-Object { $f.Firmante -like "*$_*" }).Count -gt 0

            if ($f.Estado -eq 'Valid' -and $encaja) {
                Write-Verify "firma" "$($f.Firmante)" 'ok'
            }
            elseif ($f.Estado -eq 'Valid') {
                # Firmado, valido, pero por OTRO. Esta es la senal que justifica
                # todo el comando.
                Write-Verify "firma" "la pone $($f.Firmante), NO $($esperados -join ' ni ')" 'fail'
                Write-VerifyDetail "Reinstala desde la fuente oficial:  .\bin\setup\Setup-$($Entrada.Carpeta)Env.bat -Force"
            }
            elseif ($f.Estado -eq 'NotSigned') {
                Write-Verify "firma" "sin firma" 'warn'
                Write-VerifyDetail "$($esperados -join ' o ') firma sus binarios; que este no lo este es raro."
            }
            else {
                Write-Verify "firma" "no se pudo comprobar ($($f.Estado))" 'warn'
            }
        }
    }
    else {
        # Maven y Gradle se lanzan con un .cmd, y a un script por lotes no se le
        # aplica Authenticode. Se dice, en vez de dejar el hueco en blanco.
        Write-Verify "firma" "no aplica (se lanza con un script, no un .exe)" 'info'
    }

    # --- SHA-256 de la descarga ---
    $sha = Get-InstalledRuntimeSha256 -Entrada $Entrada -Linea $Linea
    if ($sha) {
        Write-Verify "sha-256 al instalar" $sha.Substring(0, 16) 'ok'
    }
    else {
        Write-Verify "sha-256 al instalar" "no consta" 'info'
        Write-VerifyDetail "Se verifico al descargar, pero no se guardo: no hay contra que comparar."
    }

    # --- Shell ---
    #
    # Se busca cualquier .bat en la carpeta en vez del nombre exacto: cada
    # runtime lo compone a su manera (java21-shell.bat, shell-v20.bat,
    # py3.12-shell.bat) y repetir esa logica aqui seria una cuarta copia.
    $shells = @(Get-ChildItem -LiteralPath $dir -Filter *.bat -File -ErrorAction SilentlyContinue)
    if ($shells.Count -gt 0) {
        Write-Verify "shell" "$($shells[0].Name)" 'ok'
    }
    else {
        Write-Verify "shell" "no hay ninguno" 'warn'
        Write-VerifyDetail "Lo regenera:  .\bin\kit\Doctor-Env.bat -Fix"
    }

    # --- PATH de usuario ---
    $enPath = @(Split-UserPath -Path (Get-RawUserPath) | Where-Object {
        $_ -and $_.TrimEnd('\').StartsWith($dir.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
    })

    if ($enPath.Count -gt 0) {
        Write-Verify "PATH de usuario" "$($enPath.Count) entrada(s)" 'ok'
    }
    else {
        # No es un fallo: los Start-*Env abren un shell sin tocar el PATH, y hay
        # quien los usa siempre a proposito.
        Write-Verify "PATH de usuario" "sin entradas" 'info'
        Write-VerifyDetail "Se usa con .\bin\start\Start-$($Entrada.Carpeta)Env.bat, o ponlo en el PATH con Use-Env."
    }
}

# --------------------------------------------------------------------------

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Verify-Env - Lo instalado sigue siendo lo que se instalo?" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

$catalogo = @(Get-RuntimeCatalog)
if ($Runtime) {
    $catalogo = @($catalogo | Where-Object { $_.Carpeta -eq $Runtime })
}

$vistos = 0
foreach ($e in $catalogo) {
    $lineas = @(Get-InstalledRuntimeLines -Entrada $e)
    if ($Version) { $lineas = @($lineas | Where-Object { $_ -eq $Version }) }

    foreach ($l in ($lineas | Sort-Object)) {
        $vistos++
        Test-RuntimeLinea -Entrada $e -Linea $l
    }
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan

if ($vistos -eq 0) {
    $que = if ($Runtime -and $Version) { "$Runtime $Version" }
           elseif ($Runtime)           { $Runtime }
           else                        { "nada" }
    Write-Host "  No hay $que instalado que verificar." -ForegroundColor Yellow
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

if ($script:Problemas -eq 0 -and $script:Avisos -eq 0) {
    Write-Host "  $vistos comprobado(s). Todo correcto." -ForegroundColor Green
}
elseif ($script:Problemas -eq 0) {
    Write-Host "  $vistos comprobado(s). $($script:Avisos) aviso(s)." -ForegroundColor Yellow
}
else {
    Write-Host "  $vistos comprobado(s). $($script:Problemas) problema(s) y $($script:Avisos) aviso(s)." -ForegroundColor Red
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Igual que Doctor: 1 si hay algo grave, para poder encadenarlo.
if ($script:Problemas -gt 0) { exit 1 }
exit 0
