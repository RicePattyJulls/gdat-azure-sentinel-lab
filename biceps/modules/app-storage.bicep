/*
  Fase 5 · NovaShop, cuenta de almacenamiento y diagnostic settings
  El codigo de la aplicacion se publica en la fase 6.
  Cobertura Bicep: ~85%. El codigo de la aplicacion se publica aparte.

  Dos categorias de log distintas y las dos hacen falta: AppServiceHTTPLogs da
  la peticion vista desde fuera, AppServiceConsoleLogs lo que la aplicacion
  escribe por dentro.
*/

@description('Region de los recursos de aplicacion.')
param location string

@description('Prefijo de nombres.')
param prefijo string

@description('Sufijo unico para la cuenta de almacenamiento. Su nombre es global en todo Azure.')
param sufijoUnico string = uniqueString(resourceGroup().id)

@description('ID del workspace destino de los diagnostic settings.')
param workspaceId string

@description('IP publica autorizada a alcanzar NovaShop, en CIDR.')
param ipAdmin string

@description('SKU del plan de App Service.')
param skuPlan string = 'B1'

@description('Contenedor destino de la exfiltracion. El ataque escribe en este nombre.')
param nombreContenedor string = 'exfil'

@description('Modo laboratorio de NovaShop. Con on, la aplicacion expone la ruta vulnerable.')
@allowed([ 'on', 'off' ])
param modoLab string = 'on'

var nombrePlan = '${prefijo}-plan'
var nombreApp = '${prefijo}-novashop-${sufijoUnico}'
// Las cuentas de almacenamiento solo admiten minusculas y digitos, 24 caracteres.
var nombreStorage = toLower(take('${replace(prefijo, '-', '')}gdat${sufijoUnico}', 24))

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: nombrePlan
  location: location
  sku: {
    name: skuPlan
  }
  kind: 'linux'
  properties: {
    reserved: true
  }
}

resource app 'Microsoft.Web/sites@2023-12-01' = {
  name: nombreApp
  location: location
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.12'
      appSettings: [
        {
          // La aplicacion solo expone la ruta vulnerable con este ajuste en on.
          // El codigo de NovaShop se publica aparte: Bicep crea el App Service
          // y su configuracion, no el contenido.
          name: 'NOVASHOP_LAB_MODE'
          value: modoLab
        }
        {
          name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value: 'true'
        }
      ]
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      // Lista blanca: solo la IP de administracion. App Service aplica un Deny
      // implicito para todo lo demas.
      ipSecurityRestrictions: [
        {
          ipAddress: ipAdmin
          action: 'Allow'
          priority: 100
          name: 'Permitir-Admin'
        }
      ]
      // Kudu/SCM hereda exactamente la misma lista blanca. Dejar el sitio
      // restringido y el endpoint de despliegue abierto anularia el control.
      scmIpSecurityRestrictionsUseMain: true
    }
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: nombreStorage
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

// El nombre importa: el paso de exfiltracion del ataque escribe en 'exfil'.
// Un contenedor con otro nombre deja la cadena rota en el ultimo eslabon.
resource contenedor 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: nombreContenedor
  properties: {
    // Sin acceso publico: el destino de la exfiltracion no debe ser legible
    // desde Internet, porque lo que se estudia es el rastro, no el dato.
    publicAccess: 'None'
  }
}

resource diagApp 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: app
  name: 'diag-novashop'
  properties: {
    workspaceId: workspaceId
    logs: [
      {
        category: 'AppServiceHTTPLogs'
        enabled: true
      }
      {
        category: 'AppServiceConsoleLogs'
        enabled: true
      }
      {
        category: 'AppServiceAppLogs'
        enabled: true
      }
      {
        category: 'AppServiceAuditLogs'
        enabled: true
      }
    ]
  }
}

resource diagBlob 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: blobService
  name: 'diag-blob'
  properties: {
    workspaceId: workspaceId
    logs: [
      {
        category: 'StorageRead'
        enabled: true
      }
      {
        category: 'StorageWrite'
        enabled: true
      }
      {
        category: 'StorageDelete'
        enabled: true
      }
    ]
  }
}

output appName string = app.name
output appUrl string = 'https://${app.properties.defaultHostName}'
output storageName string = storage.name
output nombreContenedor string = contenedor.name
