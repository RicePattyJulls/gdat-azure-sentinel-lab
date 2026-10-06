<#
    Fase 5 · Identidades del escenario y la cadena de escalada

    Cada cuenta existe por un motivo concreto:

      charlie.dev   puente entre la aplicacion web y el dominio. Su credencial
                    es la que se planta en la base de datos de NovaShop
      svc-sql       objetivo del Kerberoasting. Lleva un SPN registrado, que es
                    lo que permite pedir un ticket de servicio a su nombre
      svc-backup    escalon de permisos excesivos
      Server-Admins escalon intermedio de privilegio

    Las contrasenas llegan como parametros seguros. No se escriben en el script
    ni aparecen en el historial del despliegue.

    Idempotente: comprueba antes de crear y no duplica usuarios, grupos ni SPN.
#>
[CmdletBinding()]
param(
    [string] $NombreOu = 'NovaShop',
    [Parameter(Mandatory = $true)] [string] $PasswordNegocio,
    [Parameter(Mandatory = $true)] [string] $PasswordCharlie,
    [Parameter(Mandatory = $true)] [string] $PasswordSvcSql,
    [Parameter(Mandatory = $true)] [string] $PasswordSvcBackup
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

function Escribir($mensaje) {
    Write-Output ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $mensaje)
}

$dominio = Get-ADDomain
$ou = "OU=$NombreOu,$($dominio.DistinguishedName)"

if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$NombreOu'" -ErrorAction SilentlyContinue)) {
    New-ADOrganizationalUnit -Name $NombreOu -Path $dominio.DistinguishedName -ProtectedFromAccidentalDeletion $false
    Escribir "OU $NombreOu creada."
}
else {
    Escribir "OU $NombreOu ya existe."
}

function NuevoUsuario($sam, $password) {
    if (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue) {
        Escribir "Usuario $sam ya existe."
        return
    }
    New-ADUser -Name $sam -SamAccountName $sam `
        -UserPrincipalName "$sam@$($dominio.DNSRoot)" `
        -Path $ou `
        -AccountPassword (ConvertTo-SecureString $password -AsPlainText -Force) `
        -Enabled $true -PasswordNeverExpires $true
    Escribir "Usuario $sam creado."
}

foreach ($sam in @('alice.finance', 'bob.hr', 'david.sales', 'it.admin')) {
    NuevoUsuario $sam $PasswordNegocio
}
NuevoUsuario 'charlie.dev' $PasswordCharlie
NuevoUsuario 'svc-sql'     $PasswordSvcSql
NuevoUsuario 'svc-backup'  $PasswordSvcBackup

# El SPN es lo que convierte a svc-sql en objetivo kerberoasteable.
$spn = "MSSQLSvc/db01.$($dominio.DNSRoot):1433"
$actual = (Get-ADUser -Identity 'svc-sql' -Properties ServicePrincipalNames).ServicePrincipalNames
if ($actual -notcontains $spn) {
    Set-ADUser -Identity 'svc-sql' -ServicePrincipalNames @{ Add = $spn }
    Escribir "SPN $spn registrado sobre svc-sql."
}
else {
    Escribir "El SPN ya estaba registrado."
}

function NuevoGrupo($nombre) {
    if (Get-ADGroup -Filter "Name -eq '$nombre'" -ErrorAction SilentlyContinue) {
        Escribir "Grupo $nombre ya existe."
        return
    }
    New-ADGroup -Name $nombre -GroupScope Global -GroupCategory Security -Path $ou
    Escribir "Grupo $nombre creado."
}

NuevoGrupo 'IT-Support'
NuevoGrupo 'Server-Admins'

function AnadirMiembro($grupo, $miembro) {
    $miembros = Get-ADGroupMember -Identity $grupo | Select-Object -ExpandProperty SamAccountName
    if ($miembros -contains $miembro) {
        Escribir "$miembro ya pertenece a $grupo."
        return
    }
    Add-ADGroupMember -Identity $grupo -Members $miembro
    Escribir "$miembro anadido a $grupo."
}

AnadirMiembro 'IT-Support'    'charlie.dev'
AnadirMiembro 'Server-Admins' 'svc-sql'

# ---------------------------------------------------------------------------
# La ACE que sostiene la escalada
# ---------------------------------------------------------------------------
# WriteProperty solo sobre el atributo member es mas quirurgico que GenericAll:
# svc-sql podra cambiar la pertenencia del grupo y nada mas. Ese es exactamente
# el permiso excesivo que se quiere representar, y es lo que genera el 4728 que
# detecta la regla NRT.
#
# Domain Admins esta protegido por AdminSDHolder. SDProp compara los descriptores
# de los objetos protegidos y restaura los que difieren, por defecto cada 60
# minutos: esta ACE es deliberadamente efimera y hay que volver a aplicarla justo
# antes del ataque. Volver a ejecutar este script la repone.

$grupoDa = Get-ADGroup 'Domain Admins'
$svcSql = Get-ADUser 'svc-sql'
$rutaGrupo = "AD:\$($grupoDa.DistinguishedName)"

# GUID del atributo member. Es universal en cualquier Active Directory.
$guidMember = [GUID]'bf9679c0-0de6-11d0-a285-00aa003049e2'
$sidSvcSql = New-Object System.Security.Principal.SecurityIdentifier $svcSql.SID

$aclGrupo = Get-Acl -Path $rutaGrupo
$yaTiene = $aclGrupo.Access | Where-Object {
    $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -eq $sidSvcSql.Value -and
    $_.ObjectType -eq $guidMember -and
    $_.ActiveDirectoryRights -band [System.DirectoryServices.ActiveDirectoryRights]::WriteProperty
}

if ($yaTiene) {
    Escribir "svc-sql ya tiene WriteProperty sobre member de Domain Admins."
}
else {
    $reglaAcceso = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $sidSvcSql,
        [System.DirectoryServices.ActiveDirectoryRights]::WriteProperty,
        [System.Security.AccessControl.AccessControlType]::Allow,
        $guidMember
    )
    $aclGrupo.AddAccessRule($reglaAcceso)
    Set-Acl -Path $rutaGrupo -AclObject $aclGrupo
    Escribir "ACE plantada: svc-sql puede modificar la pertenencia de Domain Admins."
    Escribir "AVISO: SDProp la revierte en unos 60 minutos. Reponer antes del ataque."
}

Escribir "Identidades y cadena listas en $ou."
