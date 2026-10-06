<#
    Fase 5 · Auditoria del dominio, y la SACL que el evento 4662 necesita

    Dos piezas con papeles distintos, y hacen falta las dos:

      1. La GPO enciende las subcategorias de auditoria.
      2. La SACL del objeto de dominio decide QUE objeto y QUE operacion se
         auditan.

    Sin la SACL no existe ningun 4662, aunque Directory Service Access este
    activa. Esa es la razon por la que una regla de DCSync sobre el 4662 puede
    quedarse sin datos indefinidamente.

    Los GUID de subcategoria no se escriben a mano: se leen de la propia maquina
    con auditpol, para que un nombre mal recordado no genere un CSV invalido.

    Idempotente: la GPO se reutiliza si existe y la regla de auditoria no se
    duplica si ya esta puesta.
#>
[CmdletBinding()]
param(
    [string] $NombreGpo = 'GPO-GDAT-Auditing'
)

$ErrorActionPreference = 'Stop'
Import-Module GroupPolicy
Import-Module ActiveDirectory

function Escribir($mensaje) {
    Write-Output ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $mensaje)
}

# ---------------------------------------------------------------------------
# 1. Subcategorias de auditoria, con sus GUID leidos de la maquina
# ---------------------------------------------------------------------------

$subcategorias = @(
    'Directory Service Access'
    'Process Creation'
    'Logon'
    'Logoff'
    'Special Logon'
    'Credential Validation'
    'Kerberos Authentication Service'
    'Kerberos Service Ticket Operations'
    'File Share'
    'Detailed File Share'
    'Security Group Management'
    'User Account Management'
)

# GUID de respaldo. Son constantes de Windows y no cambian entre versiones, pero
# se prefiere siempre lo que diga la maquina: si el SO conoce la subcategoria, su
# GUID manda sobre esta tabla.
$respaldo = @{
    'Directory Service Access'           = '{0CCE923B-69AE-11D9-BED3-505054503030}'
    'Process Creation'                   = '{0CCE922B-69AE-11D9-BED3-505054503030}'
    'Logon'                              = '{0CCE9215-69AE-11D9-BED3-505054503030}'
    'Logoff'                             = '{0CCE9216-69AE-11D9-BED3-505054503030}'
    'Special Logon'                      = '{0CCE9212-69AE-11D9-BED3-505054503030}'
    'Credential Validation'              = '{0CCE923F-69AE-11D9-BED3-505054503030}'
    'Kerberos Authentication Service'    = '{0CCE9242-69AE-11D9-BED3-505054503030}'
    'Kerberos Service Ticket Operations' = '{0CCE9240-69AE-11D9-BED3-505054503030}'
    'File Share'                         = '{0CCE9224-69AE-11D9-BED3-505054503030}'
    'Detailed File Share'                = '{0CCE9244-69AE-11D9-BED3-505054503030}'
    'Security Group Management'          = '{0CCE9237-69AE-11D9-BED3-505054503030}'
    'User Account Management'            = '{0CCE9235-69AE-11D9-BED3-505054503030}'
}

Escribir "Leyendo el catalogo de subcategorias de la maquina."
$catalogo = @{}

# El formato de salida de auditpol varia entre versiones y con el idioma del SO:
# con /r antepone el nombre de maquina, sin /r usa texto con sangria. En vez de
# asumir una posicion de columna, se busca el GUID en cualquier parte de la linea
# y se toma como nombre lo que queda al quitarlo.
$patronGuid = '\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}'

foreach ($intento in @('/r', '')) {
    $lineas = if ($intento) {
        auditpol /list /subcategory:* /v /r 2>$null
    } else {
        auditpol /list /subcategory:* /v 2>$null
    }

    foreach ($linea in $lineas) {
        if ($linea -notmatch $patronGuid) { continue }
        $guid = ([regex]::Match($linea, $patronGuid)).Value

        # Nombre = la linea sin el GUID, sin comillas, comas ni sangria.
        $nombre = ($linea -replace [regex]::Escape($guid), '').Trim().Trim(',').Trim('"').Trim()
        # Con /r la primera columna es el nombre de maquina: se descarta.
        if ($nombre -like "*,*") {
            $nombre = ($nombre -split ',')[-1].Trim().Trim('"')
        }
        if ($nombre) { $catalogo[$nombre] = $guid }
    }

    if ($catalogo.Count -gt 0) { break }
}

if ($catalogo.Count -eq 0) {
    # No se aborta: los GUID de subcategoria son constantes conocidas y la GPO
    # puede construirse igual. Tumbar aqui el despliegue entero seria peor.
    Escribir "AVISO: auditpol no devolvio subcategorias legibles. Se usa la tabla de respaldo."
    $catalogo = $respaldo
}
else {
    Escribir "Catalogo leido de la maquina: $($catalogo.Count) subcategorias."
}

$filas = @('Machine Name,Policy Target,Subcategory,Subcategory GUID,Inclusion Setting,Exclusion Setting,Setting Value')
$noEncontradas = @()

foreach ($sub in $subcategorias) {
    $guid = $null
    if ($catalogo.ContainsKey($sub))      { $guid = $catalogo[$sub] }
    elseif ($respaldo.ContainsKey($sub))  { $guid = $respaldo[$sub] }

    if ($guid) {
        # Setting Value 3 = Success and Failure
        $filas += ",System,Audit $sub,$guid,Success and Failure,,3"
    }
    else {
        $noEncontradas += $sub
    }
}

if ($filas.Count -le 1) {
    throw "No se pudo resolver ninguna subcategoria de auditoria. La GPO quedaria vacia."
}

if ($noEncontradas.Count -gt 0) {
    Escribir ("AVISO. Subcategorias no encontradas en este SO: {0}" -f ($noEncontradas -join ', '))
}

# ---------------------------------------------------------------------------
# 2. La GPO
# ---------------------------------------------------------------------------

$gpo = Get-GPO -Name $NombreGpo -ErrorAction SilentlyContinue
if ($null -eq $gpo) {
    Escribir "Creando la GPO $NombreGpo."
    $gpo = New-GPO -Name $NombreGpo -Comment 'Auditoria avanzada del laboratorio GDAT.'
}
else {
    Escribir "La GPO $NombreGpo ya existe. Se reutiliza."
}

$dominio = Get-ADDomain
$rutaAudit = "\\$($dominio.DNSRoot)\SYSVOL\$($dominio.DNSRoot)\Policies\{$($gpo.Id)}\Machine\Microsoft\Windows NT\Audit"
if (-not (Test-Path $rutaAudit)) {
    New-Item -Path $rutaAudit -ItemType Directory -Force | Out-Null
}

$filas | Set-Content -Path (Join-Path $rutaAudit 'audit.csv') -Encoding ASCII
Escribir "audit.csv escrito con $($filas.Count - 1) subcategorias."

# ---------------------------------------------------------------------------
# Registrar la extension de cliente y subir la version
# ---------------------------------------------------------------------------
# Escribir audit.csv en SYSVOL no basta. El motor de directivas solo invoca las
# extensiones cuyos GUID figuran en gPCMachineExtensionNames del objeto de GPO,
# y solo reprocesa cuando la version cambia. Sin las dos cosas el fichero se
# queda en SYSVOL y auditpol no refleja nada, por mucho gpupdate /force que se
# lance.

$guidCseAudit  = '{F3CCC681-B74C-4060-9F26-CD84525DCA2A}'
$guidToolAudit = '{0F3F3735-573D-9804-99E4-AB2A69BA5FD4}'
$parAudit = "[$guidCseAudit$guidToolAudit]"

$objetoGpo = Get-ADObject -Identity "CN={$($gpo.Id)},CN=Policies,CN=System,$($dominio.DistinguishedName)" `
    -Properties gPCMachineExtensionNames, versionNumber

$extensiones = $objetoGpo.gPCMachineExtensionNames
if ([string]::IsNullOrWhiteSpace($extensiones)) { $extensiones = '' }

if ($extensiones -like "*$guidCseAudit*") {
    Escribir "La extension de Advanced Audit Policy ya estaba registrada."
}
else {
    # Los pares se ordenan alfabeticamente por GUID de CSE. Se conserva lo que
    # ya hubiera: sobrescribir el atributo desactivaria otras extensiones.
    $pares = @()
    if ($extensiones -match '\[') {
        $pares = [regex]::Matches($extensiones, '\[[^\]]+\]') | ForEach-Object { $_.Value }
    }
    $pares += $parAudit
    $nuevo = ($pares | Sort-Object) -join ''

    Set-ADObject -Identity $objetoGpo.DistinguishedName -Replace @{ gPCMachineExtensionNames = $nuevo }
    Escribir "Extension de Advanced Audit Policy registrada en el GPO."
}

# La version del objeto en AD y la del GPT.INI en SYSVOL tienen que coincidir y
# subir, o el cliente considera que no hay nada nuevo que aplicar.
$objetoGpo = Get-ADObject -Identity $objetoGpo.DistinguishedName -Properties versionNumber
$versionActual = [int]$objetoGpo.versionNumber

# La parte alta del entero es la version de usuario, la baja la de equipo.
$versionUsuario = $versionActual -shr 16
$versionEquipo = ($versionActual -band 0xFFFF) + 1
$versionNueva = ($versionUsuario -shl 16) -bor $versionEquipo

Set-ADObject -Identity $objetoGpo.DistinguishedName -Replace @{ versionNumber = $versionNueva }

$rutaGpt = "\\$($dominio.DNSRoot)\SYSVOL\$($dominio.DNSRoot)\Policies\{$($gpo.Id)}\GPT.INI"
@(
    '[General]'
    "Version=$versionNueva"
) | Set-Content -Path $rutaGpt -Encoding ASCII

Escribir "Version del GPO sincronizada: $versionActual -> $versionNueva."

# Enlazar la GPO a la raiz del dominio si no lo esta ya.
$enlaces = (Get-GPInheritance -Target $dominio.DistinguishedName).GpoLinks
if ($enlaces.DisplayName -notcontains $NombreGpo) {
    New-GPLink -Name $NombreGpo -Target $dominio.DistinguishedName -LinkEnabled Yes | Out-Null
    Escribir "GPO enlazada a $($dominio.DistinguishedName)."
}
else {
    Escribir "La GPO ya estaba enlazada al dominio."
}

# ---------------------------------------------------------------------------
# 3. La SACL de replicacion en el objeto de dominio
# ---------------------------------------------------------------------------
# Sin esto el 4662 no se emite nunca. Los dos derechos extendidos son los que
# usa un DCSync: el segundo es el que permite replicar secretos.

$derechos = @{
    'DS-Replication-Get-Changes'     = [GUID]'1131f6aa-9c07-11d1-f79f-00c04fc2dcd2'
    'DS-Replication-Get-Changes-All' = [GUID]'1131f6ad-9c07-11d1-f79f-00c04fc2dcd2'
}

$rutaDominio = "AD:\$($dominio.DistinguishedName)"
$acl = Get-Acl -Path $rutaDominio -Audit

# S-1-1-0 es Everyone. La SACL audita el uso del derecho venga de quien venga;
# el filtrado de las cuentas legitimas se hace despues, en la consulta KQL.
$todos = New-Object System.Security.Principal.SecurityIdentifier('S-1-1-0')

$anadidas = 0
foreach ($nombre in $derechos.Keys) {
    $guid = $derechos[$nombre]

    $yaEsta = $acl.GetAuditRules($true, $true, [System.Security.Principal.SecurityIdentifier]) |
        Where-Object {
            $_.ObjectType -eq $guid -and
            $_.IdentityReference.Value -eq $todos.Value -and
            $_.AuditFlags -band [System.Security.AccessControl.AuditFlags]::Success
        }

    if ($yaEsta) {
        Escribir "La auditoria de $nombre ya estaba puesta."
        continue
    }

    $regla = New-Object System.DirectoryServices.ActiveDirectoryAuditRule(
        $todos,
        [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight,
        [System.Security.AccessControl.AuditFlags]::Success,
        $guid,
        [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None
    )
    $acl.AddAuditRule($regla)
    $anadidas++
    Escribir "Anadida auditoria de $nombre."
}

if ($anadidas -gt 0) {
    Set-Acl -Path $rutaDominio -AclObject $acl
    Escribir "SACL aplicada sobre $($dominio.DistinguishedName)."
}

gpupdate /force | Out-Null

Escribir "Comprobando que la directiva de auditoria se aplico de verdad."
$efectiva = auditpol /get /subcategory:"Directory Service Access" /r 2>$null | Select-Object -Skip 1
if ($efectiva -match 'Success') {
    Escribir "Directory Service Access activa en este equipo."
}
else {
    Escribir "AVISO: la subcategoria no aparece activa. Revisar el log"
    Escribir "  Microsoft-Windows-Security-Audit-Configuration-Client/Operational"
}

Escribir "Listo. Comprobar despues de un DCSync: SecurityEvent | where EventID == 4662"
