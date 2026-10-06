<#
    Fase 15 · configuracion LOCAL del colector WEC01.

    Este script no toca Active Directory ni GPO. Se ejecuta como SYSTEM en
    WEC01 y deja WinRM, Windows Event Collector y la suscripcion local en un
    estado convergente. La configuracion de los origenes vive en
    configure-wef-dominio.ps1 y se ejecuta en DC01/MEMBER01.
#>
[CmdletBinding()]
param(
    [string] $NombreSuscripcion = 'GDAT-Baseline',
    [string] $RutaXml = 'C:\Windows\Temp\gdat-baseline.xml',
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

Escribir 'Habilitando WinRM en el colector.'
Invoke-Nativo -Programa "$env:SystemRoot\System32\winrm.cmd" `
    -Argumentos @('quickconfig', '-quiet', '-force') | Out-Null

Escribir 'Habilitando Windows Event Collector.'
Invoke-Nativo -Programa "$env:SystemRoot\System32\wecutil.exe" `
    -Argumentos @('qc', '/q') | Out-Null

$sddl = 'O:NSG:NSD:(A;;GA;;;DC)(A;;GA;;;DD)(A;;GA;;;NS)'
$xml = @"
<Subscription xmlns="http://schemas.microsoft.com/2006/03/windows/events/subscription">
  <SubscriptionId>$NombreSuscripcion</SubscriptionId>
  <SubscriptionType>SourceInitiated</SubscriptionType>
  <Description>Baseline de seguridad del laboratorio GDAT</Description>
  <Enabled>true</Enabled>
  <Uri>http://schemas.microsoft.com/wbem/wsman/1/windows/EventLog</Uri>
  <ConfigurationMode>MinLatency</ConfigurationMode>
  <Query>
    <![CDATA[
      <QueryList>
        <Query Id="0">
          <Select Path="Security">*[System[(EventID=4624 or EventID=4625 or EventID=4648 or EventID=4662 or EventID=4688 or EventID=4720 or EventID=4728 or EventID=4732 or EventID=4769)]]</Select>
          <Select Path="System">*[System[Provider[@Name='Microsoft-Windows-WinRM']]]</Select>
          <Select Path="Application">*[System[Provider[@Name='GDAT-WEF'] and (EventID=100)]]</Select>
        </Query>
      </QueryList>
    ]]>
  </Query>
  <ReadExistingEvents>false</ReadExistingEvents>
  <TransportName>HTTP</TransportName>
  <ContentFormat>Events</ContentFormat>
  <Locale Language="en-US"/>
  <LogFile>ForwardedEvents</LogFile>
  <AllowedSourceNonDomainComputers></AllowedSourceNonDomainComputers>
  <AllowedSourceDomainComputers>$sddl</AllowedSourceDomainComputers>
</Subscription>
"@

$directorio = Split-Path -Parent $RutaXml
if (-not (Test-Path -LiteralPath $directorio)) {
    New-Item -ItemType Directory -Path $directorio -Force | Out-Null
}
$xml | Set-Content -LiteralPath $RutaXml -Encoding UTF8

$existentes = Invoke-Nativo -Programa "$env:SystemRoot\System32\wecutil.exe" `
    -Argumentos @('es')
if ($existentes -contains $NombreSuscripcion) {
    Escribir "Actualizando la suscripcion $NombreSuscripcion desde el XML."
    Invoke-Nativo -Programa "$env:SystemRoot\System32\wecutil.exe" `
        -Argumentos @('ss', $NombreSuscripcion, "/c:$RutaXml") | Out-Null
}
else {
    Escribir "Creando la suscripcion $NombreSuscripcion."
    Invoke-Nativo -Programa "$env:SystemRoot\System32\wecutil.exe" `
        -Argumentos @('cs', $RutaXml) | Out-Null
}

[xml] $estadoXml = (Invoke-Nativo -Programa "$env:SystemRoot\System32\wecutil.exe" `
    -Argumentos @('gs', $NombreSuscripcion, '/f:xml')) -join [Environment]::NewLine
$ns = New-Object System.Xml.XmlNamespaceManager($estadoXml.NameTable)
$ns.AddNamespace('w', 'http://schemas.microsoft.com/2006/03/windows/events/subscription')
$id = $estadoXml.SelectSingleNode('//w:SubscriptionId', $ns).InnerText
$habilitada = $estadoXml.SelectSingleNode('//w:Enabled', $ns).InnerText
$canal = $estadoXml.SelectSingleNode('//w:LogFile', $ns).InnerText
if ($id -ne $NombreSuscripcion -or $habilitada -ne 'true' -or $canal -ne 'ForwardedEvents') {
    throw "La suscripcion no converge: id=$id, enabled=$habilitada, log=$canal."
}

$servicio = Get-Service -Name Wecsvc
if ($servicio.StartType -ne 'Automatic') {
    Set-Service -Name Wecsvc -StartupType Automatic
}
if ($servicio.Status -ne 'Running') {
    Start-Service -Name Wecsvc
}

Escribir "Suscripcion $NombreSuscripcion habilitada y verificada en el colector."
