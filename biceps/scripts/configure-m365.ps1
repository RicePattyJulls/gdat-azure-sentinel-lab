<#
    Fase 2 · configuracion convergente de Microsoft 365.

    Se ejecuta desde una sesion de usuario, nunca como runCommand/SYSTEM. Graph
    y Exchange Online abren sesiones separadas y ambas se atan al tenant
    solicitado antes de modificar nada.

    Secretos (solo para el modo de aplicacion):
      GDAT_PWD_NEGOCIO   contrasena de altas nuevas excepto charlie.dev
      GDAT_PWD_CHARLIE   contrasena separada que converge charlie.dev
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Dominio,
    [string] $TenantId = '',
    [string] $ExchangeUserPrincipalName = '',
    [string] $UbicacionUso = 'ES',
    [string] $Ciudad = 'Madrid',
    [string] $Pais = 'Spain',
    [ValidateSet('SPE_E5', 'ENTERPRISEPREMIUM')]
    [string] $SkuE5 = 'SPE_E5',
    [ValidateSet('Standard', 'Strict')]
    [string] $PresetMdo = 'Standard',
    [switch] $SoloComprobar,
    [switch] $SaltarMdo
)

$ErrorActionPreference = 'Stop'

function Escribir([string] $Mensaje) {
    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Mensaje)
}

function Titulo([string] $Texto) {
    Write-Host ''
    Write-Host ("== $Texto " + ('=' * [Math]::Max(0, 62 - $Texto.Length))) -ForegroundColor Cyan
}

function Esperar-Condicion {
    param(
        [Parameter(Mandatory)] [scriptblock] $Condicion,
        [Parameter(Mandatory)] [string] $Descripcion,
        [int] $TimeoutSegundos = 600,
        [int] $IntervaloSegundos = 15
    )
    $limite = (Get-Date).AddSeconds($TimeoutSegundos)
    do {
        if (& $Condicion) { return }
        Start-Sleep -Seconds $IntervaloSegundos
    } while ((Get-Date) -lt $limite)
    throw "Timeout esperando: $Descripcion."
}

function Obtener-DominiosReglaMdo {
    param([AllowNull()] $Regla)

    return @(
        @($Regla.RecipientDomainIs) |
            Where-Object { $null -ne $_ } |
            ForEach-Object { $_.ToString() }
    )
}

$identidades = @(
    @{ Alias = 'alice.finance'; Nombre = 'Alice';   Apellido = 'Finance'; Cargo = 'Financial Analyst';      Departamento = 'Finance'     }
    @{ Alias = 'bob.hr';        Nombre = 'Bob';     Apellido = 'HR';      Cargo = 'HR Specialist';          Departamento = 'HR'          }
    @{ Alias = 'charlie.dev';   Nombre = 'Charlie'; Apellido = 'Dev';     Cargo = 'Software Developer';     Departamento = 'Development' }
    @{ Alias = 'david.sales';   Nombre = 'David';   Apellido = 'Sales';   Cargo = 'Sales Representative';   Departamento = 'Sales'       }
    @{ Alias = 'it.admin';      Nombre = 'IT';      Apellido = 'Admin';   Cargo = 'Systems Administrator';  Departamento = 'IT'          }
    @{ Alias = 'svc-backup';    Nombre = 'SVC';     Apellido = 'Backup';  Cargo = 'Backup Service Account'; Departamento = 'Security'    }
)

Titulo '0. Prerrequisitos locales'
$modulos = @(
    'Microsoft.Graph.Authentication'
    'Microsoft.Graph.Users'
    'Microsoft.Graph.Users.Actions'
    'Microsoft.Graph.Identity.DirectoryManagement'
)
if (-not $SaltarMdo) { $modulos += 'ExchangeOnlineManagement' }

$ausentes = @($modulos | Where-Object { -not (Get-Module -ListAvailable -Name $_) })
if ($ausentes.Count -gt 0 -and $SoloComprobar) {
    throw "-SoloComprobar no instala modulos. Instala antes: Install-Module $($ausentes -join ', ') -Scope CurrentUser"
}
foreach ($modulo in $ausentes) {
    Escribir "Instalando $modulo para el usuario actual."
    Install-Module -Name $modulo -Scope CurrentUser -Force -AllowClobber
}
foreach ($modulo in $modulos) {
    Import-Module $modulo -ErrorAction Stop
}

$graphConectado = $false
$exchangeConectado = $false
$passwordNegocio = $null
$passwordCharlie = $null

try {
    Titulo '1. Sesiones y tenant'
    if (Get-MgContext -ErrorAction SilentlyContinue) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }
    $tenantDestino = if ($TenantId) { $TenantId } else { $Dominio }
    $scopesGraph = if ($SoloComprobar) {
        @('User.Read.All', 'Organization.Read.All', 'Directory.Read.All')
    }
    else {
        @(
            'User.ReadWrite.All'
            'User-PasswordProfile.ReadWrite.All'
            'Organization.Read.All'
            'Directory.Read.All'
        )
    }
    Connect-MgGraph -TenantId $tenantDestino -Scopes $scopesGraph -NoWelcome
    $graphConectado = $true

    $contexto = Get-MgContext
    if (-not $contexto -or [string]::IsNullOrWhiteSpace($contexto.TenantId) -or
        [string]::IsNullOrWhiteSpace($contexto.Account)) {
        throw 'La sesion de Graph no tiene tenant y cuenta de usuario verificables.'
    }
    $dominiosTenant = @((Get-MgDomain -All -ErrorAction Stop).Id)
    if ($dominiosTenant -notcontains $Dominio) {
        throw "Graph abrio otro tenant. $Dominio no esta entre: $($dominiosTenant -join ', ')."
    }
    Escribir "Graph verificado: $($contexto.Account), tenant $($contexto.TenantId)."

    $reglasMdo = @{}
    if (-not $SaltarMdo) {
        if ([string]::IsNullOrWhiteSpace($ExchangeUserPrincipalName)) {
            $ExchangeUserPrincipalName = $contexto.Account
        }
        Connect-ExchangeOnline -Organization $Dominio `
            -UserPrincipalName $ExchangeUserPrincipalName -ShowBanner:$false
        $exchangeConectado = $true

        $dominiosExchange = @((Get-AcceptedDomain -ErrorAction Stop).DomainName | ForEach-Object { $_.ToString() })
        if ($dominiosExchange -notcontains $Dominio) {
            throw "Exchange Online abrio otro tenant. $Dominio no esta entre: $($dominiosExchange -join ', ')."
        }
        Escribir "Exchange Online verificado: $Dominio."

        $nombrePreset = "$PresetMdo Preset Security Policy"
        foreach ($tipo in @('EOP', 'ATP')) {
            $regla = & "Get-${tipo}ProtectionPolicyRule" -Identity $nombrePreset -ErrorAction SilentlyContinue
            if (-not $regla) {
                throw "Activa primero '$nombrePreset' en security.microsoft.com > Email & collaboration > Policies & rules > Threat policies > Preset Security Policies y vuelve a ejecutar. Microsoft no admite crear manualmente esa regla $tipo."
            }
            $reglasMdo[$tipo] = $regla
        }
    }

    Titulo '2. Preflight de usuarios y licencia E5'
    $usuarios = @{}
    foreach ($id in $identidades) {
        $upn = "$($id.Alias)@$Dominio"
        $usuarios[$id.Alias] = Get-MgUser -Filter "userPrincipalName eq '$upn'" `
            -Property 'id,accountEnabled,displayName,givenName,surname,userPrincipalName,mailNickname,jobTitle,department,city,country,usageLocation,assignedLicenses' `
            -ErrorAction Stop | Select-Object -First 1
    }

    $sku = Get-MgSubscribedSku -All | Where-Object { $_.SkuPartNumber -eq $SkuE5 } | Select-Object -First 1
    if (-not $sku) {
        throw "El tenant no contiene el SKU requerido $SkuE5. No se sustituye por otra licencia."
    }
    $pendientesLicencia = @($identidades | Where-Object {
        $actual = $usuarios[$_.Alias]
        -not $actual -or $actual.AssignedLicenses.SkuId -notcontains $sku.SkuId
    }).Count
    $libres = $sku.PrepaidUnits.Enabled - $sku.ConsumedUnits
    if ($libres -lt $pendientesLicencia) {
        throw "SKU ${SkuE5}: hacen falta $pendientesLicencia licencias y solo hay $libres libres. No se inicia una convergencia parcial."
    }
    Escribir "SKU exacto $SkuE5 verificado: $libres libres; $pendientesLicencia asignaciones pendientes."

    if (-not $SoloComprobar) {
        $faltanNoCharlie = @($identidades | Where-Object {
            $_.Alias -ne 'charlie.dev' -and -not $usuarios[$_.Alias]
        }).Count -gt 0
        if ($faltanNoCharlie) {
            $passwordNegocio = [Environment]::GetEnvironmentVariable('GDAT_PWD_NEGOCIO')
            if ([string]::IsNullOrWhiteSpace($passwordNegocio)) {
                throw 'Falta GDAT_PWD_NEGOCIO para crear los usuarios ausentes.'
            }
        }
        $passwordCharlie = [Environment]::GetEnvironmentVariable('GDAT_PWD_CHARLIE')
        if ([string]::IsNullOrWhiteSpace($passwordCharlie)) {
            throw 'Falta GDAT_PWD_CHARLIE: charlie.dev usa una credencial separada y se converge tambien si ya existe.'
        }
    }

    Titulo '3. Convergencia de usuarios'
    foreach ($id in $identidades) {
        $upn = "$($id.Alias)@$Dominio"
        $actual = $usuarios[$id.Alias]
        $deseado = [ordered]@{
            accountEnabled = $true
            displayName = "$($id.Nombre) $($id.Apellido)"
            givenName = $id.Nombre
            surname = $id.Apellido
            mailNickname = $id.Alias
            jobTitle = $id.Cargo
            department = $id.Departamento
            city = $Ciudad
            country = $Pais
            usageLocation = $UbicacionUso
        }

        if (-not $actual) {
            Escribir "  FALTA $upn."
            if (-not $SoloComprobar) {
                $password = if ($id.Alias -eq 'charlie.dev') { $passwordCharlie } else { $passwordNegocio }
                New-MgUser -BodyParameter (@{
                    accountEnabled = $true
                    displayName = $deseado.displayName
                    givenName = $deseado.givenName
                    surname = $deseado.surname
                    userPrincipalName = $upn
                    mailNickname = $deseado.mailNickname
                    jobTitle = $deseado.jobTitle
                    department = $deseado.department
                    city = $deseado.city
                    country = $deseado.country
                    usageLocation = $deseado.usageLocation
                    passwordProfile = @{
                        password = $password
                        forceChangePasswordNextSignIn = $false
                        forceChangePasswordNextSignInWithMfa = $false
                    }
                }) | Out-Null
                Escribir "  CREADO $upn."
            }
        }
        else {
            $cambios = @{}
            foreach ($propiedad in $deseado.Keys) {
                $nombrePs = switch ($propiedad) {
                    'accountEnabled' { 'AccountEnabled' }
                    'displayName' { 'DisplayName' }
                    'givenName' { 'GivenName' }
                    'surname' { 'Surname' }
                    'mailNickname' { 'MailNickname' }
                    'jobTitle' { 'JobTitle' }
                    'department' { 'Department' }
                    'city' { 'City' }
                    'country' { 'Country' }
                    'usageLocation' { 'UsageLocation' }
                }
                if ($actual.$nombrePs -ne $deseado[$propiedad]) {
                    $cambios[$propiedad] = $deseado[$propiedad]
                }
            }
            if ($cambios.Count -gt 0) {
                Escribir "  DERIVA ${upn}: $($cambios.Keys -join ', ')."
                if (-not $SoloComprobar) {
                    Update-MgUser -UserId $actual.Id -BodyParameter $cambios
                }
            }
            else {
                Escribir "  OK $upn."
            }

            if ($id.Alias -eq 'charlie.dev' -and -not $SoloComprobar) {
                Update-MgUser -UserId $actual.Id -PasswordProfile @{
                    Password = $passwordCharlie
                    ForceChangePasswordNextSignIn = $false
                    ForceChangePasswordNextSignInWithMfa = $false
                }
                Escribir '  charlie.dev: credencial separada convergida.'
            }
        }
    }

    Titulo '4. Licencias'
    foreach ($id in $identidades) {
        $upn = "$($id.Alias)@$Dominio"
        $usuario = Get-MgUser -UserId $upn -Property 'id,assignedLicenses,usageLocation' -ErrorAction SilentlyContinue
        if (-not $usuario) {
            if ($SoloComprobar) { Escribir "  FALTA $upn; no se puede comprobar licencia."; continue }
            throw "$upn no existe despues de la convergencia."
        }
        if ($usuario.AssignedLicenses.SkuId -contains $sku.SkuId) {
            Escribir "  OK $upn tiene $SkuE5."
            continue
        }
        Escribir "  FALTA $SkuE5 en $upn."
        if (-not $SoloComprobar) {
            Set-MgUserLicense -UserId $usuario.Id `
                -AddLicenses @(@{ SkuId = $sku.SkuId }) -RemoveLicenses @() | Out-Null
        }
    }

    if (-not $SaltarMdo) {
        Titulo '5. Purview Audit, se explota en la fase 12'
        $audit = Get-AdminAuditLogConfig -ErrorAction Stop
        if (-not $audit.UnifiedAuditLogIngestionEnabled) {
            Escribir '  FALTA grabacion unificada.'
            if (-not $SoloComprobar) {
                Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true
                Esperar-Condicion -Descripcion 'UnifiedAuditLogIngestionEnabled=true' -Condicion {
                    (Get-AdminAuditLogConfig -ErrorAction Stop).UnifiedAuditLogIngestionEnabled
                }
            }
        }
        else { Escribir '  OK grabacion unificada activa.' }

        Titulo '6. MDO preset'
        $nombrePreset = "$PresetMdo Preset Security Policy"
        foreach ($tipo in @('EOP', 'ATP')) {
            $regla = $reglasMdo[$tipo]
            $dominios = @(Obtener-DominiosReglaMdo -Regla $regla)
            if ($regla.State -ne 'Enabled') {
                Escribir "  FALTA habilitar $tipo."
                if (-not $SoloComprobar) { & "Enable-${tipo}ProtectionPolicyRule" -Identity $nombrePreset }
            }
            if ($dominios -notcontains $Dominio) {
                Escribir "  FALTA alcance $Dominio en $tipo."
                if (-not $SoloComprobar) {
                    $nuevoAmbito = @($dominios + $Dominio | Select-Object -Unique)
                    & "Set-${tipo}ProtectionPolicyRule" -Identity $nombrePreset -RecipientDomainIs $nuevoAmbito
                }
            }
        }

        if (-not $SoloComprobar) {
            Esperar-Condicion -Descripcion "preset $PresetMdo habilitado y aplicado a $Dominio" -Condicion {
                foreach ($tipo in @('EOP', 'ATP')) {
                    $r = & "Get-${tipo}ProtectionPolicyRule" -Identity $nombrePreset -ErrorAction Stop
                    $d = @(Obtener-DominiosReglaMdo -Regla $r)
                    if ($r.State -ne 'Enabled' -or $d -notcontains $Dominio) { return $false }
                }
                return $true
            }
        }
    }

    Titulo '7. Verificacion final'
    $fallos = [System.Collections.Generic.List[string]]::new()
    foreach ($id in $identidades) {
        $upn = "$($id.Alias)@$Dominio"
        $u = Get-MgUser -UserId $upn `
            -Property 'accountEnabled,displayName,givenName,surname,mailNickname,jobTitle,department,city,country,usageLocation,assignedLicenses' `
            -ErrorAction SilentlyContinue
        if (-not $u) { $fallos.Add("usuario ausente: $upn"); continue }
        if (-not $u.AccountEnabled -or $u.DisplayName -ne "$($id.Nombre) $($id.Apellido)" -or
            $u.GivenName -ne $id.Nombre -or $u.Surname -ne $id.Apellido -or
            $u.MailNickname -ne $id.Alias -or $u.JobTitle -ne $id.Cargo -or
            $u.Department -ne $id.Departamento -or $u.City -ne $Ciudad -or
            $u.Country -ne $Pais -or $u.UsageLocation -ne $UbicacionUso) {
            $fallos.Add("perfil con deriva: $upn")
        }
        if ($u.AssignedLicenses.SkuId -notcontains $sku.SkuId) {
            $fallos.Add("$SkuE5 ausente: $upn")
        }
    }
    if (-not $SaltarMdo) {
        if (-not (Get-AdminAuditLogConfig).UnifiedAuditLogIngestionEnabled) {
            $fallos.Add('Purview Audit no esta activo')
        }
        foreach ($tipo in @('EOP', 'ATP')) {
            $r = & "Get-${tipo}ProtectionPolicyRule" -Identity "$PresetMdo Preset Security Policy" -ErrorAction SilentlyContinue
            $d = @(Obtener-DominiosReglaMdo -Regla $r)
            if (-not $r -or $r.State -ne 'Enabled' -or $d -notcontains $Dominio) {
                $fallos.Add("preset MDO $tipo no converge")
            }
        }
    }
    if ($fallos.Count -gt 0) {
        throw "Verificacion final fallida: $($fallos -join '; ')."
    }

    Escribir "OK: seis perfiles, SKU $SkuE5, Purview/MDO segun alcance, tenant verificado."
    if ($SoloComprobar) { Escribir 'Modo comprobacion: no se modificaron modulos ni tenant.' }
    Write-Host @"

Pasos de portal que siguen siendo propios del servicio:
  - Activar el conector de aplicaciones de M365 dentro de MDCA.
  - Activar el sensor MDI v3 de DC01 cuando aparezca en Device inventory:
    security.microsoft.com > System > Settings > Identities > Activation.
  - Comprobar el workspace Primary en Defender.
"@
}
finally {
    $password = $null
    $passwordNegocio = $null
    $passwordCharlie = $null
    if ($exchangeConectado) {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    }
    if ($graphConectado) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }
}
