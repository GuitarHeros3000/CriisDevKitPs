#Requires -Version 5.1
<#
    Pruebas de lib\KitUpdate.ps1: poner una version nueva del kit encima de la
    que hay, y poder volver atras.

    Nada de red ni del kit de verdad: se fabrican dos copias pequenas del kit
    (la "instalada" y la "nueva") en carpetas temporales.
#>

$KitRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $KitRoot "lib\Common.ps1")
. (Join-Path $KitRoot "lib\KitUpdate.ps1")

$RaizTmp = Join-Path ([IO.Path]::GetTempPath()) ("kitupdate-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $RaizTmp -Force | Out-Null

function New-Copia {
    param([hashtable]$Archivos)
    $d = Join-Path $RaizTmp ([Guid]::NewGuid().ToString('N').Substring(0, 8))
    foreach ($k in $Archivos.Keys) {
        $f = Join-Path $d $k
        New-Item -ItemType Directory -Path (Split-Path -Parent $f) -Force | Out-Null
        [IO.File]::WriteAllText($f, $Archivos[$k])
    }
    return $d
}

function New-Escenario {
    $instalado = New-Copia @{
        'README.md'                 = 'v1'
        'sources.json'              = 'MIO, del usuario'
        'entorno-20261101.zip'      = 'un bundle mio'
        'bin\kit\Doctor-Env.bat'    = 'bat v1'
        'scripts\kit\Doctor-Env.ps1' = 'doctor v1'
        'scripts\kit\Viejo.ps1'     = 'ya no existe en la nueva'
        'lib\Common.ps1'            = '$KitVersion = "1.0.0"'
    }
    $nuevo = New-Copia @{
        'README.md'                 = 'v2'
        'bin\kit\Doctor-Env.bat'    = 'bat v2'
        'scripts\kit\Doctor-Env.ps1' = 'doctor v2'
        'scripts\env\Nuevo.ps1'     = 'nuevo en la v2'
        'lib\Common.ps1'            = '$KitVersion = "2.0.0"'
    }
    return [PSCustomObject]@{ Instalado = $instalado; Nuevo = $nuevo; Respaldo = (Join-Path $RaizTmp ([Guid]::NewGuid().ToString('N').Substring(0, 8))) }
}

function Leer { param($Raiz, $Rel) $f = Join-Path $Raiz $Rel; if (Test-Path -LiteralPath $f) { [IO.File]::ReadAllText($f) } else { $null } }

Describe "Update-KitFiles" {

    It "pone lo nuevo y lo cambiado" {
        $e = New-Escenario
        Update-KitFiles -Nuevo $e.Nuevo -Destino $e.Instalado -Respaldo $e.Respaldo -VersionAnterior '1.0.0' | Out-Null
        Leer $e.Instalado 'scripts\kit\Doctor-Env.ps1' | Should Be 'doctor v2'
        Leer $e.Instalado 'scripts\env\Nuevo.ps1' | Should Be 'nuevo en la v2'
        Leer $e.Instalado 'README.md' | Should Be 'v2'
    }

    # Un script que cambio de carpeta dejaba una copia vieja que Resolve-KitScript
    # podia encontrar antes que la buena.
    It "en las carpetas del kit, borra lo que la version nueva ya no trae" {
        $e = New-Escenario
        $r = Update-KitFiles -Nuevo $e.Nuevo -Destino $e.Instalado -Respaldo $e.Respaldo
        Test-Path -LiteralPath (Join-Path $e.Instalado 'scripts\kit\Viejo.ps1') | Should Be $false
        $r.Borrados | Should Be 1
    }

    # Lo del usuario vive en la raiz: su sources.json y sus bundles.
    It "en la raiz no borra nada que no sea del kit" {
        $e = New-Escenario
        Update-KitFiles -Nuevo $e.Nuevo -Destino $e.Instalado -Respaldo $e.Respaldo | Out-Null
        Leer $e.Instalado 'sources.json' | Should Be 'MIO, del usuario'
        Leer $e.Instalado 'entorno-20261101.zip' | Should Be 'un bundle mio'
    }

    # cmd lee un .bat a trozos mientras lo ejecuta: el que esta en marcha no se
    # puede sobrescribir.
    It "un .bat que cambia no se escribe: queda pendiente" {
        $e = New-Escenario
        $r = Update-KitFiles -Nuevo $e.Nuevo -Destino $e.Instalado -Respaldo $e.Respaldo
        Leer $e.Instalado 'bin\kit\Doctor-Env.bat' | Should Be 'bat v1'
        @($r.BatsPendientes).Count | Should Be 1
        $r.BatsPendientes[0].Destino | Should Be (Join-Path $e.Instalado 'bin\kit\Doctor-Env.bat')
    }

    It "guarda lo que cambia y lo que borra, y la version de antes, ANTES de tocar" {
        $e = New-Escenario
        Update-KitFiles -Nuevo $e.Nuevo -Destino $e.Instalado -Respaldo $e.Respaldo -VersionAnterior '1.0.0' | Out-Null
        Leer $e.Respaldo 'scripts\kit\Doctor-Env.ps1' | Should Be 'doctor v1'
        Leer $e.Respaldo 'scripts\kit\Viejo.ps1' | Should Be 'ya no existe en la nueva'
        (Leer $e.Respaldo '.criisdevkit-version').Trim() | Should Be '1.0.0'
        (Leer $e.Respaldo '.criisdevkit-anadidos.txt').Trim() | Should Be 'scripts\env\Nuevo.ps1'
    }
}

Describe "Restore-KitBackup" {

    It "deja el kit como estaba antes de actualizar" {
        $e = New-Escenario
        $antes = @(Get-ChildItem -LiteralPath $e.Instalado -Recurse -File | ForEach-Object { $_.FullName.Substring($e.Instalado.Length + 1) + '=' + [IO.File]::ReadAllText($_.FullName) } | Sort-Object) -join ';'

        Update-KitFiles -Nuevo $e.Nuevo -Destino $e.Instalado -Respaldo $e.Respaldo | Out-Null
        $r = Restore-KitBackup -Respaldo $e.Respaldo -Destino $e.Instalado

        $despues = @(Get-ChildItem -LiteralPath $e.Instalado -Recurse -File | ForEach-Object { $_.FullName.Substring($e.Instalado.Length + 1) + '=' + [IO.File]::ReadAllText($_.FullName) } | Sort-Object) -join ';'
        $despues | Should Be $antes
        $r.Borrados | Should Be 1
    }

    It "no borra nada fuera del kit aunque la lista lo pida" {
        $e = New-Escenario
        Update-KitFiles -Nuevo $e.Nuevo -Destino $e.Instalado -Respaldo $e.Respaldo | Out-Null
        $fuera = Join-Path $RaizTmp 'fuera.txt'
        [IO.File]::WriteAllText($fuera, 'no tocar')
        Add-Content -LiteralPath (Join-Path $e.Respaldo '.criisdevkit-anadidos.txt') -Value '..\fuera.txt'
        Restore-KitBackup -Respaldo $e.Respaldo -Destino $e.Instalado | Out-Null
        Test-Path -LiteralPath $fuera | Should Be $true
    }
}

Describe "Lo que se espera de una release" {

    It "lee la version de una copia del kit" {
        $d = New-Copia @{ 'lib\Common.ps1' = "# x`r`n`$KitVersion = `"9.8.7`"`r`n" }
        Get-KitVersionFromFolder -Raiz $d | Should Be '9.8.7'
    }

    It "una carpeta sin las piezas clave no pasa por el kit" {
        $d = New-Copia @{ 'lib\Common.ps1' = 'x'; 'Menu.bat' = 'x' }
        Test-KitFolderLooksComplete -Raiz $d | Should Be $false
    }

    It "el propio repositorio si pasa" {
        Test-KitFolderLooksComplete -Raiz $KitRoot | Should Be $true
    }

    # El contrato entre los dos lados: si publicar.yml cambia el nombre del zip
    # y Update-Kit no, ninguna actualizacion encontraria nada.
    It "el flujo que publica pone el zip y su .sha256 con el nombre que busca Update-Kit" {
        $f = Get-KitReleaseFiles -Tag 'v2.3.0'
        $f.FileName | Should Be 'CriisDevKitPs-2.3.0.zip'
        $f.Zip | Should Match '/releases/download/v2\.3\.0/CriisDevKitPs-2\.3\.0\.zip$'
        $f.Sha256 | Should Be "$($f.Zip).sha256"

        $yml = Get-Content -LiteralPath (Join-Path $KitRoot '.github\workflows\publicar.yml') -Raw
        $yml | Should Match ([regex]::Escape('$zip = "CriisDevKitPs-$v.zip"'))
        $yml | Should Match ([regex]::Escape('"$env:ZIP.sha256"'))
        $yml | Should Match ([regex]::Escape('--prefix=CriisDevKitPs/'))
    }
}

Describe "Start-DeferredCopy" {

    It "copia cuando ya ha pasado el rato, desde un proceso aparte" {
        $o = Join-Path $RaizTmp 'nuevo.bat'; $d = Join-Path $RaizTmp 'viejo.bat'
        [IO.File]::WriteAllText($o, 'nuevo'); [IO.File]::WriteAllText($d, 'viejo')
        Start-DeferredCopy -Pares @([PSCustomObject]@{ Origen = $o; Destino = $d }) -Segundos 1
        [IO.File]::ReadAllText($d) | Should Be 'viejo'
        $limite = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $limite -and [IO.File]::ReadAllText($d) -ne 'nuevo') { Start-Sleep -Milliseconds 300 }
        [IO.File]::ReadAllText($d) | Should Be 'nuevo'
    }
}

Remove-Item -LiteralPath $RaizTmp -Recurse -Force -ErrorAction SilentlyContinue
