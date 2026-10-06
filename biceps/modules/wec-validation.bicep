/* Puerta de datos de la fase 15, separada para ordenar el RBAC entre RG. */

@description('Region de WEC01.')
param location string

@description('Nombre del recurso VM de WEC01.')
param nombreVm string

@description('Customer ID del workspace.')
param workspaceCustomerId string

@description('Valor cambiante que obliga a volver a ejecutar la puerta.')
param marcaEjecucion string

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' existing = {
  name: nombreVm
}

resource validar 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  parent: vm
  name: 'validar-wef'
  location: location
  properties: {
    source: {
      script: loadTextContent('../scripts/validate-wef.ps1')
    }
    parameters: [
      {
        name: 'WorkspaceCustomerId'
        value: workspaceCustomerId
      }
      {
        name: 'MarcaEjecucion'
        value: marcaEjecucion
      }
    ]
    timeoutInSeconds: 2400
    treatFailureAsDeploymentFailure: true
  }
}
