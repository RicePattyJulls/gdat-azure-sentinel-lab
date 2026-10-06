/*
  Fase 18 · Threat Intelligence
  Cobertura Bicep: ~75%. El conector TAXII y la solucion son ARM; subir
  indicadores por la Upload API no lo es.

  No necesita ninguna maquina virtual.

  El conector queda desactivado por defecto: un feed TAXII mal elegido llena la
  tabla de indicadores y empuja el coste sin aportar deteccion. Se enciende
  cuando hay un feed concreto que se quiere probar.
*/

@description('Nombre del workspace con Sentinel habilitado.')
param nombreWorkspace string

@description('Crear el conector TAXII. Requiere un servidor y una coleccion reales.')
param conConectorTaxii bool = false

@description('URL raiz del servidor TAXII.')
param servidorTaxii string = ''

@description('ID de la coleccion TAXII a consumir.')
param coleccionTaxii string = ''

@description('Nombre visible del feed.')
param nombreFeed string = 'Feed TAXII del laboratorio'

@description('Usuario del servidor TAXII, si lo pide.')
param usuarioTaxii string = ''

@description('Contrasena del servidor TAXII, si lo pide.')
@secure()
param passwordTaxii string = ''

@description('Cada cuanto se consulta el feed.')
@allowed([ 'OnceAMinute', 'OnceAnHour', 'OnceADay' ])
param frecuenciaSondeo string = 'OnceADay'

@description('Periodo historico que importa el conector al arrancar.')
@allowed([ 'OneDay', 'OneWeek', 'OneMonth', 'All' ])
param periodoTaxii string = 'OneDay'

@description('Paquete de la solucion de Threat Intelligence en el Content Hub.')
param paqueteTi object = {
  contentId: 'azuresentinel.azure-sentinel-solution-threatintelligence-taxii'
  displayName: 'Threat Intelligence'
  version: '3.1.3'
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: nombreWorkspace
}

resource solucionTi 'Microsoft.SecurityInsights/contentPackages@2024-03-01' = {
  name: paqueteTi.contentId
  scope: workspace
  properties: {
    contentId: paqueteTi.contentId
    contentKind: 'Solution'
    displayName: paqueteTi.displayName
    version: paqueteTi.version
    contentProductId: '${take(paqueteTi.contentId, 50)}-sl-${uniqueString(format('{0}-Solution-{0}-{1}', paqueteTi.contentId, paqueteTi.version))}'
    contentSchemaVersion: '3.0.0'
  }
}

// Mismo caso que la regla NRT: el kind ThreatIntelligenceTaxii necesita la
// version preview. Con 2023-02-01 el despliegue fallaria con "Unsupported
// api-version for kind".
resource conectorTaxii 'Microsoft.SecurityInsights/dataConnectors@2023-12-01-preview' = if (conConectorTaxii) {
  name: guid(workspace.id, 'taxii', coleccionTaxii)
  scope: workspace
  kind: 'ThreatIntelligenceTaxii'
  properties: {
    workspaceId: workspace.properties.customerId
    // tenantId es obligatorio en este conector.
    tenantId: subscription().tenantId
    friendlyName: nombreFeed
    taxiiServer: servidorTaxii
    collectionId: coleccionTaxii
    userName: usuarioTaxii
    password: passwordTaxii
    taxiiLookbackPeriod: periodoTaxii
    pollingFrequency: frecuenciaSondeo
    dataTypes: {
      taxiiClient: {
        state: 'Enabled'
      }
    }
  }
  dependsOn: [ solucionTi ]
}

output solucionInstalada string = solucionTi.name
output conectorActivo bool = conConectorTaxii
