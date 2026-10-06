/*
  Fase 5 · Azure Monitor Agent, DCR y asociaciones
  Cobertura Bicep: ~80%. Los conectores que exigen consentimiento OAuth quedan
  fuera de ARM.

  Dos detalles que deciden si esto funciona:

  1. La DCR se despliega en la region del WORKSPACE, no en la de las VM. Aqui se
     recibe esa region como parametro para no heredar por descuido la del grupo
     de recursos.
  2. El agente por si solo no recoge nada. Lo que define que se recoge es la
     DCR, y lo que la aplica a una maquina es la asociacion. Sin la DCRA el
     agente queda instalado y mudo.
*/

@description('Region de las VM, donde se instala el agente.')
param location string

@description('Region del workspace. La DCR tiene que crearse aqui.')
param locationWorkspace string

@description('Prefijo de nombres.')
param prefijo string

@description('ID del workspace destino.')
param workspaceId string

@description('Maquinas a instrumentar: objetos con name y id.')
param maquinas array

var nombreDcr = 'DCR-${prefijo}-SecurityEvents'

resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: nombreDcr
  location: locationWorkspace
  kind: 'Windows'
  properties: {
    dataSources: {
      windowsEventLogs: [
        {
          // Solo el canal Security va por este stream. Es lo que decide que los
          // eventos aterricen en SecurityEvent y no en Event, que es la tabla
          // que espera Sentinel.
          name: 'eventos-seguridad'
          streams: [ 'Microsoft-SecurityEvent' ]
          xPathQueries: [
            // band() sobre Keywords selecciona auditorias correctas y fallidas.
            // El XPath de AMA es el subconjunto de Windows Event Log: admite
            // band, position y timediff, pero NO contains ni starts-with. Un
            // filtro por texto aqui no da error, simplemente no recoge nada.
            'Security!*[System[(band(Keywords,13510798882111488))]]'
          ]
        }
        {
          // System y Application son canales distintos y no son de seguridad:
          // van por su propio stream y aterrizan en la tabla Event. Mezclarlos
          // en el stream anterior los empujaria a SecurityEvent, que no es su
          // sitio.
          name: 'eventos-sistema'
          streams: [ 'Microsoft-WindowsEvent' ]
          xPathQueries: [
            'System!*[System[(Level=1 or Level=2 or Level=3)]]'
            'Application!*[System[(Level=1 or Level=2 or Level=3)]]'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: 'destino-workspace'
          workspaceResourceId: workspaceId
        }
      ]
    }
    dataFlows: [
      {
        streams: [ 'Microsoft-SecurityEvent' ]
        destinations: [ 'destino-workspace' ]
      }
      {
        streams: [ 'Microsoft-WindowsEvent' ]
        destinations: [ 'destino-workspace' ]
      }
    ]
  }
}

resource maquina 'Microsoft.Compute/virtualMachines@2024-07-01' existing = [for m in maquinas: {
  name: m.name
}]

resource agente 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = [for (m, i) in maquinas: {
  parent: maquina[i]
  name: 'AzureMonitorWindowsAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorWindowsAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}]

// La asociacion es la pieza que hace que el agente sepa que recoger.
resource asociacion 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = [for (m, i) in maquinas: {
  name: 'dcra-${m.name}'
  scope: maquina[i]
  properties: {
    dataCollectionRuleId: dcr.id
  }
  dependsOn: [ agente[i] ]
}]

output dcrId string = dcr.id
output dcrName string = dcr.name
