/*
  Fase 5 · Reglas analiticas y automation rules
  Las siete reglas se prueban contra un ataque en la fase 10.
  Cobertura Bicep: ~95%. El KQL vive en queries/ y queda versionado en Git, que
  era el objetivo principal de llevar esto a IaC.

  Tres cosas que no son opcionales:

  1. La descripcion empieza por #INC_CORR#. Sin ese tag la regla queda fuera del
     motor de correlacion de Defender XDR y genera un incidente aislado.
  2. El entity mapping decide si dos alertas hablan de la misma cuenta o de dos.
     Las cuentas van normalizadas para que NOVASHOP\usuario y usuario@tenant se
     reconozcan como una sola identidad.
  3. La agrupacion usa matchingMethod Selected con ventana de cinco horas. Eso
     decide como se juntan las alertas ya creadas; no confundir con el event
     grouping, que decide cuantas alertas salen de una consulta.

  La regla 3 es NRT y no Scheduled: no admite frecuencia ni periodo.
  La regla 7 no emite IP, porque el 4662 no la trae: el evento lo escribe el
  propio controlador.
*/

@description('Nombre del workspace con Sentinel habilitado.')
param nombreWorkspace string

@description('IPs de administracion excluidas de las reglas, como array.')
param ipsAdmin array

@description('Cuentas de administracion excluidas de las reglas, como array.')
param cuentasAdmin array

@description('Mapa de IP publica a nombre de host del laboratorio.')
param mapaIpHost object

@description('Nombre de la aplicacion NovaShop, para la entidad Host de la regla 1.')
param nombreApp string

@description('Nombre de la cuenta de almacenamiento, para la entidad Host de la regla 4.')
param nombreStorage string

@description('Crear tambien las automation rules de la fase 5.')
param conAutomationRules bool = true

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: nombreWorkspace
}

// Sustituciones de los marcadores que dejan el KQL libre de datos del entorno.
var ipsAdminJson = string(ipsAdmin)
var cuentasAdminJson = string(cuentasAdmin)
var mapaIpHostJson = string(mapaIpHost)

var kqlSqli = replace(loadTextContent('../queries/01-sqli-novashop.kql'), '__NOMBRE_APP__', nombreApp)
var kqlKerberoasting = loadTextContent('../queries/02-kerberoasting.kql')
var kqlGrupo = loadTextContent('../queries/03-grupo-privilegiado.kql')
var kqlExfiltracion = replace(replace(replace(
  loadTextContent('../queries/04-exfiltracion-storage.kql'),
  '__IPS_ADMIN__', ipsAdminJson),
  '__MAPA_IP_HOST__', mapaIpHostJson),
  '__NOMBRE_STORAGE__', nombreStorage)
var kqlRecursos = loadTextContent('../queries/05-creacion-recursos.kql')
var kqlRdp = replace(loadTextContent('../queries/06-rdp-entrante.kql'), '__CUENTAS_ADMIN__', cuentasAdminJson)
var kqlDcsync = loadTextContent('../queries/07-dcsync-4662.kql')

var agrupacionCuentaIpHost = [ 'Account', 'IP', 'Host' ]
var agrupacionCuentaHost = [ 'Account', 'Host' ]
var agrupacionIpHost = [ 'IP', 'Host' ]
var agrupacionCuentaIp = [ 'Account', 'IP' ]

var reglasScheduled = [
  {
    id: 'sqli-novashop'
    displayName: 'Explotacion de SQL injection en NovaShop'
    descripcion: '#INC_CORR# Patron de inyeccion SQL registrado por la propia aplicacion en su log de seguridad.'
    severity: 'High'
    query: kqlSqli
    frecuencia: 'PT5M'
    periodo: 'PT1H'
    tactics: [ 'InitialAccess' ]
    techniques: [ 'T1190' ]
    agrupa: agrupacionCuentaIpHost
    entidades: [
      { entityType: 'Account', fieldMappings: [ { identifier: 'Name', columnName: 'CuentaNormalizada' } ] }
      { entityType: 'IP', fieldMappings: [ { identifier: 'Address', columnName: 'IPOrigen' } ] }
      { entityType: 'Host', fieldMappings: [ { identifier: 'HostName', columnName: 'HostAfectado' } ] }
    ]
  }
  {
    id: 'kerberoasting'
    displayName: 'Kerberoasting'
    descripcion: '#INC_CORR# Peticion de ticket de servicio con cifrado RC4 contra una cuenta con SPN. Por si solo no prueba el ataque: hay sistemas antiguos que siguen pidiendo RC4.'
    severity: 'High'
    query: kqlKerberoasting
    frecuencia: 'PT5M'
    periodo: 'PT1H'
    tactics: [ 'CredentialAccess' ]
    techniques: [ 'T1558' ]
    agrupa: agrupacionCuentaIpHost
    entidades: [
      { entityType: 'Account', fieldMappings: [ { identifier: 'Name', columnName: 'CuentaNormalizada' } ] }
      { entityType: 'IP', fieldMappings: [ { identifier: 'Address', columnName: 'IPOrigen' } ] }
      { entityType: 'Host', fieldMappings: [ { identifier: 'HostName', columnName: 'HostCorto' } ] }
    ]
  }
  {
    id: 'exfiltracion-storage'
    displayName: 'Exfiltracion a Azure Storage'
    descripcion: '#INC_CORR# Subida de blobs autenticada con clave de cuenta desde una IP que no es de administracion.'
    severity: 'High'
    query: kqlExfiltracion
    frecuencia: 'PT5M'
    periodo: 'PT1H'
    tactics: [ 'Exfiltration' ]
    techniques: [ 'T1567' ]
    agrupa: agrupacionIpHost
    entidades: [
      { entityType: 'IP', fieldMappings: [ { identifier: 'Address', columnName: 'IPOrigen' } ] }
      { entityType: 'Host', fieldMappings: [ { identifier: 'HostName', columnName: 'HostOrigen' } ] }
    ]
  }
  {
    id: 'creacion-recursos'
    displayName: 'Creacion sospechosa de recursos'
    descripcion: '#INC_CORR# Una identidad crea varios recursos en poco tiempo. Senal de persistencia en la suscripcion.'
    severity: 'Medium'
    query: kqlRecursos
    frecuencia: 'PT1H'
    periodo: 'PT1H'
    tactics: [ 'Persistence' ]
    techniques: [ 'T1078' ]
    agrupa: agrupacionCuentaIp
    entidades: [
      { entityType: 'Account', fieldMappings: [ { identifier: 'Name', columnName: 'CuentaNormalizada' } ] }
      { entityType: 'IP', fieldMappings: [ { identifier: 'Address', columnName: 'IPOrigen' } ] }
    ]
  }
  {
    id: 'rdp-entrante'
    displayName: 'RDP entrante desde Internet'
    descripcion: '#INC_CORR# Inicio de sesion tipo 10 desde una IP publica. Sospechoso, no concluyente por si solo: por eso es la regla puente entre la nube y el endpoint.'
    severity: 'Medium'
    query: kqlRdp
    frecuencia: 'PT5M'
    periodo: 'PT1H'
    tactics: [ 'LateralMovement' ]
    techniques: [ 'T1021' ]
    agrupa: agrupacionCuentaIpHost
    entidades: [
      { entityType: 'Account', fieldMappings: [ { identifier: 'Name', columnName: 'CuentaNormalizada' } ] }
      { entityType: 'IP', fieldMappings: [ { identifier: 'Address', columnName: 'IPOrigen' } ] }
      { entityType: 'Host', fieldMappings: [ { identifier: 'HostName', columnName: 'HostCorto' } ] }
    ]
  }
  {
    id: 'dcsync-4662'
    displayName: 'DCSync mediante el evento 4662'
    descripcion: '#INC_CORR# Uso de los derechos extendidos de replicacion por algo que no es un controlador de dominio. Requiere la SACL de auditoria en el objeto de dominio; sin ella no se emite ningun 4662.'
    severity: 'High'
    query: kqlDcsync
    frecuencia: 'PT5M'
    periodo: 'PT1H'
    tactics: [ 'CredentialAccess' ]
    techniques: [ 'T1003' ]
    agrupa: agrupacionCuentaHost
    entidades: [
      { entityType: 'Account', fieldMappings: [ { identifier: 'Name', columnName: 'CuentaNormalizada' } ] }
      { entityType: 'Host', fieldMappings: [ { identifier: 'HostName', columnName: 'HostCorto' } ] }
    ]
  }
]

resource reglaScheduled 'Microsoft.SecurityInsights/alertRules@2023-12-01-preview' = [for r in reglasScheduled: {
  name: guid(workspace.id, r.id)
  scope: workspace
  kind: 'Scheduled'
  properties: {
    displayName: r.displayName
    description: r.descripcion
    severity: r.severity
    enabled: true
    query: r.query
    queryFrequency: r.frecuencia
    queryPeriod: r.periodo
    triggerOperator: 'GreaterThan'
    triggerThreshold: 0
    suppressionDuration: 'PT1H'
    suppressionEnabled: false
    tactics: r.tactics
    techniques: r.techniques
    entityMappings: r.entidades
    incidentConfiguration: {
      createIncident: true
      groupingConfiguration: {
        enabled: true
        reopenClosedIncident: false
        lookbackDuration: 'PT5H'
        matchingMethod: 'Selected'
        groupByEntities: r.agrupa
        groupByAlertDetails: []
        groupByCustomDetails: []
      }
    }
  }
}]

// La adicion a grupo privilegiado va en NRT: se quiere en el minuto, no en cinco.
// NRT no admite queryFrequency ni queryPeriod.
// NRT necesita 2023-12-01-preview. La API 2023-02-01 no lo admite y el
// despliegue falla con "Unsupported api-version for kind: NRT". El aviso BCP036
// que daba Bicep con la version antigua era real, no cosmetico.
resource reglaGrupoPrivilegiado 'Microsoft.SecurityInsights/alertRules@2023-12-01-preview' = {
  name: guid(workspace.id, 'grupo-privilegiado')
  scope: workspace
  kind: 'NRT'
  properties: {
    displayName: 'Adicion a grupo privilegiado'
    description: '#INC_CORR# Alguien anade una cuenta a Domain Admins o a los administradores locales.'
    severity: 'High'
    enabled: true
    query: kqlGrupo
    suppressionDuration: 'PT1H'
    suppressionEnabled: false
    tactics: [ 'PrivilegeEscalation' ]
    techniques: [ 'T1098' ]
    entityMappings: [
      {
        entityType: 'Account'
        fieldMappings: [ { identifier: 'Name', columnName: 'CuentaNormalizada' } ]
      }
      {
        entityType: 'Host'
        fieldMappings: [ { identifier: 'HostName', columnName: 'HostCorto' } ]
      }
    ]
    incidentConfiguration: {
      createIncident: true
      groupingConfiguration: {
        enabled: true
        reopenClosedIncident: false
        lookbackDuration: 'PT5H'
        matchingMethod: 'Selected'
        groupByEntities: agrupacionCuentaHost
        groupByAlertDetails: []
        groupByCustomDetails: []
      }
    }
  }
}

// --- Fase 5 · automation rules --------------------------------------------
// Corren por prioridad ascendente. La de triaje va primero para que la de
// asignacion trabaje sobre un incidente ya clasificado.

resource automationTriaje 'Microsoft.SecurityInsights/automationRules@2023-12-01-preview' = if (conAutomationRules) {
  name: guid(workspace.id, 'auto-triaje-severidad')
  scope: workspace
  properties: {
    displayName: 'Triaje: elevar incidentes de la cadena'
    order: 1
    triggeringLogic: {
      isEnabled: true
      triggersOn: 'Incidents'
      triggersWhen: 'Created'
      conditions: [
        {
          conditionType: 'Property'
          conditionProperties: {
            propertyName: 'IncidentSeverity'
            operator: 'Equals'
            propertyValues: [ 'High' ]
          }
        }
      ]
    }
    actions: [
      {
        order: 1
        actionType: 'ModifyProperties'
        actionConfiguration: {
          severity: 'High'
          status: 'Active'
        }
      }
    ]
  }
}

resource automationCierre 'Microsoft.SecurityInsights/automationRules@2023-12-01-preview' = if (conAutomationRules) {
  name: guid(workspace.id, 'auto-cierre-informativo')
  scope: workspace
  properties: {
    displayName: 'Cerrar incidentes informativos del laboratorio'
    order: 2
    triggeringLogic: {
      isEnabled: true
      triggersOn: 'Incidents'
      triggersWhen: 'Created'
      conditions: [
        {
          conditionType: 'Property'
          conditionProperties: {
            propertyName: 'IncidentSeverity'
            operator: 'Equals'
            propertyValues: [ 'Informational' ]
          }
        }
      ]
    }
    actions: [
      {
        order: 1
        actionType: 'ModifyProperties'
        actionConfiguration: {
          status: 'Closed'
          classification: 'BenignPositive'
          // Cerrar como benigno exige decir por que. Sin classificationReason
          // el servicio rechaza la regla entera.
          classificationReason: 'SuspiciousButExpected'
          classificationComment: 'Ruido conocido del laboratorio.'
        }
      }
    ]
  }
}

output reglasCreadas int = length(reglasScheduled) + 1
