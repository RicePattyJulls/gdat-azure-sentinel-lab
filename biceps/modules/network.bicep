/*
  Fase 5 · Red del laboratorio
  Cobertura Bicep: 100%. VNet, subnet y NSG son ARM puro.

  La subnet nace con defaultOutboundAccess en false: sin salida implicita a
  internet. Las VM que necesiten actualizarse salen por su IP publica, y las que
  no la tengan quedan sin salida por diseno.
*/

@description('Region de las VM del laboratorio.')
param location string

@description('Prefijo de nombres. Permite levantar el lab dos veces sin colisionar.')
param prefijo string

@description('IP publica desde la que se administra el laboratorio, en formato CIDR /32.')
param ipAdmin string

@description('Espacio de direcciones de la VNet.')
param espacioVnet string = '10.10.0.0/16'

@description('Rango de la subnet del laboratorio.')
param rangoSubnet string = '10.10.1.0/24'

@description('Desplegar NAT Gateway para dar salida a las VM sin IP publica.')
param conNatGateway bool = true

var nombreVnet = '${prefijo}-vnet'
var nombreSubnet = 'SN-LAB'
var nombreNsg = '${prefijo}-nsg'

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: nombreNsg
  location: location
  properties: {
    securityRules: [
      {
        // RDP solo desde la IP de administracion. Un origen '*' deja el
        // laboratorio abierto a internet entero.
        name: 'Permitir-RDP-Admin'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefix: ipAdmin
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Allow'
          priority: 300
          direction: 'Inbound'
        }
      }
      {
        name: 'Permitir-SSH-Admin'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: ipAdmin
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Allow'
          priority: 310
          direction: 'Inbound'
        }
      }
      {
        // Cierre explicito. El Deny por defecto de Azure tiene prioridad 65500;
        // dejarlo escrito documenta la intencion y sobrevive a reglas nuevas.
        name: 'Denegar-Resto-Internet'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
          access: 'Deny'
          priority: 4000
          direction: 'Inbound'
        }
      }
    ]
  }
}

/*
  Salida a Internet.

  La subnet nace con defaultOutboundAccess en false, asi que una VM sin IP
  publica se queda sin salida: no puede instalar paquetes ni, sobre todo,
  alcanzar los endpoints de Azure Monitor. El agente quedaria instalado y mudo.

  El NAT Gateway da esa salida sin exponer ninguna VM a Internet entrante, que
  es justo lo que interesa para WEC01 y FWD01. Tiene coste por hora y por dato
  procesado: se puede apagar con conNatGateway y dar IP publica en su lugar,
  aceptando la exposicion.
*/

resource ipNat 'Microsoft.Network/publicIPAddresses@2024-05-01' = if (conNatGateway) {
  name: '${prefijo}-nat-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2024-05-01' = if (conNatGateway) {
  name: '${prefijo}-nat'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [
      {
        id: ipNat!.id
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: nombreVnet
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [ espacioVnet ]
    }
    subnets: [
      {
        name: nombreSubnet
        properties: {
          addressPrefix: rangoSubnet
          defaultOutboundAccess: false
          natGateway: conNatGateway ? {
            id: natGateway!.id
          } : null
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

@description('ID de la subnet donde se enganchan todas las NIC del laboratorio.')
output subnetId string = vnet.properties.subnets[0].id

@description('ID del NSG, por si un modulo necesita anadir reglas.')
output nsgId string = nsg.id

output vnetName string = vnet.name

@description('IP publica de salida del NAT. Es la que veran los servicios externos.')
output ipSalida string = ipNat.?properties.ipAddress ?? ''
