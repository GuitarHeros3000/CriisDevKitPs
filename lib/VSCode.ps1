#Requires -Version 5.1
<#
    VS Code: ajustes, extensiones y los JDK que conoce

    Parte de lib\Common.ps1, que es quien carga este archivo. No se toma
    por separado: los scripts siguen haciendo un unico dot-source de
    Common.ps1 y no se enteran de esta division.
#>

function Get-VSCodeSettingsTargets {
    <#
        Donde vive el settings.json de cada VS Code que haya en la maquina.

        Son dos sitios distintos y no uno: el VS Code portable del kit guarda
        sus ajustes dentro de su propia carpeta data\, y el que se instala por
        usuario -sin admin, el habitual- los guarda en %APPDATA%\Code. Registrar
        los JDK en el que no se usa no serviria de nada, asi que se buscan los
        dos y se dice cual es cual.

        Devuelve tambien los que aun no tienen settings.json: el archivo se crea
        la primera vez que se cambia un ajuste, y no tenerlo no significa que ese
        VS Code no exista.
    #>
    $targets = @()

    # 1. El portable del kit, una carpeta data\ por version.
    $vscodeRoot = Join-Path $WorkspaceRoot "VSCode"
    if (Test-Path -LiteralPath $vscodeRoot) {
        foreach ($d in @(Get-ChildItem -LiteralPath $vscodeRoot -Directory -ErrorAction SilentlyContinue)) {
            if ($d.Name -notmatch '^vscode-(\d+\.\d+)$') { continue }
            if (-not (Test-Path (Join-Path $d.FullName "Code.exe"))) { continue }

            $targets += [PSCustomObject]@{
                # Corta a proposito: Doctor la imprime en una columna de 26.
                Etiqueta = "VS Code $($Matches[1]) del kit"
                Ruta     = Join-Path $d.FullName "data\user-data\User\settings.json"
                DelKit   = $true
            }
        }
    }

    # 2. El instalado por usuario. Se comprueba el ejecutable y no solo la
    # carpeta de ajustes: %APPDATA%\Code sobrevive a una desinstalacion.
    $exe = Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code\Code.exe"
    $sys = "C:\Program Files\Microsoft VS Code\Code.exe"
    if ((Test-Path -LiteralPath $exe) -or (Test-Path -LiteralPath $sys)) {
        $targets += [PSCustomObject]@{
            Etiqueta = "VS Code del equipo"
            Ruta     = Join-Path $env:APPDATA "Code\User\settings.json"
            DelKit   = $false
        }
    }

    return $targets
}

function Get-VSCodeCli {
    <#
        El code.cmd de un VS Code, a partir de la ruta de su settings.json.

        Hace falta para preguntarle por sus extensiones y para instalarlas, y no
        es deducible de una sola regla: en el portable esta en <carpeta>\bin\ y
        en el instalado por usuario, en Programs\Microsoft VS Code\bin\.
    #>
    param([Parameter(Mandatory=$true)][string]$SettingsPath)

    # Portable:  ...\vscode-1.136\data\user-data\User\settings.json
    $userData = Split-Path -Parent (Split-Path -Parent $SettingsPath)
    if ((Split-Path -Leaf $userData) -eq 'user-data') {
        $raiz = Split-Path -Parent (Split-Path -Parent $userData)
        $cli  = Join-Path $raiz "bin\code.cmd"
        if (Test-Path -LiteralPath $cli) { return $cli }
        return $null
    }

    # Instalado por usuario o de maquina.
    foreach ($c in @(
        (Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code\bin\code.cmd"),
        "C:\Program Files\Microsoft VS Code\bin\code.cmd"
    )) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}

function Get-VSCodeExtensions {
    <#
        Que extensiones tiene instaladas ese VS Code.

        Se leen las CARPETAS, descontando las que .obsolete marque.

        Las dos alternativas evidentes estan mal, y las dos se probaron:

        - extensions.json de la carpeta de extensiones parecia el registro
          bueno, pero en cuanto se usan PERFILES de VS Code queda vacio: cada
          perfil lleva el suyo en User\profiles\<id>\extensions.json. En un
          equipo con 68 extensiones instaladas devolvia cero.

        - los nombres de carpeta a secas tampoco: al desinstalar, VS Code dice
          "successfully uninstalled" pero deja la carpeta y la anota en
          .obsolete para borrarla al arrancar, asi que una extension retirada
          seguia constando como instalada.

        La carpeta menos lo obsoleto acierta en los dos casos, y ademas es lo
        que interesa: los perfiles solo eligen cuales se activan, pero todas
        viven en el mismo sitio.

        Tampoco se usa 'code --list-extensions': tarda varios segundos y Doctor
        lo llamaria en cada ejecucion.
    #>
    param([Parameter(Mandatory=$true)][string]$SettingsPath)

    # Portable: data\extensions, al lado de data\user-data.
    $userData = Split-Path -Parent (Split-Path -Parent $SettingsPath)
    $dir = if ((Split-Path -Leaf $userData) -eq 'user-data') {
        Join-Path (Split-Path -Parent $userData) "extensions"
    } else {
        Join-Path $env:USERPROFILE ".vscode\extensions"
    }

    if (-not (Test-Path -LiteralPath $dir)) { return @() }

    $obsoletas = @()
    $ob = Join-Path $dir ".obsolete"
    if (Test-Path -LiteralPath $ob) {
        try {
            $o = Get-Content -LiteralPath $ob -Raw | ConvertFrom-Json
            $obsoletas = @($o.PSObject.Properties.Name)
        }
        catch { }
    }

    # El nombre de carpeta es <publicador>.<id>-<version>[-<plataforma>].
    return @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $obsoletas -notcontains $_.Name } |
        ForEach-Object { $_.Name -replace '-\d+\.\d+\.\d+.*$', '' } |
        Sort-Object -Unique)
}

function Install-VSCodeExtension {
    <#
        Instala una extension en ese VS Code con su propio CLI. No pide admin: en
        el portable va a data\extensions y en el instalado por usuario, al perfil.

        VS Code no usa la descarga del kit, sale por su cuenta, asi que se le
        pasa el proxy por las variables que si mira. Sin esto, en un equipo con
        proxy obligatorio la instalacion fallaba sin explicar por que.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$CodeCmd,
        [Parameter(Mandatory=$true)][string]$Id
    )

    $previo = @{ HTTPS_PROXY = $env:HTTPS_PROXY; HTTP_PROXY = $env:HTTP_PROXY }
    try {
        $proxy = Resolve-DownloadProxy -Uri ([Uri]"https://marketplace.visualstudio.com")
        if ($proxy) {
            $env:HTTPS_PROXY = $proxy
            $env:HTTP_PROXY  = $proxy
        }

        $salida = & cmd /c "`"$CodeCmd`" --install-extension $Id --force 2>&1"
        $rc = $LASTEXITCODE

        return [PSCustomObject]@{
            Ok     = ($rc -eq 0)
            Salida = @($salida)
        }
    }
    finally {
        $env:HTTPS_PROXY = $previo.HTTPS_PROXY
        $env:HTTP_PROXY  = $previo.HTTP_PROXY
    }
}

function Get-KitJavaRuntimeEntries {
    <#
        Las entradas de java.configuration.runtimes que describen los JDK del
        kit. Es el ajuste con el que la extension de Java elige un JDK POR
        PROYECTO, segun el nivel que declare cada uno, sin tocar los proyectos.

        El nombre no es libre: la extension espera el identificador oficial de la
        plataforma, y el Java 8 se llama JavaSE-1.8 y no JavaSE-8.
    #>
    param([string]$Default)

    $entradas = @()
    $javaRoot = Join-Path $WorkspaceRoot "Java"

    foreach ($l in @(Get-KitJdkLines)) {
        $nombre = if ($l -eq '8') { 'JavaSE-1.8' } else { "JavaSE-$l" }
        $e = [ordered]@{
            name = $nombre
            path = (Join-Path $javaRoot "jdk-$l")
        }
        if ($Default -and $l -eq $Default) { $e['default'] = $true }
        $entradas += [PSCustomObject]$e
    }

    return $entradas
}

function Merge-VSCodeJavaRuntimes {
    <#
        Mezcla las entradas del kit con las que ya hubiera en settings.json.

        Las de fuera del kit se CONSERVAN: quien tenga registrado a mano el JDK
        de la empresa no puede perderlo por ejecutar esto. Solo se reemplazan las
        que apuntan dentro de la carpeta Java del kit, que son las nuestras.

        Si el kit pone un default, se le quita a las conservadas: la extension
        admite un unico runtime por defecto y dos lo dejarian en un estado que
        no se puede predecir.

        Con -Quitar se van las del kit y se quedan solo las ajenas.
    #>
    param(
        [AllowNull()]$Actual,
        [AllowNull()]$DelKit,
        [Parameter(Mandatory=$true)][string]$RaizJava,
        [switch]$Quitar
    )

    $raiz = $RaizJava.TrimEnd('\')
    $ajenas = @(@($Actual) | Where-Object { $_ -and $_.path } | Where-Object {
        $p = ([string]$_.path).TrimEnd('\')
        -not ($p -ieq $raiz -or $p.StartsWith($raiz + '\', [StringComparison]::OrdinalIgnoreCase))
    })

    if ($Quitar) { return @($ajenas) }

    $nuevas = @($DelKit)
    $hayDefaultDelKit = @($nuevas | Where-Object { $_.default }).Count -gt 0

    if ($hayDefaultDelKit) {
        $ajenas = @($ajenas | ForEach-Object {
            $copia = [ordered]@{}
            foreach ($p in $_.PSObject.Properties) {
                if ($p.Name -ne 'default') { $copia[$p.Name] = $p.Value }
            }
            [PSCustomObject]$copia
        })
    }

    return @($ajenas + $nuevas)
}

function Read-VSCodeSettings {
    <#
        Lee un settings.json de VS Code. Devuelve Ajustes, y Legible en $false si
        lleva comentarios: VS Code los admite y ConvertFrom-Json no, asi que ese
        archivo se puede leer a medias pero NO se puede reescribir sin comerselos.
    #>
    param([Parameter(Mandatory=$true)][string]$Ruta)

    if (-not (Test-Path -LiteralPath $Ruta)) {
        return [PSCustomObject]@{ Ajustes = [PSCustomObject]@{}; Legible = $true; Existe = $false }
    }

    $texto = Get-Content -LiteralPath $Ruta -Raw
    if ([string]::IsNullOrWhiteSpace($texto)) {
        return [PSCustomObject]@{ Ajustes = [PSCustomObject]@{}; Legible = $true; Existe = $true }
    }

    try { $o = $texto | ConvertFrom-Json }
    catch { return [PSCustomObject]@{ Ajustes = $null; Legible = $false; Existe = $true } }

    return [PSCustomObject]@{ Ajustes = $o; Legible = $true; Existe = $true }
}

function Set-VSCodeJavaRuntimes {
    <#
        Escribe java.configuration.runtimes en un settings.json conservando el
        resto de ajustes. Se recompone el objeto entero porque asi da igual que
        la propiedad ya estuviera o no.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Ruta,
        [Parameter(Mandatory=$true)][AllowNull()]$Ajustes,
        [AllowNull()]$Runtimes
    )

    $carpeta = Split-Path -Parent $Ruta
    if (-not (Test-Path -LiteralPath $carpeta)) {
        New-Item -ItemType Directory -Path $carpeta -Force | Out-Null
    }

    $salida = [ordered]@{}
    if ($Ajustes) {
        foreach ($p in $Ajustes.PSObject.Properties) {
            if ($p.Name -ne 'java.configuration.runtimes') { $salida[$p.Name] = $p.Value }
        }
    }
    if (@($Runtimes).Count -gt 0) { $salida['java.configuration.runtimes'] = @($Runtimes) }

    ([PSCustomObject]$salida | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $Ruta -Encoding UTF8
}

function Get-RegisteredKitJdks {
    <#
        Que lineas de JDK del kit constan en un settings.json ya leido.
    #>
    param([AllowNull()]$Ajustes)

    if (-not $Ajustes -or -not $Ajustes.PSObject.Properties['java.configuration.runtimes']) { return @() }
    $raiz = (Join-Path $WorkspaceRoot "Java").TrimEnd('\')

    return @(@($Ajustes.'java.configuration.runtimes') |
        Where-Object { $_ -and $_.path -and ([string]$_.path).StartsWith($raiz, [StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object { if ((Split-Path -Leaf ([string]$_.path)) -match '^jdk-(\d+)$') { $Matches[1] } })
}

function Sync-VSCodeJavaRuntimes {
    <#
        Pone al dia los JDK registrados en el VS Code PORTABLE del kit.

        Es el equivalente de Sync-BuildToolShells para el editor: instalar o
        quitar un JDK tiene que notarse donde el kit ya lo tiene anotado, sin que
        haya que acordarse de reejecutar nada. Que una cosa fuera automatica y la
        otra no era una incoherencia, no una decision.

        Solo toca el portable, nunca el VS Code instalado en el equipo: ese es del
        usuario y se entra ahi unicamente con Use-VSCodeJava -Global.

        Y solo si YA tenia JDK del kit anotados. Un portable donde nadie los
        registro -o donde se quitaron con -Remove- se queda como esta: mantener al
        dia lo que alguien pidio es una cosa, y decidir por el otra distinta.

        Con -Inicializar se registra tambien donde no hubiera nada, que es lo que
        hace falta al instalar el editor teniendo ya JDK.
    #>
    param([switch]$Inicializar)

    $resumen = @()
    $lineas  = @(Get-KitJdkLines)

    foreach ($t in @(Get-VSCodeSettingsTargets | Where-Object { $_.DelKit })) {
        if (Update-VSCodeJavaRuntimes -Ruta $t.Ruta -Inicializar:$Inicializar) {
            $txt = if ($lineas.Count -gt 0) { "Java $($lineas -join ', ')" } else { "sin ningun JDK" }
            $resumen += "$($t.Etiqueta) : $txt"
        }
    }

    return $resumen
}

function Update-VSCodeJavaRuntimes {
    <#
        Pone al dia UN settings.json con los JDK del kit. Devuelve $true si lo
        cambio.

        Aparte de Sync-VSCodeJavaRuntimes para que Doctor -Fix pueda reparar un
        settings.json concreto -incluido el del VS Code del equipo, si el usuario
        opto por gestionarlo- sin repetir la logica del JDK por defecto.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Ruta,
        [switch]$Inicializar
    )

    $lineas = @(Get-KitJdkLines)
    $s = Read-VSCodeSettings -Ruta $Ruta
    if (-not $s.Legible) { return $false }

    $tieneClave = $s.Ajustes -and $s.Ajustes.PSObject.Properties['java.configuration.runtimes']
    $yaHay = @(Get-RegisteredKitJdks -Ajustes $s.Ajustes)

    if ($yaHay.Count -eq 0) {
        # Sin nada anotado no se decide por el usuario, salvo al instalar el
        # editor: ahi si, un portable nuevo debe nacer sabiendo que JDK hay.
        if (-not $Inicializar -or $tieneClave -or $lineas.Count -eq 0) { return $false }
    }

    # Se respeta el JDK por defecto que hubiera si sigue instalado: cambiarlo
    # por instalar otra version seria decidir con que compila sin avisar.
    $defActual = $null
    if ($tieneClave) {
        $d = @(@($s.Ajustes.'java.configuration.runtimes') | Where-Object { $_.default -and $_.path })
        if ($d.Count -gt 0 -and (Split-Path -Leaf ([string]$d[0].path)) -match '^jdk-(\d+)$') {
            $defActual = $Matches[1]
        }
    }
    $porDefecto = if ($defActual -and $lineas -contains $defActual) { $defActual }
                  elseif ($lineas.Count -gt 0) { $lineas[-1] }
                  else { $null }

    $delKit    = @(Get-KitJavaRuntimeEntries -Default $porDefecto)
    $actual    = if ($tieneClave) { @($s.Ajustes.'java.configuration.runtimes') } else { @() }
    $resultado = @(Merge-VSCodeJavaRuntimes -Actual $actual -DelKit $delKit `
                                            -RaizJava (Join-Path $WorkspaceRoot "Java"))

    $antes   = (@($actual)    | ForEach-Object { "$($_.name)=$($_.path)=$($_.default)" }) -join '|'
    $despues = (@($resultado) | ForEach-Object { "$($_.name)=$($_.path)=$($_.default)" }) -join '|'
    if ($antes -eq $despues) { return $false }

    Set-VSCodeJavaRuntimes -Ruta $Ruta -Ajustes $s.Ajustes -Runtimes $resultado
    return $true
}
