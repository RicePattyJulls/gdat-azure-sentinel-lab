/*
  Fase 17 · Logs personalizados, DCE, tablas _CL y transformaciones
  Cobertura Bicep: ~90%. Lo unico que queda fuera es el envio real de datos.

  Esta fase no necesita ninguna maquina virtual: es toda plano de control. Se
  puede levantar con la cuota de cores al limite.

  El orden importa y es el que corrige el recorrido de portal: el DCE va PRIMERO
  y en la region del workspace, luego la tabla, luego la DCR que la referencia.
  Construir la URI de ingesta a mano, del tipo <dce>.<region>-1, no es fiable:
  se lee del propio DCE con logsIngestion.endpoint.

  La transformKql se aplica ANTES de guardar. Es la palanca de coste mas directa
  que existe: filtrar aqui evita pagar la ingesta de lo que no se va a consultar.
*/

@description('Region del workspace. El DCE y la DCR deben ir aqui.')
param location string

@description('Prefijo de nombres.')
param prefijo string

@description('Nombre del workspace destino.')
param nombreWorkspace string

@description('Nombre de la tabla personalizada, sin el sufijo _CL.')
@minLength(4)
@maxLength(40)
param nombreTabla string = 'NovaShop'

@description('Object ID del principal que enviara datos a la DCR.')
@minLength(1)
param principalIngestaId string

@description('Tipo del principal de ingesta.')
@allowed([ 'ServicePrincipal', 'User', 'Group' ])
param tipoPrincipalIngesta string = 'ServicePrincipal'

var nombreCompletoTabla = '${nombreTabla}_CL'
var nombreDce = 'DCE-${prefijo}-${nombreTabla}'
var nombreDcr = 'DCR-${prefijo}-${nombreTabla}'
var streamEntrada = 'Custom-${nombreCompletoTabla}'

// Monitoring Metrics Publisher: concede Microsoft.Insights/Telemetry/Write sobre
// la DCR. Asignarlo exige a su vez Microsoft.Authorization/roleAssignments/write
// en ese ambito; sin ese permiso la ingesta termina en 403.
var rolMetricsPublisher = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: nombreWorkspace
}

resource dce 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: nombreDce
  location: location
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

resource tabla 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = {
  parent: workspace
  name: nombreCompletoTabla
  properties: {
    plan: 'Analytics'
    schema: {
      name: nombreCompletoTabla
      columns: [
        {
          // TimeGenerated es obligatoria en toda tabla personalizada.
          name: 'TimeGenerated'
          type: 'datetime'
        }
        {
          name: 'Lote'
          type: 'string'
        }
        {
          name: 'ResourceId'
          type: 'string'
        }
        {
          name: 'Sitio'
          type: 'string'
        }
        {
          name: 'Tabla'
          type: 'string'
        }
        {
          name: 'Registros'
          type: 'long'
        }
        {
          name: 'Sensibilidad'
          type: 'string'
        }
      ]
    }
  }
}

resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: nombreDcr
  location: location
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      '${streamEntrada}': {
        columns: [
          { name: 'Time', type: 'string' }
          { name: 'Lote', type: 'string' }
          { name: 'ResourceId', type: 'string' }
          { name: 'Sitio', type: 'string' }
          { name: 'Tabla', type: 'string' }
          { name: 'Registros', type: 'long' }
          { name: 'Sensibilidad', type: 'string' }
        ]
      }
    }
    destinations: {
      logAnalytics: [
        {
          name: 'destino-workspace'
          workspaceResourceId: workspace.id
        }
      ]
    }
    dataFlows: [
      {
        streams: [ streamEntrada ]
        destinations: [ 'destino-workspace' ]
        outputStream: streamEntrada
        transformKql: 'source | extend TimeGenerated = todatetime(Time) | where Sensibilidad == "alta" | project-away Time'
      }
    ]
  }
  dependsOn: [ tabla ]
}

resource permisoIngesta 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dcr.id, principalIngestaId, 'MetricsPublisher')
  scope: dcr
  properties: {
    roleDefinitionId: rolMetricsPublisher
    principalId: principalIngestaId
    principalType: tipoPrincipalIngesta
  }
}

@description('URI de ingesta leida del DCE. No construir a mano.')
output uriIngesta string = dce.properties.logsIngestion.endpoint

@description('immutableId de la DCR, que forma parte de la ruta de ingesta.')
output dcrImmutableId string = dcr.properties.immutableId

output streamEntrada string = streamEntrada
output nombreTabla string = nombreCompletoTabla
