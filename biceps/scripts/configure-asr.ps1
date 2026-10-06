<#
    Fase 14 · Reglas ASR por GPO

    Las cinco reglas se despliegan en Audit. Auditar primero y bloquear despues
    permite medir que habria pasado antes de romper nada, y es lo que hace
    comparable el antes y el despues.

    Precedencia: Set-MpPreference es el metodo de menor prioridad y cualquier
    metodo basado en directivas lo sobrescribe al iniciar. Por eso la
    configuracion va por GPO y no por ajuste local.

    Dependencias reales de cada regla, que no son iguales para todas: solo la de
    scripts ofuscados exige proteccion en la nube y AMSI. Sin ellas esa regla no
    se aplica y no avisa de que no se aplica.

    Idempotente: reutiliza la GPO si ya existe y reescribe los valores.
#>
[CmdletBinding()]
param(
    [string] $NombreGpo = 'GPO-GDAT-ASR',

    # 0 Disabled | 1 Block | 2 Audit | 6 Warn
    [ValidateSet(0, 1, 2, 6)]
    [int] $Accion = 2,

    [string] $UoDestino = ''
)

$ErrorActionPreference = 'Stop'
Import-Module GroupPolicy
Import-Module ActiveDirectory

function Escribir($mensaje) {
    Write-Output ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $mensaje)
}

$reglas = [ordered]@{
    '9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2' = 'Robo de credenciales desde LSASS'
    'd1e49aac-8f56-4280-b9ba-993a6d77406c' = 'Procesos creados por PsExec y WMI'
    '5beb7efe-fd9a-4556-801d-275e5ffc04cc' = 'Ejecucion de scripts ofuscados'
    'e6db77e5-3df2-4cf1-b95a-636979351e5b' = 'Persistencia por suscripcion de eventos WMI'
    'c0033c00-d16d-4114-a5a0-dc9b3a7d2ceb' = 'Uso de herramientas del sistema copiadas'
}

$claveAsr = 'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Windows Defender Exploit Guard\ASR\Rules'
$claveRaiz = 'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Windows Defender Exploit Guard\ASR'

$gpo = Get-GPO -Name $NombreGpo -ErrorAction SilentlyContinue
if ($null -eq $gpo) {
    Escribir "Creando la GPO $NombreGpo."
    $gpo = New-GPO -Name $NombreGpo -Comment 'Reglas ASR del laboratorio GDAT.'
}
else {
    Escribir "La GPO $NombreGpo ya existe. Se reutiliza."
}

# ExploitGuard_ASR_Rules a 1 habilita el conjunto; sin el, los valores
# individuales no se aplican.
Set-GPRegistryValue -Name $NombreGpo -Key $claveRaiz `
    -ValueName 'ExploitGuard_ASR_Rules' -Type DWord -Value 1 | Out-Null

foreach ($guid in $reglas.Keys) {
    # DWord, no String. Con String la GPO se escribe pero el motor de ASR no
    # interpreta el valor y las reglas quedan sin aplicar.
    Set-GPRegistryValue -Name $NombreGpo -Key $claveAsr `
        -ValueName $guid -Type DWord -Value $Accion | Out-Null
    Escribir ("{0} -> accion {1}  ({2})" -f $guid, $Accion, $reglas[$guid])
}

# Se enlaza a la raiz del dominio, y esto es deliberado.
#
# La OU NovaShop contiene usuarios y grupos del escenario, no objetos de equipo:
# una maquina que se une al dominio aterriza en CN=Computers salvo que se la
# mueva. Enlazar ahi dejaria la GPO sin aplicarse a ningun endpoint, que es justo
# lo contrario de lo que se busca.
#
# Ademas este script corre en el controlador antes de que MEMBER01 exista. Solo
# un enlace en la raiz alcanza a los equipos que se unan despues.
#
# Que el controlador quede dentro del alcance no es un efecto secundario que
# moleste: ASR en un DC tambien protege.
$destino = if ([string]::IsNullOrWhiteSpace($UoDestino)) {
    (Get-ADDomain).DistinguishedName
}
else { $UoDestino }
$enlaces = (Get-GPInheritance -Target $destino).GpoLinks
if ($enlaces.DisplayName -notcontains $NombreGpo) {
    New-GPLink -Name $NombreGpo -Target $destino -LinkEnabled Yes | Out-Null
    Escribir "GPO enlazada a $destino."
}
else {
    Escribir "La GPO ya estaba enlazada."
}

gpupdate /force | Out-Null

# gpupdate aqui solo refresca el controlador. Cada endpoint tiene que refrescar
# el suyo, o quedara con la accion anterior mientras el DC ya muestra la nueva.
# Los equipos que ya existan se refrescan ahora. Los que se unan despues recogen
# la directiva en su primer arranque, porque el enlace esta en la raiz.
$otros = Get-ADComputer -Filter * | Select-Object -ExpandProperty Name |
    Where-Object { $_ -ne $env:COMPUTERNAME }

if ($otros) {
    Escribir "Refrescando la directiva en: $($otros -join ', ')"
    foreach ($equipo in $otros) {
        try {
            Invoke-GPUpdate -Computer $equipo -Force -RandomDelayInMinutes 0 -ErrorAction Stop
            Escribir "  $equipo refrescado."
        }
        catch {
            Escribir "  $equipo no respondio: $($_.Exception.Message). Recogera la GPO al arrancar."
        }
    }
}
else {
    Escribir "Todavia no hay mas equipos en el dominio. Los que se unan recogeran la GPO al arrancar."
}

Escribir "Comprobar EN CADA ENDPOINT, no en el DC:"
Escribir "  Get-MpPreference | Select-Object -ExpandProperty AttackSurfaceReductionRules_Actions"
