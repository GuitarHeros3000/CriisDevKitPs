#Requires -Version 5.1
<#
    Semver, lo justo para leer los campos "engines" de npm

    Parte de lib\Common.ps1, que es quien carga este archivo. No se toma
    por separado: los scripts siguen haciendo un unico dot-source de
    Common.ps1 y no se enteran de esta division.
#>

# --------------------------------------------------------------------------
# Semver (lo justo para leer campos "engines" de npm)
# --------------------------------------------------------------------------

function ConvertTo-SemverObject {
    param([Parameter(Mandatory=$true)][string]$Version)

    # Quita la 'v' inicial y cualquier sufijo de prerelease o build.
    $clean = $Version.Trim().TrimStart('v', 'V').Split('-')[0].Split('+')[0]
    $parts = @($clean.Split('.') | Where-Object { $_ -match '^\d+$' })
    while ($parts.Count -lt 3) { $parts += '0' }

    return [version]("{0}.{1}.{2}" -f $parts[0], $parts[1], $parts[2])
}

function Test-SemverComparator {
    param(
        [Parameter(Mandatory=$true)][version]$Version,
        [Parameter(Mandatory=$true)][string]$Comparator
    )

    $c = $Comparator.Trim()
    if ($c -eq '' -or $c -eq '*') { return $true }

    if ($c -match '^\^\s*(.+)$') {
        # ^X.Y.Z  =>  >= X.Y.Z  y  < (X+1).0.0
        $base  = ConvertTo-SemverObject $Matches[1]
        $upper = [version]("{0}.0.0" -f ($base.Major + 1))
        return ($Version -ge $base -and $Version -lt $upper)
    }
    if ($c -match '^~\s*(.+)$') {
        # ~X.Y.Z  =>  >= X.Y.Z  y  < X.(Y+1).0
        $base  = ConvertTo-SemverObject $Matches[1]
        $upper = [version]("{0}.{1}.0" -f $base.Major, ($base.Minor + 1))
        return ($Version -ge $base -and $Version -lt $upper)
    }
    if ($c -match '^>=\s*(.+)$') { return $Version -ge (ConvertTo-SemverObject $Matches[1]) }
    if ($c -match '^<=\s*(.+)$') { return $Version -le (ConvertTo-SemverObject $Matches[1]) }
    if ($c -match '^>\s*(.+)$')  { return $Version -gt (ConvertTo-SemverObject $Matches[1]) }
    if ($c -match '^<\s*(.+)$')  { return $Version -lt (ConvertTo-SemverObject $Matches[1]) }
    if ($c -match '^=\s*(.+)$')  { return $Version -eq (ConvertTo-SemverObject $Matches[1]) }

    # Comodines y versiones parciales: "20", "20.x", "20.*", "20.19", "20.19.x".
    # La forma "14.x" es de lo mas comun en un campo engines, y antes caia en el
    # ultimo return de esta funcion, que la trataba como version EXACTA: la 'x' se
    # descartaba al normalizar y "14.x" acababa significando "exactamente 14.0.0".
    # Cualquier Node 14.21 quedaba descartado y nadie se enteraba.
    if ($c -match '^v?(\d+)(?:\.(\d+|[xX*]))?(?:\.(\d+|[xX*]))?$') {
        $major = [int]$Matches[1]
        $minor = $Matches[2]
        $patch = $Matches[3]

        # Sin menor, o con comodin => toda la mayor:  >=X.0.0  <(X+1).0.0
        if ([string]::IsNullOrEmpty($minor) -or $minor -match '^[xX*]$') {
            return ($Version -ge [version]("{0}.0.0" -f $major) -and
                    $Version -lt [version]("{0}.0.0" -f ($major + 1)))
        }

        # Sin parche, o con comodin => toda la menor:  >=X.Y.0  <X.(Y+1).0
        if ([string]::IsNullOrEmpty($patch) -or $patch -match '^[xX*]$') {
            return ($Version -ge [version]("{0}.{1}.0" -f $major, [int]$minor) -and
                    $Version -lt [version]("{0}.{1}.0" -f $major, ([int]$minor + 1)))
        }

        return ($Version -eq [version]("{0}.{1}.{2}" -f $major, [int]$minor, [int]$patch))
    }

    # No se entiende. Se devuelve $false, que es lo conservador, pero quien llama
    # deberia haber avisado antes con Get-UnsupportedSemverComparators: fallar en
    # silencio aqui es como "14.x" paso desapercibido tanto tiempo.
    return $false
}

function Test-SemverComparatorSupported {
    <#
        Dice si Test-SemverComparator sabe interpretar este termino. Se mantiene
        al lado de la funcion anterior a proposito: si alli se anade una forma
        nueva, aqui hay que anadirla tambien o se avisara de algo que si funciona.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Comparator)

    $c = $Comparator.Trim()
    if ($c -eq '' -or $c -eq '*') { return $true }
    if ($c -match '^(\^|~|>=|<=|>|<|=)\s*v?\d') { return $true }
    if ($c -match '^v?\d+(\.(\d+|[xX*]))?(\.(\d+|[xX*]))?$') { return $true }
    return $false
}

function Get-UnsupportedSemverComparators {
    <#
    .SYNOPSIS
        Devuelve los terminos de un rango que Test-SemverRange no sabe leer.
    .DESCRIPTION
        Sirve para avisar UNA vez, antes de usar el rango, en vez de que
        Test-SemverRange devuelva $false en silencio por cada version candidata.

        Lo tipico que aparece aqui es un rango con guion ("1.2 - 1.5"), que sigue
        sin soportarse. Si algun dia un campo engines lo usara, el usuario vera el
        aviso y podra forzar la version a mano en vez de quedarse sin entender por
        que el kit eligio lo que eligio.
    .EXAMPLE
        Get-UnsupportedSemverComparators -Range '^20.19.0 || 1.2 - 1.5'
        # -1.2, -, 1.5  ->  se avisa del guion
    #>
    param([Parameter(Mandatory=$true)][string]$Range)

    $raros = @()
    foreach ($branch in ($Range -split '\|\|')) {
        foreach ($c in @($branch.Trim() -split '\s+' | Where-Object { $_ -ne '' })) {
            if (-not (Test-SemverComparatorSupported -Comparator $c)) { $raros += $c }
        }
    }
    return @($raros | Select-Object -Unique)
}

function Test-SemverRange {
    <#
    .SYNOPSIS
        Comprueba si una version cumple un rango semver de npm.
    .DESCRIPTION
        Soporta lo que usan los campos "engines" en la practica: ^, ~, >=, <=,
        >, <, versiones exactas, alternativas con || y conjunciones separadas
        por espacio (">=18.0.0 <21.0.0").
        No implementa semver completo: no cubre rangos con guion ("1.2 - 1.5")
        ni comodines parciales ("1.x").
    .EXAMPLE
        Test-SemverRange -Version "20.20.2" -Range "^22.22.3 || ^24.15.0 || >=26.0.0"
        # False
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Version,
        [Parameter(Mandatory=$true)][string]$Range
    )

    $v = ConvertTo-SemverObject $Version

    foreach ($branch in ($Range -split '\|\|')) {
        $comparators = @($branch.Trim() -split '\s+' | Where-Object { $_ -ne '' })
        if ($comparators.Count -eq 0) { continue }

        $all = $true
        foreach ($c in $comparators) {
            if (-not (Test-SemverComparator -Version $v -Comparator $c)) {
                $all = $false
                break
            }
        }
        if ($all) { return $true }
    }

    return $false
}
