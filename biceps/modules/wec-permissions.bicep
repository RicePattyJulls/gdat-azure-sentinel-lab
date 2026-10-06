/* Permiso minimo para que la identidad de WEC01 ejecute la puerta KQL. */

@description('Nombre del workspace.')
param nombreWorkspace string

@description('Object ID de la identidad administrada de WEC01.')
param principalId string

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: nombreWorkspace
}

resource lector 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: workspace
  name: guid(workspace.id, principalId, 'Log Analytics Reader WEF')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '73c42c96-874c-492b-b04d-ab87d138a893')
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

output roleAssignmentId string = lector.id
