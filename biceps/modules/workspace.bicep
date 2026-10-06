/*
  Fase 5 · Workspace, Sentinel, retencion, RBAC y arranque de UEBA
  Cobertura Bicep: ~90%.

  Queda fuera y se hace aparte: conectar el workspace como Primary en el portal
  de Defender. Eso no es ARM.

  Sobre UEBA: se prehabilita aqui, en la etapa 0, para que el reloj empiece
  cuanto antes. Un workspace vacio no genera aprendizaje: la ventana util
  comienza cuando los conectores entregan los primeros eventos, no en el
  momento de esta linea.
*/

@description('Region del workspace. Las DCR deben desplegarse en esta misma region.')
param location string

@description('Nombre del workspace de Log Analytics.')
param nombreWorkspace string

@description('Dias de retencion en el nivel analytics.')
@minValue(30)
@maxValue(730)
param retencionDias int = 90

@description('Tope diario de ingesta en GB. -1 desactiva el tope.')
param topeDiarioGb int = -1

/*
  UEBA y Entity Analytics son de "activar una vez".

  La API de SecurityInsights usa concurrencia optimista: un segundo despliegue
  sobre unos settings que ya existen falla pidiendo el ETag actual, y ARM no
  admite declarar etag en una plantilla. Como no hay nada que reconfigurar
  despues de la primera vez, se apagan en los redespliegues.

  Si alguna vez hay que cambiar sus dataSources, se pone en true tras borrar los
  settings existentes, o se hace desde el portal.
*/
@description('Crear los settings de UEBA y Entity Analytics. Apagar en redespliegues.')
param conUeba bool = true

@description('Object IDs de Entra que reciben Microsoft Sentinel Responder. Vacio para omitir.')
param responderObjectIds array = []

@description('Object IDs de Entra que reciben Microsoft Sentinel Contributor. Vacio para omitir.')
param contributorObjectIds array = []

// IDs fijos de rol integrado. Son constantes globales de Azure.
var rolSentinelResponder = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3e150937-b8fe-4cfb-8069-0eaf05ecd056')
var rolSentinelContributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ab8e14d6-4a74-4a29-9ba8-549422addade')

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: nombreWorkspace
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retencionDias
    workspaceCapping: {
      dailyQuotaGb: topeDiarioGb
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// Habilitar Microsoft Sentinel sobre el workspace.
// Habilitar Sentinel tambien es de una vez, y por el mismo motivo.
resource sentinel 'Microsoft.SecurityInsights/onboardingStates@2023-02-01' = if (conUeba) {
  name: 'default'
  scope: workspace
}

// Entity Analytics primero: UEBA se apoya en el proveedor de entidades.
resource entityAnalytics 'Microsoft.SecurityInsights/settings@2023-12-01-preview' = if (conUeba) {
  name: 'EntityAnalytics'
  scope: workspace
  kind: 'EntityAnalytics'
  properties: {
    entityProviders: [ 'AzureActiveDirectory' ]
  }
  dependsOn: [ sentinel ]
}

resource ueba 'Microsoft.SecurityInsights/settings@2023-12-01-preview' = if (conUeba) {
  name: 'Ueba'
  scope: workspace
  kind: 'Ueba'
  properties: {
    dataSources: [
      'AuditLogs'
      'AzureActivity'
      'SigninLogs'
      'SecurityEvent'
    ]
  }
  dependsOn: [ entityAnalytics ]
}

// Separacion de roles del SOC: operator responde, engineer construye.
resource asignacionResponder 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for oid in responderObjectIds: {
  name: guid(workspace.id, oid, 'Responder')
  scope: workspace
  properties: {
    roleDefinitionId: rolSentinelResponder
    principalId: oid
    principalType: 'User'
  }
}]

resource asignacionContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for oid in contributorObjectIds: {
  name: guid(workspace.id, oid, 'Contributor')
  scope: workspace
  properties: {
    roleDefinitionId: rolSentinelContributor
    principalId: oid
    principalType: 'User'
  }
}]

output workspaceId string = workspace.id
output workspaceName string = workspace.name
output customerId string = workspace.properties.customerId
@description('Region del workspace. Las DCR tienen que ir aqui, no donde estan las VM.')
output workspaceLocation string = workspace.location
