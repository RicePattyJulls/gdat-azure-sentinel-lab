/*
  Fase 5 · Content Hub
  Cobertura Bicep: ~95%.

  Los paquetes se fijan por ID y version a proposito. Un 'latest' implicito
  convierte cada despliegue en una tirada distinta y rompe la reproducibilidad,
  que es justo lo que se busca al pasar el laboratorio a IaC.
*/

@description('Nombre del workspace con Sentinel habilitado.')
param nombreWorkspace string

@description('Paquetes del Content Hub a instalar: objetos con contentId, displayName y version.')
param paquetes array = [
  {
    contentId: 'azuresentinel.azure-sentinel-solution-securitythreatessentialsol'
    displayName: 'Threat Essentials'
    version: '3.0.3'
  }
  {
    contentId: 'azuresentinel.azure-sentinel-solution-azureactivedirectory'
    displayName: 'Microsoft Entra ID'
    version: '3.3.16'
  }
  {
    contentId: 'azuresentinel.azure-sentinel-solution-microsoftdefenderendpoint'
    displayName: 'Microsoft Defender for Endpoint'
    version: '3.0.6'
  }
  {
    contentId: 'azuresentinel.azure-sentinel-solution-securityevents'
    displayName: 'Windows Security Events'
    version: '3.0.13'
  }
]

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: nombreWorkspace
}

resource paquete 'Microsoft.SecurityInsights/contentPackages@2024-03-01' = [for p in paquetes: {
  name: p.contentId
  scope: workspace
  properties: {
    contentId: p.contentId
    contentKind: 'Solution'
    displayName: p.displayName
    version: p.version
    // Algoritmo publicado por los paquetes oficiales del catalogo.
    contentProductId: '${take(p.contentId, 50)}-sl-${uniqueString(format('{0}-Solution-{0}-{1}', p.contentId, p.version))}'
    contentSchemaVersion: '3.0.0'
  }
}]

output paquetesInstalados int = length(paquetes)
