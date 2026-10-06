/*
  Fase 5 · DC01, promocion del bosque y auditoria
  Cobertura Bicep: ~60%. La VM y su red son declarativas; la promocion, la
  poblacion de AD y la auditoria ocurren dentro del sistema operativo.

  Los tres runCommand estan separados a proposito. La promocion reinicia la
  maquina, asi que su comando termina en error de conexion y eso es normal:
  por eso lleva treatFailureAsDeploymentFailure en false. El segundo comando es
  la puerta de validacion real, y no da por bueno el dominio hasta que DNS,
  Kerberos y LDAP responden.
*/

@description('Region de la VM.')
param location string

@description('Prefijo de nombres.')
param prefijo string

@description('ID de la subnet donde se engancha la NIC.')
param subnetId string

@description('IP privada fija del controlador. El resto del lab la usa como DNS.')
param ipPrivada string = '10.10.1.4'

@description('Tamano de la VM. Con la cuota del laboratorio, dos vCPU.')
param tamanoVm string = 'Standard_B2as_v2'

@description('Nombre DNS del dominio.')
param nombreDominio string = 'novashop.local'

@description('Nombre NetBIOS del dominio.')
param netbiosDominio string = 'NOVASHOP'

@description('SKU de la imagen de Windows Server.')
param skuImagen string = '2025-datacenter-azure-edition'

@description('Version de la imagen. Poner una version concreta para que dos despliegues den la misma maquina.')
param versionImagen string = 'latest'

@description('Usuario administrador local. Sera el Domain Admin tras la promocion.')
param usuarioAdmin string

@description('Contrasena del administrador local.')
@secure()
param passwordAdmin string

@description('Contrasena del modo de restauracion de servicios de directorio.')
@secure()
param passwordDsrm string

@description('Crear IP publica para el acceso administrativo inicial.')
param conIpPublica bool = true

@description('Contrasena comun de las cuentas de negocio del escenario.')
@secure()
param passwordNegocio string

@description('Contrasena de charlie.dev, la credencial que se planta en NovaShop.')
@secure()
param passwordCharlie string

@description('Contrasena de svc-sql. Debil a proposito: es el objetivo del Kerberoasting.')
@secure()
param passwordSvcSql string

@description('Contrasena de svc-backup.')
@secure()
param passwordSvcBackup string

@description('Accion de las reglas ASR. 2 es Audit, 1 es Block.')
@allowed([ 0, 1, 2, 6 ])
param accionAsr int = 2

var nombreVm = '${prefijo}-DC01'

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
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnetId
          }
          // Estatica: el DC es servidor DNS del dominio y su direccion no puede
          // cambiar entre reinicios.
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
      computerName: 'DC01'
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

// --- Etapa A.1 · promocion -------------------------------------------------
// El reinicio corta la sesion del agente. El fallo aqui es esperado.
resource promocion 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  parent: vm
  name: 'promover-dc'
  location: location
  properties: {
    source: {
      script: loadTextContent('../scripts/configure-dc.ps1')
    }
    parameters: [
      {
        name: 'NombreDominio'
        value: nombreDominio
      }
      {
        name: 'NetbiosDominio'
        value: netbiosDominio
      }
    ]
    protectedParameters: [
      {
        name: 'PasswordDsrm'
        value: passwordDsrm
      }
    ]
    timeoutInSeconds: 3600
    treatFailureAsDeploymentFailure: false
  }
}

// --- Etapa A.2 · puerta de validacion --------------------------------------
// Aqui si importa el resultado: si el dominio no responde, la etapa B no debe
// arrancar.
resource esperarAd 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  parent: vm
  name: 'esperar-ad'
  location: location
  properties: {
    source: {
      script: loadTextContent('../scripts/wait-ad.ps1')
    }
    parameters: [
      {
        name: 'NombreDominio'
        value: nombreDominio
      }
    ]
    timeoutInSeconds: 2400
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [ promocion ]
}

// --- Etapa A.3 · auditoria y SACL ------------------------------------------
resource auditoria 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  parent: vm
  name: 'configurar-auditoria'
  location: location
  properties: {
    source: {
      script: loadTextContent('../scripts/configure-audit.ps1')
    }
    timeoutInSeconds: 1800
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [ esperarAd ]
}

// --- Etapa A.4 · identidades del escenario ---------------------------------
resource cadena 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  parent: vm
  name: 'plantar-cadena'
  location: location
  properties: {
    source: {
      script: loadTextContent('../scripts/plant-chain.ps1')
    }
    protectedParameters: [
      {
        name: 'PasswordNegocio'
        value: passwordNegocio
      }
      {
        name: 'PasswordCharlie'
        value: passwordCharlie
      }
      {
        name: 'PasswordSvcSql'
        value: passwordSvcSql
      }
      {
        name: 'PasswordSvcBackup'
        value: passwordSvcBackup
      }
    ]
    timeoutInSeconds: 1800
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [ auditoria ]
}

// --- Etapa A.5 · reglas ASR ------------------------------------------------
// En Audit por defecto: primero se mide, despues se bloquea.
resource asr 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  parent: vm
  name: 'configurar-asr'
  location: location
  properties: {
    source: {
      script: loadTextContent('../scripts/configure-asr.ps1')
    }
    parameters: [
      {
        name: 'Accion'
        value: string(accionAsr)
      }
    ]
    timeoutInSeconds: 1800
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [ cadena ]
}

output vmId string = vm.id
output vmName string = vm.name
output ipPrivada string = ipPrivada
output ipPublica string = ipPublica.?properties.ipAddress ?? ''
