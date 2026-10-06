/*
  Fase 15 · WEC01, colector de Windows Event Forwarding
  La suscripcion se crea por script porque no existe un recurso ARM para WEF.
  El modulo configura por separado el colector, la GPO en DC01 y cada origen.

  WEC01 se despliega como Spot: es un colector, tolera el desalojo y cuesta una
  fraccion. La serie B no admite Spot, de ahi la familia D. Politica de desalojo
  Deallocate para que la maquina se conserve y baste con arrancarla de nuevo.

  El agente lee ForwardedEvents, que no es un canal de Security: por eso lleva
  su propia DCR con el stream de Windows Event y no la de SecurityEvent.
*/

@description('Region de la VM.')
param location string

@description('Region del workspace, donde va la DCR.')
param locationWorkspace string

@description('Prefijo de nombres.')
param prefijo string

@description('ID de la subnet.')
param subnetId string

@description('IP privada fija del colector.')
param ipPrivada string = '10.10.1.6'

@description('IP del controlador de dominio, que actua como DNS.')
param ipDns string

@description('ID del workspace destino.')
param workspaceId string

@description('Tamano de la VM. Spot exige familia D como minimo.')
param tamanoVm string = 'Standard_D2as_v5'

@description('Desplegar como Spot. Reduce el coste a cambio de aceptar desalojos.')
param usarSpot bool = true

@description('Nombre del dominio.')
param nombreDominio string = 'novashop.local'

@description('Nombre NetBIOS del dominio.')
param netbiosDominio string = 'NOVASHOP'

@description('Nombre del recurso VM de DC01 ya desplegado.')
param nombreVmDc string

@description('Nombre del recurso VM de MEMBER01 ya desplegado.')
param nombreVmMember string

@description('SKU de la imagen de Windows Server.')
param skuImagen string = '2025-datacenter-azure-edition'

@description('Version de la imagen. Poner una version concreta para que dos despliegues den la misma maquina.')
param versionImagen string = 'latest'

@description('Usuario administrador local.')
param usuarioAdmin string

@description('Contrasena del administrador local.')
@secure()
param passwordAdmin string

@description('Cuenta con permiso para unir equipos al dominio.')
param usuarioJoin string

@description('Contrasena de la cuenta que une al dominio.')
@secure()
param passwordJoin string

@description('Marca UTC que fuerza a reconverger colector y origenes en cada despliegue.')
param marcaEjecucion string

var nombreVm = '${prefijo}-WEC01'
var nombreDcr = 'DCR-${prefijo}-WEF'

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${nombreVm}-nic'
  location: location
  properties: {
    dnsSettings: {
      dnsServers: [ ipDns ]
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnetId
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: ipPrivada
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
      computerName: 'WEC01'
      adminUsername: usuarioAdmin
      adminPassword: passwordAdmin
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: skuImagen
        // Por defecto va 'latest', que es comodo pero hace que dos despliegues
        // del mismo codigo den maquinas distintas. Para reproducibilidad real
        // hay que pasar una version concreta en versionImagen.
        version: versionImagen
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

resource domainJoin 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vm
  name: 'JoinDominio'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'JsonADDomainExtension'
    typeHandlerVersion: '1.3'
    autoUpgradeMinorVersion: true
    settings: {
      Name: nombreDominio
      User: usuarioJoin
      Restart: 'true'
      Options: 3
    }
    protectedSettings: {
      Password: passwordJoin
    }
  }
}

resource suscripcionWef 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  parent: vm
  name: 'configurar-wef'
  location: location
  properties: {
    source: {
      script: loadTextContent('../scripts/configure-wef.ps1')
    }
    parameters: [
      {
        name: 'MarcaEjecucion'
        value: marcaEjecucion
      }
    ]
    timeoutInSeconds: 1800
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [ domainJoin ]
}

resource dcExistente 'Microsoft.Compute/virtualMachines@2024-07-01' existing = {
  name: nombreVmDc
}

resource memberExistente 'Microsoft.Compute/virtualMachines@2024-07-01' existing = {
  name: nombreVmMember
}

// GroupPolicy/ActiveDirectory existen en DC01. Este runCommand no usa SYSTEM:
// una cuenta de equipo no puede crear ni enlazar GPO de dominio.
resource configurarDominio 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  parent: dcExistente
  name: 'configurar-wef-dominio'
  location: location
  properties: {
    source: {
      script: loadTextContent('../scripts/configure-wef-dominio.ps1')
    }
    parameters: [
      {
        name: 'Modo'
        value: 'Dominio'
      }
      {
        name: 'FqdnColector'
        value: 'WEC01.${nombreDominio}'
      }
      {
        name: 'MarcaEjecucion'
        value: marcaEjecucion
      }
    ]
    runAsUser: '${netbiosDominio}\\${usuarioAdmin}'
    runAsPassword: passwordAdmin
    timeoutInSeconds: 1800
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [ suscripcionWef ]
}

// En el origen solo se necesitan privilegios locales; SYSTEM es la identidad
// correcta. La GPO ya existe cuando se fuerza gpupdate.
resource configurarMember 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  parent: memberExistente
  name: 'configurar-wef-origen'
  location: location
  properties: {
    source: {
      script: loadTextContent('../scripts/configure-wef-dominio.ps1')
    }
    parameters: [
      {
        name: 'Modo'
        value: 'Origen'
      }
      {
        name: 'MarcaEjecucion'
        value: marcaEjecucion
      }
    ]
    timeoutInSeconds: 1800
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [ configurarDominio ]
}

// ForwardedEvents no es Security: va por el stream de Windows Event.
resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: nombreDcr
  location: locationWorkspace
  kind: 'Windows'
  properties: {
    dataSources: {
      windowsEventLogs: [
        {
          name: 'eventos-reenviados'
          streams: [ 'Microsoft-WindowsEvent' ]
          xPathQueries: [ 'ForwardedEvents!*' ]
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
        streams: [ 'Microsoft-WindowsEvent' ]
        destinations: [ 'destino-workspace' ]
      }
    ]
  }
}

resource agente 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vm
  name: 'AzureMonitorWindowsAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorWindowsAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
  dependsOn: [ domainJoin ]
}

resource asociacion 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  name: 'dcra-${nombreVm}'
  scope: vm
  properties: {
    dataCollectionRuleId: dcr.id
  }
  dependsOn: [ agente ]
}

output vmName string = vm.name
output ipPrivada string = ipPrivada
output dcrId string = dcr.id
output fqdn string = 'WEC01.${nombreDominio}'
output principalId string = vm.identity.principalId
