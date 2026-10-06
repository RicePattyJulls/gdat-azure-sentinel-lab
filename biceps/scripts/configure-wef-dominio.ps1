<#
    Fase 15 · configuracion de DOMINIO y de los origenes WEF.

    Modo Dominio: se ejecuta en DC01 con una identidad de administrador del
    dominio; crea/converge la GPO y configura el propio DC como origen.
    Modo Origen: se ejecuta como SYSTEM en MEMBER01; aplica la GPO y concede a
    NETWORK SERVICE acceso al grupo LOCAL Event Log Readers.
#>
[CmdletBinding()]
param(
    [ValidateSet('Dominio', 'Origen')]
    [string] $Modo = 'Dominio',
    [string] $FqdnColector,
    [string] $NombreGpo = 'GPO-GDAT-WEF-Origenes',
    [string[]] $NombresOrigen = @('DC01', 'MEMBER01'),
    [string] $MarcaEjecucion = ''
)

$ErrorActionPreference = 'Stop'
Write-Output "Marca de convergencia WEF: $MarcaEjecucion"

function Escribir([string] $Mensaje) {
    Write-Output ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Mensaje)
}

function Invoke-Nativo {
    param(
        [Parameter(Mandatory)] [string] $Programa,
        [Parameter(Mandatory)] [string[]] $Argumentos,
        [int[]] $CodigosValidos = @(0)
    )

    $salida = & $Programa @Argumentos 2>&1
    $codigo = $LASTEXITCODE
    if ($codigo -notin $CodigosValidos) {
        throw "$Programa $($Argumentos -join ' ') termino con codigo $codigo. Salida: $($salida -join ' ')"
    }
    return @($salida)
}

function Configurar-OrigenLocal {
    Escribir "Concediendo al NETWORK SERVICE local acceso a Event Log Readers en $env:COMPUTERNAME."
    # Microsoft.PowerShell.LocalAccounts no esta disponible en controladores de
    # dominio. El proveedor WinNT resuelve el grupo BUILTIN tanto en DC como en
    # un miembro sin depender del idioma de la salida de net.exe.
    $grupoLectores = [ADSI] 'WinNT://./Event Log Readers,group'
    $adsPathNetworkService = 'WinNT://NT AUTHORITY/NETWORK SERVICE'
    $miembrosAntes = @($grupoLectores.psbase.Invoke('Members')) | ForEach-Object {
        $_.GetType().InvokeMember('AdsPath', 'GetProperty', $null, $_, $null)
    }
    if ($miembrosAntes -notcontains $adsPathNetworkService) {
        $grupoLectores.Add($adsPathNetworkService)
    }

    Invoke-Nativo -Programa "$env:SystemRoot\System32\gpupdate.exe" `
        -Argumentos @('/target:computer', '/force') | Out-Null

    $miembrosDespues = @($grupoLectores.psbase.Invoke('Members')) | ForEach-Object {
        $_.GetType().InvokeMember('AdsPath', 'GetProperty', $null, $_, $null)
    }
    if ($miembrosDespues -notcontains $adsPathNetworkService) {
        throw 'NETWORK SERVICE no pertenece al grupo local Event Log Readers.'
    }

    Set-Service -Name WinRM -StartupType Automatic
    Restart-Service -Name WinRM -Force
    if ((Get-Service -Name WinRM).Status -ne 'Running') {
        throw 'WinRM no quedo en ejecucion despues de reconstruir su token.'
    }

    # SubscriptionManager se refresca cada 60 segundos. Tres eventos espaciados
    # hacen que al menos uno nazca despues de que el cliente WEF se conecte; la
    # puerta en WEC01 exige despues una fila nueva de cada origen.
    foreach ($intento in 1..3) {
        Start-Sleep -Seconds 30
        Invoke-Nativo -Programa "$env:SystemRoot\System32\eventcreate.exe" -Argumentos @(
            '/t', 'INFORMATION', '/id', '100', '/l', 'APPLICATION', '/so', 'GDAT-WEF',
            '/d', "Validacion WEF $MarcaEjecucion intento $intento"
        ) | Out-Null
    }
    Escribir 'Origen configurado; WinRM se reinicio y no queda un reinicio pendiente.'
}

if ($Modo -eq 'Dominio') {
    if ([string]::IsNullOrWhiteSpace($FqdnColector)) {
        throw 'FqdnColector es obligatorio en modo Dominio.'
    }

    $identidad = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ($identidad -match '\$$' -or $identidad -eq 'NT AUTHORITY\SYSTEM') {
        throw "La GPO necesita una identidad de usuario de dominio; se esta ejecutando como $identidad."
    }

    Import-Module GroupPolicy -ErrorAction Stop
    Import-Module ActiveDirectory -ErrorAction Stop
    $dominio = Get-ADDomain -ErrorAction Stop

    $gpo = Get-GPO -Name $NombreGpo -ErrorAction SilentlyContinue
    if ($null -eq $gpo) {
        $gpo = New-GPO -Name $NombreGpo -Comment 'Origenes WEF del laboratorio GDAT.'
    }

    $subscriptionManager = "Server=http://${FqdnColector}:5985/wsman/SubscriptionManager/WEC,Refresh=60"
    Set-GPRegistryValue -Name $NombreGpo `
        -Key 'HKLM\SOFTWARE\Policies\Microsoft\Windows\EventLog\EventForwarding\SubscriptionManager' `
        -ValueName '1' -Type String -Value $subscriptionManager | Out-Null
    Set-GPRegistryValue -Name $NombreGpo `
        -Key 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WinRM\Service' `
        -ValueName 'AllowAutoConfig' -Type DWord -Value 1 | Out-Null
    Set-GPRegistryValue -Name $NombreGpo `
        -Key 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WinRM\Service' `
        -ValueName 'IPv4Filter' -Type String -Value '*' | Out-Null

    $enlaces = (Get-GPInheritance -Target $dominio.DistinguishedName).GpoLinks
    if ($enlaces.DisplayName -notcontains $NombreGpo) {
        New-GPLink -Name $NombreGpo -Target $dominio.DistinguishedName -LinkEnabled Yes | Out-Null
    }

    Set-GPPermission -Name $NombreGpo -TargetName 'Authenticated Users' `
        -TargetType Group -PermissionLevel GpoRead -Replace | Out-Null
    foreach ($origen in $NombresOrigen) {
        $cuentaEquipo = Get-ADComputer -Identity $origen -ErrorAction Stop
        Set-GPPermission -Name $NombreGpo -TargetName $cuentaEquipo.Name `
            -TargetType Computer -PermissionLevel GpoApply | Out-Null
    }

    $registro = Get-GPRegistryValue -Name $NombreGpo `
        -Key 'HKLM\SOFTWARE\Policies\Microsoft\Windows\EventLog\EventForwarding\SubscriptionManager' `
        -ValueName '1'
    if ($registro.Value -ne $subscriptionManager) {
        throw 'La GPO no conserva el SubscriptionManager solicitado.'
    }
    Escribir "GPO $NombreGpo verificada; colector $FqdnColector."
}

Configurar-OrigenLocal
