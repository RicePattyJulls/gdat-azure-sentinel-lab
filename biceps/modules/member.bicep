/*
  Fase 5 · MEMBER01, la estacion de trabajo del escenario
  Cobertura Bicep: ~75%. VM y red declarativas; el domain join va por extension.

  El orden importa: MEMBER01 se une al dominio ANTES de que MDE la onboardee.
  Al reves, la maquina se registra primero como equipo de Workgroup y arrastra
  esa identidad en el inventario junto a la del dominio.

  Se usa JsonADDomainExtension y no un runCommand porque la extension gestiona
  ella misma el reinicio y el reintento del join.
*/

@description('Region de la VM.')
param location string

@description('Prefijo de nombres.')
param prefijo string

@description('ID de la subnet.')
param subnetId string

@description('IP privada fija.')
param ipPrivada string = '10.10.1.5'

@description('IP del controlador de dominio, que actua como servidor DNS.')
param ipDns string

@description('Tamano de la VM.')
param tamanoVm string = 'Standard_B2as_v2'

@description('Nombre DNS del dominio al que unirse.')
param nombreDominio string = 'novashop.local'

@description('Nombre NetBIOS del dominio, para el grupo local de escritorio remoto.')
param netbiosDominio string = 'NOVASHOP'

@description('SKU de la imagen de Windows Server.')
param skuImagen string = '2025-datacenter-azure-edition'

@description('Version de la imagen. Poner una version concreta para que dos despliegues den la misma maquina.')
param versionImagen string = 'latest'

@description('Usuario administrador local.')
param usuarioAdmin string

@description('Contrasena del administrador local.')
@secure()
param passwordAdmin string

@description('Cuenta con permiso para unir equipos al dominio, en formato UPN o DOMINIO\\usuario.')
param usuarioJoin string

@description('Contrasena de la cuenta que une al dominio.')
@secure()
param passwordJoin string

@description('Crear IP publica para el acceso administrativo inicial.')
param conIpPublica bool = true

var nombreVm = '${prefijo}-MEMBER01'

// 3 = JOIN_DOMAIN (1) + ACCT_CREATE (2). Crea la cuenta de equipo si no existe.
var opcionesJoin = 3

resource ipPublica 'Microsoft.Network/publicIPAddresses@2024-05-01' = if (conIpPublica) {
  name: '${nombreVm}-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${nombreVm}-nic'
  location: location
  properties: {
    // Sin este DNS la maquina no resuelve el dominio y el join falla.
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
          publicIPAddress: conIpPublica ? {
            id: ipPublica.id
          } : null
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
    osProfile: {
      computerName: 'MEMBER01'
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
      Options: opcionesJoin
    }
    protectedSettings: {
      Password: passwordJoin
    }
  }
}

// Fase 5 · lo que se planta en el endpoint. Va despues del join: la cuenta de
// dominio tiene que resolverse para poder anadirla al grupo local.
resource plantarEndpoint 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  parent: vm
  name: 'plantar-endpoint'
  location: location
  properties: {
    source: {
      script: loadTextContent('../scripts/plant-endpoint.ps1')
    }
    parameters: [
      {
        name: 'Netbios'
        value: netbiosDominio
      }
    ]
    timeoutInSeconds: 1800
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [ domainJoin ]
}

output vmId string = vm.id
output vmName string = vm.name
output ipPrivada string = ipPrivada
output ipPublica string = ipPublica.?properties.ipAddress ?? ''
