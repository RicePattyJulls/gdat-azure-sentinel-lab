<#
    Puerta real de la fase 15. No valida tiempo transcurrido: exige origenes
    activos, una fila en ForwardedEvents y esa misma canalizacion visible en la
    tabla WindowsEvent del workspace.
#>
[CmdletBinding()]
param(
    [string] $NombreSuscripcion = 'GDAT-Baseline',
    [Parameter(Mandatory)] [string] $WorkspaceCustomerId,
    [string[]] $Origenes = @('DC01', 'MEMBER01'),
    [int] $TimeoutSegundos = 1800,
    [string] $MarcaEjecucion = ''
)

$ErrorActionPreference = 'Stop'

function Escribir([string] $Mensaje) {
    Write-Output ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Mensaje)
}

Escribir "Puerta WEF, ejecucion $MarcaEjecucion."
try {
    $inicioUtc = [DateTime]::ParseExact(
        $MarcaEjecucion,
        'yyyyMMddHHmmss',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    )
}
catch {
    throw "MarcaEjecucion debe ser UTC con formato yyyyMMddHHmmss; valor recibido: '$MarcaEjecucion'."
}

function Invoke-Wecutil([string[]] $Argumentos) {
    $salida = & "$env:SystemRoot\System32\wecutil.exe" @Argumentos 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "wecutil $($Argumentos -join ' ') termino con codigo $LASTEXITCODE. $($salida -join ' ')"
    }
    return @($salida)
}

$limite = (Get-Date).AddSeconds($TimeoutSegundos)
$runtimeListo = $false
do {
    $runtime = (Invoke-Wecutil @('gr', $NombreSuscripcion)) -join [Environment]::NewLine
    $origenesPresentes = @($Origenes | Where-Object { $runtime -match [regex]::Escape($_) }).Count
    $erroresCero = ([regex]::Matches($runtime, '(?im)^\s*LastError:\s*0\s*$')).Count
    $runtimeListo = $origenesPresentes -eq $Origenes.Count -and $erroresCero -ge $Origenes.Count
    if (-not $runtimeListo) {
        Start-Sleep -Seconds 15
    }
} while (-not $runtimeListo -and (Get-Date) -lt $limite)

if (-not $runtimeListo) {
    throw "Los origenes no quedaron activos y sin error en $NombreSuscripcion antes del timeout. Runtime: $runtime"
}
Escribir 'Todos los origenes aparecen activos y con LastError=0.'

do {
    $filaLocal = Get-WinEvent -FilterHashtable @{
        LogName = 'ForwardedEvents'
        StartTime = $inicioUtc.ToLocalTime()
    } -MaxEvents 1 -ErrorAction SilentlyContinue
    if ($null -eq $filaLocal) {
        Start-Sleep -Seconds 15
    }
} while ($null -eq $filaLocal -and (Get-Date) -lt $limite)
if ($null -eq $filaLocal) {
    throw 'ForwardedEvents sigue vacio aunque los origenes aparecen activos.'
}
Escribir "ForwardedEvents contiene datos; ultima fila de $($filaLocal.MachineName)."

$compute = Invoke-RestMethod -Headers @{ Metadata = 'true' } -Method GET `
    -Uri 'http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01'
$resourceIdWec = [string] $compute.resourceId
if ([string]::IsNullOrWhiteSpace($resourceIdWec)) {
    throw 'IMDS no devolvio el resource ID de WEC01.'
}

$inicioKql = $inicioUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
$consulta = @"
WindowsEvent
| where TimeGenerated >= datetime($inicioKql)
| where _ResourceId =~ "$resourceIdWec"
| summarize Filas=count(), Origenes=dcount(Computer)
"@

$filaNube = $null
$ultimoError = $null
do {
    try {
        $token = Invoke-RestMethod -Headers @{ Metadata = 'true' } -Method GET `
            -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2019-08-01&resource=https%3A%2F%2Fapi.loganalytics.io'
        $respuesta = Invoke-RestMethod -Method POST `
            -Uri "https://api.loganalytics.azure.com/v1/workspaces/$WorkspaceCustomerId/query" `
            -Headers @{ Authorization = "Bearer $($token.access_token)" } `
            -ContentType 'application/json' `
            -Body (@{ query = $consulta } | ConvertTo-Json)
        $filaNube = $respuesta.tables[0].rows[0]
        if ($null -eq $filaNube -or [int64] $filaNube[0] -lt 1 -or [int64] $filaNube[1] -lt $Origenes.Count) {
            $filaNube = $null
        }
    }
    catch {
        $ultimoError = $_.Exception.Message
        $filaNube = $null
    }
    if ($null -eq $filaNube) {
        Start-Sleep -Seconds 30
    }
} while ($null -eq $filaNube -and (Get-Date) -lt $limite)

if ($null -eq $filaNube) {
    throw "La tabla WindowsEvent no recibio ForwardedEvents nuevos de los $($Origenes.Count) origenes antes del timeout. Ultimo error: $ultimoError"
}
Escribir "Canalizacion WEF verificada en Log Analytics: $($filaNube[0]) filas, $($filaNube[1]) origenes."
