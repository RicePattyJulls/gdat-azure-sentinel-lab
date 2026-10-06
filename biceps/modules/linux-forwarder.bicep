/*
  Fase 16 · Forwarder de Syslog y CEF
  Cobertura Bicep: ~70%. La VM y la DCR son declarativas; rsyslog y el colector
  de AMA se configuran dentro del sistema.

  Dimensionada al minimo a proposito: con la cuota del laboratorio al limite,
  esta maquina es la que decide si el resto cabe. Un vCPU basta para reenviar.
  Sin IP publica: se administra con az vm run-command, no por SSH.
*/

@description('Region de la VM.')
param location string

@description('Region del workspace, donde va la DCR.')
param locationWorkspace string

@description('Prefijo de nombres.')
param prefijo string

@description('ID de la subnet.')
param subnetId string

@description('IP privada fija del forwarder.')
param ipPrivada string = '10.10.1.7'

@description('ID del workspace destino.')
param workspaceId string

/*
  Tamano y prioridad.

  Standard_B1s NO sirve aqui: su restriccion en esta region es de tipo Location,
  o sea que no esta disponible en ninguna zona. Standard_F1as_v7 tiene la
  restriccion acotada a la zona 3, asi que se despliega sin problema en el resto.

  Y va como Spot a proposito. Azure lleva dos contadores de vCPU separados: las
  VM regulares consumen 'Total Regional vCPUs', que DC01 y MEMBER01 agotan, y las
  Spot consumen 'Total Regional Low-priority vCPUs', que va aparte. Con WEC01 (2)
  y FWD01 (1) se llena justo esa cuota.

  Un forwarder de syslog tolera el desalojo igual de bien que el colector: si lo
  desalojan, se vuelve a arrancar y sigue reenviando.
*/
@description('Tamano de la VM. Un vCPU basta para reenviar. B1s no esta disponible en spaincentral.')
param tamanoVm string = 'Standard_F1as_v7'

@description('Desplegar como Spot. Usa la cuota Low-priority, que va aparte de la regular.')
param usarSpot bool = true

@description('Usuario administrador.')
param usuarioAdmin string

@description('Clave publica SSH del administrador.')
param clavePublicaSsh string

@description('Facility por la que llega el trafico CEF. local4 es la convencion.')
param facilityCef string = 'local4'

@description('Facilidades de syslog a recoger.')
param facilidades array = [
  'auth'
  'authpriv'
  'daemon'
  'kern'
  'syslog'
  'user'
]

var nombreVm = '${prefijo}-FWD01'
var nombreDcr = 'DCR-${prefijo}-Syslog'

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${nombreVm}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnetId
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: ipPrivada
          // Sin IP publica por diseno: menos superficie y una direccion menos
          // consumiendo cuota.
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: nombreVm
  location: location
  // AMA autentica con identidad administrada. Sin ella el agente se instala,
  // arranca y no entrega ni una fila: Microsoft lo exige de forma explicita
  // para maquinas virtuales de Azure.
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: tamanoVm
    }
    priority: usarSpot ? 'Spot' : 'Regular'
    // Deallocate conserva la maquina: si la desalojan basta con arrancarla.
    evictionPolicy: usarSpot ? 'Deallocate' : null
    billingProfile: usarSpot ? {
      maxPrice: -1
    } : null
    osProfile: {
      computerName: 'FWD01'
      adminUsername: usuarioAdmin
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${usuarioAdmin}/.ssh/authorized_keys'
              keyData: clavePublicaSsh
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: nombreDcr
  location: locationWorkspace
  kind: 'Linux'
  properties: {
    dataSources: {
      syslog: [
        {
          // Syslog corriente: aterriza en la tabla Syslog.
          name: 'syslog-lab'
          streams: [ 'Microsoft-Syslog' ]
          facilityNames: facilidades
          logLevels: [
            'Warning'
            'Error'
            'Critical'
            'Alert'
            'Emergency'
          ]
        }
        {
          // CEF es un stream distinto y aterriza en otra tabla,
          // CommonSecurityLog. Con solo Microsoft-Syslog los mensajes CEF
          // llegarian como texto plano a Syslog y no se parsearian.
          // Por convencion el trafico CEF viaja por la facility local4.
          name: 'cef-lab'
          streams: [ 'Microsoft-CommonSecurityLog' ]
          facilityNames: [ facilityCef ]
          logLevels: [
            'Info'
            'Notice'
            'Warning'
            'Error'
            'Critical'
            'Alert'
            'Emergency'
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
        streams: [ 'Microsoft-Syslog' ]
        destinations: [ 'destino-workspace' ]
      }
      {
        streams: [ 'Microsoft-CommonSecurityLog' ]
        destinations: [ 'destino-workspace' ]
      }
    ]
  }
}

resource agente 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vm
  name: 'AzureMonitorLinuxAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorLinuxAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}

resource asociacion 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  name: 'dcra-${nombreVm}'
  scope: vm
  properties: {
    dataCollectionRuleId: dcr.id
  }
  dependsOn: [ agente ]
}

// AMA crea 10-azuremonitoragent-omfwd.conf. Solo despues se abren los
// listeners; asi GDAT no compite con el reenvio a 28330 que gestiona el agente.
resource configurarCef 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  parent: vm
  name: 'configurar-cef'
  location: location
  properties: {
    source: {
      script: loadTextContent('../scripts/configure-cef.sh')
    }
    timeoutInSeconds: 1800
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [ asociacion ]
}

output vmName string = vm.name
output ipPrivada string = ipPrivada
output dcrId string = dcr.id
