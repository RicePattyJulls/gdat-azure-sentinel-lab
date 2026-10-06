<#
    Puerta de validacion de la etapa A.
    Comprueba que el dominio responde de verdad, no que ARM haya terminado.

    dependsOn solo garantiza que el recurso se desplego. No demuestra que el DC
    reinicio ni que Kerberos, DNS y LDAP contestan. Este script consulta el
    estado real y termina con error al agotar el tiempo.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $NombreDominio,
    [int] $TimeoutSegundos = 1800,
    [int] $IntervaloSegundos = 20
)

$ErrorActionPreference = 'Stop'
$limite = (Get-Date).AddSeconds($TimeoutSegundos)

function Escribir($mensaje) {
    Write-Output ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $mensaje)
}

$puertos = @{ 'DNS' = 53; 'Kerberos' = 88; 'LDAP' = 389 }

while ((Get-Date) -lt $limite) {
    $fallos = @()

    foreach ($nombre in $puertos.Keys) {
        $ok = Test-NetConnection -ComputerName $NombreDominio -Port $puertos[$nombre] -InformationLevel Quiet -WarningAction SilentlyContinue
        if (-not $ok) { $fallos += "$nombre/$($puertos[$nombre])" }
    }

    if ($fallos.Count -eq 0) {
        try {
            $dominio = Get-ADDomain -Identity $NombreDominio -ErrorAction Stop
            Escribir "Dominio $($dominio.DNSRoot) operativo. DNS, Kerberos y LDAP responden."
            exit 0
        }
        catch {
            $fallos += "Get-ADDomain: $($_.Exception.Message)"
        }
    }

    Escribir ("Aun no listo: {0}. Reintentando en {1}s." -f ($fallos -join ', '), $IntervaloSegundos)
    Start-Sleep -Seconds $IntervaloSegundos
}

throw "El dominio $NombreDominio no respondio dentro de $TimeoutSegundos segundos."
