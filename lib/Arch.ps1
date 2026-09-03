#Requires -Version 5.1
<#
    Arquitectura de la maquina, y como la llama cada fuente

    Parte de lib\Common.ps1, que es quien carga este archivo.

    El kit daba x64 por hecho en trece archivos. Los portatiles corporativos ya
    llegan con Windows on ARM, y ahi un JDK x64 corre emulado: funciona, pero mas
    lento y gastando mas bateria, que es justo lo que no sobra en un portatil.
#>

function Get-KitArchitecture {
    <#
    .SYNOPSIS
        'x64' o 'arm64', segun la maquina.
    .DESCRIPTION
        Se usa OSArchitecture y no $env:PROCESSOR_ARCHITECTURE a proposito. En
        Windows on ARM, un proceso x64 emulado -y Windows PowerShell 5.1 puede
        serlo- lee "AMD64" en esa variable: preguntando asi, el kit se bajaria
        binarios x64 en una maquina ARM y nadie sabria por que va lento.
        OSArchitecture responde por el SISTEMA, que es lo que se pregunta.

        CRIISDEVKIT_ARCH lo fuerza. Sirve para dos cosas: probar la construccion
        de URLs sin tener una maquina ARM delante, y bajarse a proposito los x64
        en una ARM si algo no tuviera build nativa.
    #>

    if ($env:CRIISDEVKIT_ARCH) {
        $forzada = $env:CRIISDEVKIT_ARCH.Trim().ToLowerInvariant()
        if ($forzada -in @('x64', 'arm64')) { return $forzada }
        # Un valor invalido no se ignora en silencio: quien lo puso creia estar
        # forzando algo, y seguir con la de la maquina le daria un resultado
        # correcto por casualidad o incorrecto sin explicacion.
        throw "CRIISDEVKIT_ARCH solo admite x64 o arm64, y vale '$($env:CRIISDEVKIT_ARCH)'."
    }

    try {
        if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') {
            return 'arm64'
        }
        return 'x64'
    }
    catch {
        # .NET demasiado antiguo para RuntimeInformation (llego en 4.7.1). Se
        # cae a las variables de entorno, que en una maquina x64 -que es donde
        # va a pasar esto- aciertan.
        if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') {
            return 'arm64'
        }
        return 'x64'
    }
}

function Get-ArchToken {
    <#
    .SYNOPSIS
        Como llama a esta arquitectura la fuente que se le diga.
    .DESCRIPTION
        Un solo sitio con toda la nomenclatura, porque NO hay un nombre comun y
        suponerlo cuesta una descarga que devuelve 404 sin explicar nada:

          Adoptium   aarch64  (no arm64: es el unico que usa el nombre de ARM)
          python.org amd64    (no x64: tambien es el unico raro en 64 bits)
          Node       arm64 / x64
          .NET       arm64 / x64
          VS Code    arm64 / x64

        Maven y Gradle no aparecen: son Java puro y su zip vale para las dos.
        Git tampoco, y ese caso es distinto -ver Test-ArchSoportada.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('adoptium', 'node', 'python', 'dotnet', 'vscode')]
        [string]$Fuente,

        [ValidateSet('x64', 'arm64')]
        [string]$Arch
    )

    if (-not $Arch) { $Arch = Get-KitArchitecture }

    if ($Arch -eq 'arm64') {
        switch ($Fuente) {
            'adoptium' { return 'aarch64' }
            'python'   { return 'arm64' }
            default    { return 'arm64' }
        }
    }

    switch ($Fuente) {
        'python' { return 'amd64' }
        default  { return 'x64' }
    }
}

function Test-ArchSoportada {
    <#
    .SYNOPSIS
        Si un runtime tiene build nativa para esta arquitectura.
    .DESCRIPTION
        Hoy solo falla Git: Git for Windows no publica un PortableGit arm64, asi
        que en una maquina ARM se coge el x64 y corre emulado. Funciona -Windows
        emula x64 en ARM- y para Git, que son procesos cortos, el coste no se
        nota.

        Se dice en vez de callarlo: alguien que ve "todo instalado" en una ARM
        tiene derecho a saber cual de sus runtimes no es nativo, sobre todo si
        despues mide rendimiento y no le cuadra.

        Devuelve Soportada y Motivo.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Clave,
        [ValidateSet('x64', 'arm64')][string]$Arch
    )

    if (-not $Arch) { $Arch = Get-KitArchitecture }

    if ($Arch -eq 'arm64' -and $Clave -eq 'git') {
        return [PSCustomObject]@{
            Soportada = $false
            Motivo    = 'Git for Windows no publica PortableGit para arm64; se usa el x64 emulado.'
        }
    }

    return [PSCustomObject]@{ Soportada = $true; Motivo = $null }
}
