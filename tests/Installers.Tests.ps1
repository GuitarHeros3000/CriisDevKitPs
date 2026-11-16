#Requires -Version 5.1
<#
    Pruebas de lib\Installers.ps1: leer un .exe, un bundle Burn y un MSI sin
    ejecutar ninguno.

    Todo se fabrica aqui, con makecab y con la propia API de Windows Installer,
    en vez de usar binarios de verdad: el redistribuible de Visual C++ pesa
    7 MB y no puede vivir en el repositorio, y los de System32 cambian de
    arquitectura segun la maquina.

    La prueba que mas importa es la de la firma entre contenedores. Ese fallo
    existio: el kit contaba los contenedores seguidos, el segundo caia 16 KB
    antes de tiempo, y solo lo freno que cada contenedor tiene que empezar
    como un CAB. Un bundle de prueba sin esa firma no lo habria visto.
#>

$KitRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $KitRoot "lib\Common.ps1")
. (Join-Path $PSScriptRoot "Helpers.ps1")

function New-CarpetaTemporal {
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ("installers-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return $d
}

function Get-Sha1 {
    param([string]$Texto)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Texto))) -replace '-', '') }
    finally { $sha.Dispose() }
}

function New-BundleDePrueba {
    <#
        Un bundle Burn con dos contenedores, como los de verdad: el primero
        con el manifiesto ("0") y el segundo con una carga ("a0"). -Firma mete
        entre los dos los bytes de la firma original del motor.
    #>
    param(
        [string]$Carpeta,
        [string]$Contenido = 'contenido de la carga',
        [string]$RutaCarga = 'packages\cosa\cosa.msi',
        [string]$Hash,
        [switch]$ConExterna,
        [int]$Firma = 0
    )

    if (-not $Hash) { $Hash = Get-Sha1 $Contenido }
    $externa = if ($ConExterna) {
        '<Payload Id="web" FilePath="packages\web\web.msi" SourcePath="w0" DownloadUrl="https://example.com/web.msi" Hash="00" />'
    } else { '' }

    $manifiesto = @"
<?xml version="1.0" encoding="utf-8"?>
<BurnManifest xmlns="http://schemas.microsoft.com/wix/2008/Burn">
  <UX><Payload Id="ux" FilePath="ux.dll" SourcePath="u0" /></UX>
  <Container Id="WixAttachedContainer" FileSize="1" Hash="00" FilePath="bundle.exe" AttachedIndex="1" Attached="yes" Primary="yes" />
  <Payload Id="cosa" FilePath="$RutaCarga" SourcePath="a0" Container="WixAttachedContainer" Hash="$Hash" />
  $externa
</BurnManifest>
"@

    $ux = New-CabDePrueba -Carpeta $Carpeta -Nombre '0' -Contenido $manifiesto
    $at = New-CabDePrueba -Carpeta $Carpeta -Nombre 'a0' -Contenido $Contenido
    $tamUx = (Get-Item -LiteralPath $ux).Length
    $tamAt = (Get-Item -LiteralPath $at).Length

    $exe = Join-Path $Carpeta 'bundle.exe'
    New-PeDePrueba -Ruta $exe -BurnContenedores @($tamUx, $tamAt) -BurnFirma $Firma | Out-Null

    $fs = [System.IO.File]::Open($exe, 'Append')
    try {
        $bytes = [System.IO.File]::ReadAllBytes($ux); $fs.Write($bytes, 0, $bytes.Length)
        if ($Firma -gt 0) { $relleno = New-Object byte[] $Firma; $fs.Write($relleno, 0, $relleno.Length) }
        $bytes = [System.IO.File]::ReadAllBytes($at); $fs.Write($bytes, 0, $bytes.Length)
    }
    finally { $fs.Dispose() }

    return $exe
}

function New-MsiDePrueba {
    <#
        Un MSI con lo justo para Expand-MsiFiles: la tabla File y la tabla
        Media, creadas con la API de Windows Installer. El CAB lleva el archivo
        con su CLAVE como nombre, igual que en un MSI de verdad.
    #>
    param(
        [string]$Carpeta,
        [string]$Clave = 'F_CENTRAL_libreria_x86',
        [string]$NombreEnTabla = 'librer~1.dll|libreria.dll',
        [string]$Cabinet = 'cab1.cab',
        [string]$Contenido = 'soy la libreria'
    )

    $msi = Join-Path $Carpeta 'prueba.msi'
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $db = Invoke-ComMember $installer 'OpenDatabase' -Argumentos @($msi, 3)    # 3 = crear
    try {
        foreach ($sql in @(
            'CREATE TABLE `File` (`File` CHAR(72) NOT NULL, `FileName` CHAR(255) NOT NULL, `Sequence` SHORT NOT NULL PRIMARY KEY `File`)',
            'CREATE TABLE `Media` (`DiskId` SHORT NOT NULL, `LastSequence` SHORT NOT NULL, `Cabinet` CHAR(255) PRIMARY KEY `DiskId`)',
            "INSERT INTO ``File`` (``File``, ``FileName``, ``Sequence``) VALUES ('$Clave', '$NombreEnTabla', 1)",
            "INSERT INTO ``Media`` (``DiskId``, ``LastSequence``, ``Cabinet``) VALUES (1, 1, '$Cabinet')"
        )) {
            $v = Invoke-ComMember $db 'OpenView' -Argumentos @($sql)
            Invoke-ComMember $v 'Execute' | Out-Null
            Invoke-ComMember $v 'Close' | Out-Null
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($v)
        }
        Invoke-ComMember $db 'Commit' | Out-Null
    }
    finally {
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($db)
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($installer)
    }

    if (-not $Cabinet.StartsWith('#')) {
        $cab = New-CabDePrueba -Carpeta $Carpeta -Nombre $Clave -Contenido $Contenido
        Move-Item -LiteralPath $cab -Destination (Join-Path $Carpeta $Cabinet)
    }
    return $msi
}

Describe "Get-PeInfo" {

    $d = New-CarpetaTemporal

    It "reconoce un ejecutable de 32 bits y lo que importa" {
        $exe = Join-Path $d 'x86.exe'
        New-PeDePrueba -Ruta $exe -Arch x86 -Importa @('KERNEL32.dll', 'mfc110.dll') | Out-Null

        $i = Get-PeInfo -FilePath $exe
        $i.Arquitectura | Should Be 'x86'
        ($i.Importa -join ',') | Should Be 'KERNEL32.dll,mfc110.dll'
    }

    # En 64 bits el directorio de datos esta 16 bytes mas abajo. Leerlo en el
    # sitio de 32 daba importaciones basura en cualquier binario de 64.
    It "lee las importaciones de uno de 64 bits, que las guarda en otro sitio" {
        $exe = Join-Path $d 'x64.exe'
        New-PeDePrueba -Ruta $exe -Arch x64 -Importa @('msvcr110.dll', 'USER32.dll') | Out-Null

        $i = Get-PeInfo -FilePath $exe
        $i.Arquitectura | Should Be 'x64'
        ($i.Importa -join ',') | Should Be 'msvcr110.dll,USER32.dll'
    }

    It "reconoce arm64" {
        $exe = Join-Path $d 'arm.exe'
        New-PeDePrueba -Ruta $exe -Arch arm64 | Out-Null
        (Get-PeInfo -FilePath $exe).Arquitectura | Should Be 'arm64'
    }

    # Una DLL de carga diferida que falta da el mismo error, solo que mas
    # tarde: tambien cuenta como necesaria.
    It "incluye las DLL de carga diferida" {
        $exe = Join-Path $d 'diferida.exe'
        New-PeDePrueba -Ruta $exe -Importa @('KERNEL32.dll') -Diferidas @('msvcp110.dll') | Out-Null
        (Get-PeInfo -FilePath $exe).Importa -contains 'msvcp110.dll' | Should Be $true
    }

    It "no repite una DLL que aparece en las dos tablas" {
        $exe = Join-Path $d 'repetida.exe'
        New-PeDePrueba -Ruta $exe -Importa @('msvcr110.dll') -Diferidas @('MSVCR110.dll') | Out-Null
        @((Get-PeInfo -FilePath $exe).Importa).Count | Should Be 1
    }

    It "sin importaciones, la lista esta vacia" {
        $exe = Join-Path $d 'nada.exe'
        New-PeDePrueba -Ruta $exe | Out-Null
        @((Get-PeInfo -FilePath $exe).Importa).Count | Should Be 0
    }

    It "devuelve nulo para algo que no es un ejecutable" {
        $txt = Join-Path $d 'texto.exe'
        Set-Content -LiteralPath $txt -Value 'esto no es un ejecutable, aunque se llame asi'
        Get-PeInfo -FilePath $txt | Should Be $null
    }

    It "devuelve nulo para un ejecutable cortado" {
        $exe = Join-Path $d 'entero.exe'
        New-PeDePrueba -Ruta $exe | Out-Null
        $cortado = Join-Path $d 'cortado.exe'
        [System.IO.File]::WriteAllBytes($cortado, [byte[]]([System.IO.File]::ReadAllBytes($exe)[0..69]))
        Get-PeInfo -FilePath $cortado | Should Be $null
    }

    It "devuelve nulo si el archivo no existe" {
        Get-PeInfo -FilePath (Join-Path $d 'no-existe.exe') | Should Be $null
    }

    Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
}

Describe "Expand-BurnBundle" {

    It "saca la carga con su nombre y su carpeta" {
        $d = New-CarpetaTemporal
        try {
            $exe = New-BundleDePrueba -Carpeta $d -Contenido 'hola'
            $r = Expand-BurnBundle -Path $exe -DestDir (Join-Path $d 'salida')

            $r.Extraidas -join ',' | Should Be 'packages\cosa\cosa.msi'
            Get-Content -LiteralPath (Join-Path $d 'salida\packages\cosa\cosa.msi') -Raw | Should Be 'hola'
        }
        finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # EL FALLO QUE SI OCURRIO. Con los contenedores contados seguidos, este
    # bundle se lee 4096 bytes antes de tiempo y no encuentra el segundo.
    It "salta la firma original que queda entre contenedores" {
        $d = New-CarpetaTemporal
        try {
            $exe = New-BundleDePrueba -Carpeta $d -Contenido 'detras de la firma' -Firma 4096
            $r = Expand-BurnBundle -Path $exe -DestDir (Join-Path $d 'salida') 6>$null

            $r | Should Not Be $null
            Get-Content -LiteralPath (Join-Path $d 'salida\packages\cosa\cosa.msi') -Raw | Should Be 'detras de la firma'
        }
        finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "rechaza una carga que no coincide con su hash, y no la deja" {
        $d = New-CarpetaTemporal
        try {
            $exe = New-BundleDePrueba -Carpeta $d -Contenido 'lo de verdad' -Hash (Get-Sha1 'otra cosa')
            $r = Expand-BurnBundle -Path $exe -DestDir (Join-Path $d 'salida') 6>$null

            $r | Should Be $null
            Test-Path -LiteralPath (Join-Path $d 'salida\packages\cosa\cosa.msi') | Should Be $false
        }
        finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "rechaza una carga sin hash: sin comprobar no es lo mismo que correcta" {
        $d = New-CarpetaTemporal
        try {
            $exe = New-BundleDePrueba -Carpeta $d -Hash 'ZZ'
            Expand-BurnBundle -Path $exe -DestDir (Join-Path $d 'salida') 6>$null | Should Be $null
        }
        finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "rechaza una ruta que se sale de la carpeta destino" {
        $d = New-CarpetaTemporal
        try {
            $exe = New-BundleDePrueba -Carpeta $d -RutaCarga '..\fuera.txt'
            Expand-BurnBundle -Path $exe -DestDir (Join-Path $d 'salida') 6>$null | Should Be $null
            Test-Path -LiteralPath (Join-Path $d 'fuera.txt') | Should Be $false
        }
        finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "cuenta aparte las cargas que el bundle descarga al instalar" {
        $d = New-CarpetaTemporal
        try {
            $exe = New-BundleDePrueba -Carpeta $d -ConExterna
            $r = Expand-BurnBundle -Path $exe -DestDir (Join-Path $d 'salida')

            $r.Externas -join ',' | Should Be 'packages\web\web.msi'
            @($r.Extraidas).Count | Should Be 1
        }
        finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "un ejecutable normal no es un bundle" {
        $d = New-CarpetaTemporal
        try {
            $exe = Join-Path $d 'normal.exe'
            New-PeDePrueba -Ruta $exe | Out-Null
            Get-BurnContainerInfo -FilePath $exe | Should Be $null
            Expand-BurnBundle -Path $exe -DestDir (Join-Path $d 'salida') 6>$null | Should Be $null
        }
        finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe "Expand-ZipArchive" {

    function Get-Arbol {
        param([string]$Carpeta)
        @(Get-ChildItem -LiteralPath $Carpeta -Recurse -File | ForEach-Object {
            $_.FullName.Substring($Carpeta.Length + 1) + '=' + [IO.File]::ReadAllText($_.FullName)
        } | Sort-Object) -join ';'
    }

    It "saca archivos y carpetas, vacias incluidas" {
        $d = New-CarpetaTemporal
        try {
            $z = New-ZipDePrueba -Ruta (Join-Path $d 'a.zip') -Entradas ([ordered]@{ 'uno.txt' = '1'; 'sub/dos.txt' = '2'; 'vacia/' = $null })
            Expand-ZipArchive -Path $z -Destino (Join-Path $d 'x')
            Get-Arbol (Join-Path $d 'x') | Should Be 'sub\dos.txt=2;uno.txt=1'
            Test-Path -LiteralPath (Join-Path $d 'x\vacia') -PathType Container | Should Be $true
        }
        finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # Lo que pide VS Code al actualizarse: sus archivos nuevos, y su data\ (los
    # ajustes y extensiones del usuario, que no vienen en el zip) intacto.
    It "sustituye lo que trae el zip y respeta lo demas" {
        $d = New-CarpetaTemporal
        try {
            $x = Join-Path $d 'x'
            New-Item -ItemType Directory -Path (Join-Path $x 'data'), (Join-Path $x 'bin') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $x 'data\ajustes.json') -Value 'mios' -NoNewline
            Set-Content -LiteralPath (Join-Path $x 'bin\viejo.dll') -Value 'v1' -NoNewline
            Set-Content -LiteralPath (Join-Path $x 'Code.exe') -Value 'v1' -NoNewline

            $z = New-ZipDePrueba -Ruta (Join-Path $d 'a.zip') -Entradas ([ordered]@{ 'Code.exe' = 'v2'; 'bin/nuevo.dll' = 'v2' })
            Expand-ZipArchive -Path $z -Destino $x

            Get-Arbol $x | Should Be 'bin\nuevo.dll=v2;Code.exe=v2;data\ajustes.json=mios'
        }
        finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "-QuitarEnvoltorio sube un nivel lo que cuelga de una sola carpeta" {
        $d = New-CarpetaTemporal
        try {
            $z = New-ZipDePrueba -Ruta (Join-Path $d 'a.zip') -Entradas ([ordered]@{ 'jdk-21.0.12+8/' = $null; 'jdk-21.0.12+8/bin/java.exe' = 'j'; 'jdk-21.0.12+8/release' = 'r' })
            Expand-ZipArchive -Path $z -Destino (Join-Path $d 'jdk-21') -QuitarEnvoltorio
            Get-Arbol (Join-Path $d 'jdk-21') | Should Be 'bin\java.exe=j;release=r'
        }
        finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # La version anterior movia la unica carpeta y perdia los archivos sueltos
    # de la raiz. Si no TODO cuelga de una carpeta, no hay envoltorio que quitar.
    It "-QuitarEnvoltorio no quita nada si hay algo suelto en la raiz" {
        $d = New-CarpetaTemporal
        try {
            $z = New-ZipDePrueba -Ruta (Join-Path $d 'a.zip') -Entradas ([ordered]@{ 'LEEME.txt' = 'l'; 'app/a.exe' = 'a' })
            Expand-ZipArchive -Path $z -Destino (Join-Path $d 'x') -QuitarEnvoltorio
            Get-Arbol (Join-Path $d 'x') | Should Be 'app\a.exe=a;LEEME.txt=l'
        }
        finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "-QuitarEnvoltorio no quita nada si hay dos carpetas en la raiz" {
        $d = New-CarpetaTemporal
        try {
            $z = New-ZipDePrueba -Ruta (Join-Path $d 'a.zip') -Entradas ([ordered]@{ 'bin/a.exe' = 'a'; 'lib/b.jar' = 'b' })
            Expand-ZipArchive -Path $z -Destino (Join-Path $d 'x') -QuitarEnvoltorio
            Get-Arbol (Join-Path $d 'x') | Should Be 'bin\a.exe=a;lib\b.jar=b'
        }
        finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # Zip slip: un nombre con ..\ escribiria donde quisiera quien hizo el zip.
    It "una entrada que sale de la carpeta hace fallar todo, sin escribir nada" {
        $d = New-CarpetaTemporal
        try {
            $z = New-ZipDePrueba -Ruta (Join-Path $d 'a.zip') -Entradas ([ordered]@{ 'bien.txt' = 'b'; '../fuera.txt' = 'f' })
            { Expand-ZipArchive -Path $z -Destino (Join-Path $d 'x') } | Should Throw
            Test-Path -LiteralPath (Join-Path $d 'fuera.txt') | Should Be $false
            Test-Path -LiteralPath (Join-Path $d 'x') | Should Be $false
        }
        finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # Un fallo a mitad no puede dejar media instalacion en el destino, que la
    # siguiente ejecucion daria por buena. Aqui falla porque "a" es un archivo
    # y despues se pide "a\b.txt".
    It "si falla a mitad, el destino queda como estaba y no deja restos" {
        $d = New-CarpetaTemporal
        try {
            $x = Join-Path $d 'x'
            New-Item -ItemType Directory -Path $x -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $x 'previo.txt') -Value 'p' -NoNewline

            $z = New-ZipDePrueba -Ruta (Join-Path $d 'a.zip') -Entradas ([ordered]@{ 'a' = 'archivo'; 'a/b.txt' = 'b' })
            { Expand-ZipArchive -Path $z -Destino $x } | Should Throw

            Get-Arbol $x | Should Be 'previo.txt=p'
            @(Get-ChildItem -LiteralPath $d -Directory | Where-Object { $_.Name -like 'x.part-*' }).Count | Should Be 0
        }
        finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "al terminar bien no deja la carpeta temporal" {
        $d = New-CarpetaTemporal
        try {
            $z = New-ZipDePrueba -Ruta (Join-Path $d 'a.zip') -Entradas ([ordered]@{ 'uno.txt' = '1' })
            Expand-ZipArchive -Path $z -Destino (Join-Path $d 'x')
            Expand-ZipArchive -Path $z -Destino (Join-Path $d 'x')
            @(Get-ChildItem -LiteralPath $d -Directory).Name -join ',' | Should Be 'x'
        }
        finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # El guardian de que ya no queda ningun Expand-Archive: con uno solo, ese
    # camino volveria a tardar el doble y a mezclar versiones al reinstalar.
    It "ningun script del kit usa ya Expand-Archive" {
        $kit = Split-Path -Parent $PSScriptRoot
        $ps1 = @(Get-ChildItem -LiteralPath (Join-Path $kit 'lib'), (Join-Path $kit 'scripts') -Recurse -Filter *.ps1)
        $ps1.Count | Should BeGreaterThan 20
        # El patron tiene que casar con una llamada de verdad: la primera version
        # exigia un caracter ANTES del nombre y no habria visto ninguna.
        $patron = '^(?!\s*#).*\bExpand-Archive\s+-'
        '        Expand-Archive -Path $z -DestinationPath $d' | Should Match $patron
        '    # Expand-Archive -Path antiguo' | Should Not Match $patron

        $usos = @($ps1 | Select-String -Pattern $patron | ForEach-Object { "$($_.Filename):$($_.LineNumber)" })
        ($usos -join ', ') | Should Be ''
    }
}

Describe "Expand-TarArchive" {

    # Un .tar.gz de verdad, con el tar.exe de Windows: es como llega Python.
    function New-TarDePrueba {
        param([string]$Carpeta, [hashtable]$Archivos)
        $fuente = Join-Path $Carpeta 'fuente'
        foreach ($k in $Archivos.Keys) {
            $f = Join-Path $fuente $k
            New-Item -ItemType Directory -Path (Split-Path -Parent $f) -Force | Out-Null
            [IO.File]::WriteAllText($f, $Archivos[$k])
        }
        $tgz = Join-Path $Carpeta 'a.tar.gz'
        & "$env:SystemRoot\System32\tar.exe" -czf $tgz -C $fuente . 2>$null
        Remove-Item -LiteralPath $fuente -Recurse -Force
        return $tgz
    }

    function Get-Arbol {
        param([string]$Carpeta)
        @(Get-ChildItem -LiteralPath $Carpeta -Recurse -File | ForEach-Object {
            $_.FullName.Substring($Carpeta.Length + 1) + '=' + [IO.File]::ReadAllText($_.FullName)
        } | Sort-Object) -join ';'
    }

    It "-QuitarEnvoltorio sube el python\ de dentro un nivel" {
        $d = New-CarpetaTemporal
        try {
            $t = New-TarDePrueba -Carpeta $d -Archivos @{ 'python\python.exe' = 'p'; 'python\Lib\os.py' = 'o' }
            Expand-TarArchive -Path $t -Destino (Join-Path $d 'python-3.12') -QuitarEnvoltorio
            Get-Arbol (Join-Path $d 'python-3.12') | Should Be 'Lib\os.py=o;python.exe=p'
            @(Get-ChildItem -LiteralPath $d -Directory | Where-Object { $_.Name -like '*.part-*' }).Count | Should Be 0
        }
        finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "sin envoltorio que quitar, lo deja como viene" {
        $d = New-CarpetaTemporal
        try {
            $t = New-TarDePrueba -Carpeta $d -Archivos @{ 'a.txt' = '1'; 'b\c.txt' = '2' }
            Expand-TarArchive -Path $t -Destino (Join-Path $d 'x') -QuitarEnvoltorio
            Get-Arbol (Join-Path $d 'x') | Should Be 'a.txt=1;b\c.txt=2'
        }
        finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "un archivo que no es un tar falla y no toca el destino" {
        $d = New-CarpetaTemporal
        try {
            $malo = Join-Path $d 'malo.tar.gz'
            [IO.File]::WriteAllText($malo, 'no soy un tar')
            { Expand-TarArchive -Path $malo -Destino (Join-Path $d 'x') } | Should Throw
            Test-Path -LiteralPath (Join-Path $d 'x') | Should Be $false
            @(Get-ChildItem -LiteralPath $d -Directory).Count | Should Be 0
        }
        finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe "Expand-MsiFiles" {

    It "renombra cada archivo del CAB al nombre largo de la tabla File" {
        $d = New-CarpetaTemporal
        try {
            $msi = New-MsiDePrueba -Carpeta $d -Contenido 'soy la libreria'
            $n = Expand-MsiFiles -MsiPath $msi -DestDir (Join-Path $d 'salida')

            $n -join ',' | Should Be 'libreria.dll'
            Get-Content -LiteralPath (Join-Path $d 'salida\libreria.dll') -Raw | Should Be 'soy la libreria'
        }
        finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "acepta un nombre sin parte corta" {
        $d = New-CarpetaTemporal
        try {
            $msi = New-MsiDePrueba -Carpeta $d -NombreEnTabla 'corto.dll'
            (Expand-MsiFiles -MsiPath $msi -DestDir (Join-Path $d 'salida')) -join ',' | Should Be 'corto.dll'
        }
        finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "suelta el MSI al terminar: se puede borrar enseguida" {
        $d = New-CarpetaTemporal
        try {
            $msi = New-MsiDePrueba -Carpeta $d
            Expand-MsiFiles -MsiPath $msi -DestDir (Join-Path $d 'salida') | Out-Null
            { Remove-Item -LiteralPath $msi -ErrorAction Stop } | Should Not Throw
        }
        finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "rechaza un MSI que lleva el CAB dentro, en vez de devolver nada" {
        $d = New-CarpetaTemporal
        try {
            $msi = New-MsiDePrueba -Carpeta $d -Cabinet '#cab1.cab'
            Expand-MsiFiles -MsiPath $msi -DestDir (Join-Path $d 'salida') 6>$null | Should Be $null
        }
        finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "falla si el CAB no esta junto al MSI" {
        $d = New-CarpetaTemporal
        try {
            $msi = New-MsiDePrueba -Carpeta $d
            Remove-Item -LiteralPath (Join-Path $d 'cab1.cab')
            Expand-MsiFiles -MsiPath $msi -DestDir (Join-Path $d 'salida') 6>$null | Should Be $null
        }
        finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
