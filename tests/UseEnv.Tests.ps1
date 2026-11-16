#Requires -Version 5.1
<#
    Pruebas de Use-Env frente a la politica de ejecucion de PowerShell.

    Existe por un caso real: en un equipo con la ejecucion de scripts
    deshabilitada, Use-Env enganchaba igual el perfil de PowerShell. El perfil
    pasaba a existir, cada terminal nueva abria con un error rojo, y el runtime
    seguia sin activarse en PowerShell.

    Nunca se toca el perfil ni el registro de verdad: Add-ProfileHook y
    Add-AutoRunHook se sustituyen por mocks, y la politica se le da hecha a
    Get-PersistedExecutionPolicy con -Ambitos.
#>

$KitRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $KitRoot "lib\Common.ps1")
. (Join-Path $PSScriptRoot "Helpers.ps1")

# Use-Env es un script ejecutable: se cargan solo sus funciones.
. ([scriptblock]::Create((Get-TextoDeFunciones -Script 'Use-Env.ps1' -Nombres @(
    'Write-PolicyWarning', 'Add-Hooks', 'Add-ProfileHook', 'Add-AutoRunHook'))))

Describe "Get-PersistedExecutionPolicy" {

    It "sin nada guardado, Windows aplica Restricted y bloquea el perfil" {
        $p = Get-PersistedExecutionPolicy -Ambitos @{ MachinePolicy = 'Undefined'; UserPolicy = 'Undefined'; CurrentUser = 'Undefined'; LocalMachine = 'Undefined' }
        $p.Politica | Should Be 'Restricted'
        $p.Origen | Should Be 'por defecto'
        $p.BloqueaPerfil | Should Be $true
        $p.DeGrupo | Should Be $false
    }

    It "RemoteSigned del usuario deja cargar el perfil" {
        $p = Get-PersistedExecutionPolicy -Ambitos @{ CurrentUser = 'RemoteSigned'; LocalMachine = 'Restricted' }
        $p.Politica | Should Be 'RemoteSigned'
        $p.Origen | Should Be 'CurrentUser'
        $p.BloqueaPerfil | Should Be $false
    }

    # El perfil del kit no va firmado, asi que AllSigned lo bloquea igual.
    It "AllSigned tambien bloquea el perfil" {
        (Get-PersistedExecutionPolicy -Ambitos @{ CurrentUser = 'AllSigned' }).BloqueaPerfil | Should Be $true
    }

    # La directiva de grupo manda aunque el usuario haya puesto otra cosa, y
    # eso cambia el consejo: no se arregla con Set-ExecutionPolicy.
    It "la directiva de grupo gana sobre lo que haya puesto el usuario" {
        $p = Get-PersistedExecutionPolicy -Ambitos @{ UserPolicy = 'Restricted'; CurrentUser = 'RemoteSigned' }
        $p.Politica | Should Be 'Restricted'
        $p.Origen | Should Be 'UserPolicy'
        $p.DeGrupo | Should Be $true
    }

    It "sin -Ambitos lee la de esta maquina sin fallar" {
        $p = Get-PersistedExecutionPolicy
        $p.Politica | Should Not BeNullOrEmpty
    }
}

Describe "Add-Hooks" {

    Mock Add-ProfileHook { }
    Mock Add-AutoRunHook { }
    Mock Write-Log { }

    $bloqueada = Get-PersistedExecutionPolicy -Ambitos @{ CurrentUser = 'Restricted' }
    $libre     = Get-PersistedExecutionPolicy -Ambitos @{ CurrentUser = 'RemoteSigned' }

    It "con la politica bloqueando, NO engancha el perfil de PowerShell" {
        $r = @(Add-Hooks -Politica $bloqueada)
        Assert-MockCalled Add-ProfileHook -Times 0 -Scope It
        ($r -join ',') | Should Be 'cmd'
    }

    It "con la politica bloqueando, cmd si se engancha" {
        Add-Hooks -Politica $bloqueada | Out-Null
        Assert-MockCalled Add-AutoRunHook -Times 1 -Scope It
    }

    It "con la politica bloqueando, avisa y dice como arreglarlo sin admin" {
        Add-Hooks -Politica $bloqueada | Out-Null
        Assert-MockCalled Write-Log -Scope It -ParameterFilter { $Message -match 'Set-ExecutionPolicy -Scope CurrentUser' }
    }

    It "si viene de una directiva de grupo no le manda a cambiarla" {
        $gpo = Get-PersistedExecutionPolicy -Ambitos @{ MachinePolicy = 'Restricted' }
        Add-Hooks -Politica $gpo | Out-Null
        Assert-MockCalled Write-Log -Scope It -Times 0 -ParameterFilter { $Message -match 'Set-ExecutionPolicy' }
        Assert-MockCalled Write-Log -Scope It -ParameterFilter { $Message -match 'IT' }
    }

    It "con -SinAviso no repite el aviso" {
        Add-Hooks -Politica $bloqueada -SinAviso | Out-Null
        Assert-MockCalled Write-Log -Times 0 -Scope It
    }

    It "con la politica libre engancha los dos" {
        $r = @(Add-Hooks -Politica $libre)
        Assert-MockCalled Add-ProfileHook -Times 1 -Scope It
        Assert-MockCalled Add-AutoRunHook -Times 1 -Scope It
        ($r -join ',') | Should Be 'PowerShell,cmd'
    }
}
