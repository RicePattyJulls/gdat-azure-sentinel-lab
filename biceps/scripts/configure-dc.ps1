<#
    Fase 5 · Promocion de DC01 a controlador de dominio
    Se ejecuta como runCommand desde dc.bicep.

    Idempotente: si el dominio ya existe, sale sin tocar nada. La promocion
    reinicia la maquina, asi que este script no debe hacer nada despues de
    llamar a Install-ADDSForest.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $NombreDominio,
    [Parameter(Mandatory = $true)] [string] $NetbiosDominio,
    [Parameter(Mandatory = $true)] [string] $PasswordDsrm,

    # WinThreshold es el nivel de Windows Server 2016 y es el ultimo que admiten
    # todas las versiones en produccion. Windows Server 2025 introduce el suyo,
    # que habilita funciones nuevas a cambio de no poder degradarse ni admitir
    # controladores anteriores. Se deja configurable y conservador por defecto.
    [ValidateSet('WinThreshold', 'WinServer2025')]
    [string] $NivelFuncional = 'WinThreshold'
)

$ErrorActionPreference = 'Stop'

function Escribir($mensaje) {
    Write-Output ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $mensaje)
}

# Puerta de idempotencia: si ya es DC, no hay nada que hacer.
$rol = (Get-WmiObject -Class Win32_ComputerSystem).DomainRole
if ($rol -eq 4 -or $rol -eq 5) {
    Escribir "La maquina ya es controlador de dominio. Nada que hacer."
    exit 0
}

Escribir "Instalando el rol AD-Domain-Services."
$resultado = Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
if (-not $resultado.Success) {
    throw "No se pudo instalar AD-Domain-Services."
}

Import-Module ADDSDeployment

$dsrm = ConvertTo-SecureString -String $PasswordDsrm -AsPlainText -Force

Escribir "Promocionando a controlador del bosque $NombreDominio. La maquina se reiniciara."

# -Force evita la confirmacion interactiva. El reinicio es intencionado: sin el,
# Kerberos y DNS no responden y la etapa siguiente fallaria de todos modos.
Install-ADDSForest `
    -DomainName $NombreDominio `
    -DomainNetbiosName $NetbiosDominio `
    -SafeModeAdministratorPassword $dsrm `
    -InstallDns:$true `
    -DomainMode $NivelFuncional `
    -ForestMode $NivelFuncional `
    -DatabasePath 'C:\Windows\NTDS' `
    -LogPath 'C:\Windows\NTDS' `
    -SysvolPath 'C:\Windows\SYSVOL' `
    -NoRebootOnCompletion:$false `
    -Force:$true
