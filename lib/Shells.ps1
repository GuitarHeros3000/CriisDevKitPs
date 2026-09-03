#Requires -Version 5.1
<#
    Escritura de los shells .bat que genera el kit

    Parte de lib\Common.ps1, que es quien carga este archivo. No se toma
    por separado: los scripts siguen haciendo un unico dot-source de
    Common.ps1 y no se enteran de esta division.
#>

# --------------------------------------------------------------------------
# Shells generados
# --------------------------------------------------------------------------
#
# Los .bat que abre Start-*Env viven aqui y no en cada setup porque los generan
# CUATRO sitios: los tres Setup-*, Import-Env (que los rehace con las rutas de la
# maquina destino) y Doctor -Fix (que los regenera si faltan). Con copias sueltas
# acabarian divergiendo y el shell diria una cosa distinta segun quien lo escribio.

function ConvertTo-PsLiteral {
    <#
        Escapa un valor para incrustarlo entre comillas SIMPLES en codigo de
        PowerShell generado. Ahi el unico caracter con significado es la propia
        comilla simple, y se anula duplicandola.

        Sin esto, un usuario llamado O'Brien producia un activate.ps1
        sintacticamente roto que el perfil carga en CADA PowerShell nuevo.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Value)
    return $Value.Replace("'", "''")
}

function ConvertTo-CmdLiteral {
    <#
        Escapa un valor para incrustarlo en un .bat dentro de set "VAR=...".
        Las comillas ya neutralizan &, |, ^, < y >; lo que sigue vivo es el
        porcentaje, que cmd expande al leer la linea y que es legal en un nombre
        de carpeta de Windows. Duplicarlo lo deja literal.

        Se aplica SOLO a los valores, nunca a la plantilla: el %PATH% del final
        tiene que expandirse de verdad.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Value)
    return $Value.Replace('%', '%%')
}

function ConvertFrom-CmdLiteral {
    <#
        Deshace ConvertTo-CmdLiteral. Hace falta porque Use-Env vuelve a LEER los
        shells generados para saber que rutas antepone cada uno: sin esto, una
        ruta con porcentaje se leeria con el %% puesto y se volveria a escapar en
        cada pasada (%%%%, %%%%%%%%...).
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Value)
    return $Value.Replace('%%', '%')
}

function ConvertTo-CmdEchoText {
    <#
        Escapa un valor para una linea "echo ..." de un .bat. Aqui no se puede
        recurrir a las comillas como en set: se imprimirian. Hay que escapar a
        mano cada caracter especial de cmd.

        El circunflejo va PRIMERO porque es el propio caracter de escape: hacerlo
        despues escaparia los que acabamos de anadir.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Value)

    $result = $Value.Replace('^', '^^')
    foreach ($c in @('&', '|', '<', '>')) { $result = $result.Replace($c, "^$c") }
    return $result.Replace('%', '%%')
}

function Write-AngularShell {
    param(
        [Parameter(Mandatory=$true)][string]$AngularPath,
        [Parameter(Mandatory=$true)][string]$NodePath,
        [Parameter(Mandatory=$true)][string]$Version,
        [Parameter(Mandatory=$true)][string]$NodeVersion
    )

    $angularRoot = Split-Path -Parent $AngularPath
    $npmPrefix   = Join-Path $AngularPath "npm-global"
    $npmCache    = Join-Path $angularRoot "npm-cache"

    # El prefix y la cache van aqui, no en el .npmrc del usuario: asi el npm que
    # ya tuviera instalado sigue intacto y este shell queda autocontenido.
    #
    # Las rutas van en set "VAR=..." y escapadas. Sin las comillas, un & o un ^
    # en la ruta (legales en Windows: "Marks & Spencer", muy posible en el nombre
    # de una carpeta corporativa) rompia la linea entera.
    $nodeCmd    = ConvertTo-CmdLiteral $NodePath
    $prefixCmd  = ConvertTo-CmdLiteral $npmPrefix
    $cacheCmd   = ConvertTo-CmdLiteral $npmCache
    $proyectos  = ConvertTo-CmdEchoText (Join-Path $AngularPath "projects")

    $lines = @(
        "@echo off",
        "set `"PATH=$nodeCmd;$prefixCmd;%PATH%`"",
        "set `"NPM_CONFIG_PREFIX=$prefixCmd`"",
        "set `"NPM_CONFIG_CACHE=$cacheCmd`""
    )
    $lines += Get-NodeCaLine

    $lines += @(
        "title Angular v$Version Development Shell",
        "echo.",
        "echo ============================================",
        "echo   Angular v$Version Development Shell",
        "echo ============================================",
        "echo.",
        "echo Node: $NodeVersion",
        "echo Angular CLI: v$Version",
        "echo.",
        "echo Proyectos: $proyectos",
        "echo.",
        "echo Comandos:",
        "echo   ng new [nombre]     - Crear proyecto",
        "echo   ng serve            - Iniciar servidor",
        "echo.",
        "echo Escribe exit para cerrar",
        "cmd /k"
    )

    $file = Join-Path $AngularPath "shell-v$Version.bat"
    Set-Content -Path $file -Value ($lines -join "`n") -Encoding ASCII
    return $file
}

function Write-PythonShell {
    param(
        [Parameter(Mandatory=$true)][string]$PythonPath,
        [Parameter(Mandatory=$true)][string]$Version
    )

    $tag = $Version -replace '\.', ''
    $scripts = Join-Path $PythonPath "Scripts"

    $pythonCmd  = ConvertTo-CmdLiteral $PythonPath
    $scriptsCmd = ConvertTo-CmdLiteral $scripts

    $lines = @(
        "@echo off",
        "set `"PATH=$pythonCmd;$scriptsCmd;%PATH%`"",
        "title Python v$Version Shell",
        "echo.",
        "echo ============================================",
        "echo   Python v$Version Shell",
        "echo ============================================",
        "echo.",
        "python.exe --version",
        "echo.",
        "echo Comandos:",
        "echo   python --version    - Ver version",
        "echo   pip install [paq]   - Instalar paquete",
        "echo.",
        "echo Escribe exit para cerrar",
        "cmd /k"
    )

    $file = Join-Path $PythonPath "py$tag-shell.bat"
    Set-Content -Path $file -Value ($lines -join "`n") -Encoding ASCII
    return $file
}

function Write-JavaShell {
    param(
        [Parameter(Mandatory=$true)][string]$JdkPath,
        [Parameter(Mandatory=$true)][string]$Major,
        [string]$Release
    )

    $bin = Join-Path $JdkPath "bin"

    $binCmd     = ConvertTo-CmdLiteral $bin
    $jdkCmd     = ConvertTo-CmdLiteral $JdkPath
    $jdkEcho    = ConvertTo-CmdEchoText $JdkPath

    $lines = @(
        "@echo off",
        "set `"PATH=$binCmd;%PATH%`"",
        "set `"JAVA_HOME=$jdkCmd`"",
        "title Java $Major Shell",
        "echo.",
        "echo ============================================",
        "echo   Java $Major Shell",
        "echo ============================================",
        "echo.",
        "echo Release: $Release",
        "echo JAVA_HOME: $jdkEcho",
        "echo.",
        "java -version",
        "echo.",
        "echo Comandos:",
        "echo   javac Archivo.java  - Compilar",
        "echo   jar                 - Empaquetar",
        "echo.",
        "echo Escribe exit para cerrar",
        "cmd /k"
    )

    $file = Join-Path $JdkPath "java$Major-shell.bat"
    Set-Content -Path $file -Value ($lines -join "`n") -Encoding ASCII
    return $file
}
