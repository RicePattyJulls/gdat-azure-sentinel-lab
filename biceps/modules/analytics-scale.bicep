/*
  Fase 19 · Summary rules

  Esta plantilla declara la parte ARM de la fase: la summary rule. El onboarding
  irreversible del data lake, el KQL job y el notebook requieren el portal de
  Defender/VS Code y quedan como pasos comprobables en BUILD_GDAT.md.
*/

@description('Nombre del workspace.')
param nombreWorkspace string

@description('Crear la summary rule.')
param conSummaryRules bool = false

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: nombreWorkspace
}

// Campana agregada por cuenta y por hora, exactamente el contrato de la fase 19.
resource resumenCampana 'Microsoft.OperationalInsights/workspaces/summaryLogs@2025-07-01' = if (conSummaryRules) {
  parent: workspace
  name: 'CampanaPorCuentaHora'
  properties: {
    ruleType: 'User'
    displayName: 'Campana por cuenta y hora'
    description: 'Agrega alertas por entidad cuenta en ventanas horarias para la cronologia de la fase 19.'
    ruleDefinition: {
      binSize: 60
      // Cinco minutos para absorber latencia de ingesta.
      binDelay: 5
      destinationTable: 'CampanaResumen_CL'
      timeSelector: 'TimeGenerated'
      query: 'SecurityAlert | extend Entidades = todynamic(Entities) | mv-apply Entidad = Entidades on (where tolower(tostring(Entidad.Type)) == "account" | extend Cuenta = tolower(tostring(Entidad.Name))) | summarize Alertas = count(), Reglas = make_set(AlertName), PrimerEvento = min(TimeGenerated), UltimoEvento = max(TimeGenerated) by Cuenta, bin(TimeGenerated, 1h)'
    }
  }
}

output summaryRulesActivas bool = conSummaryRules
output tablaResumen string = conSummaryRules ? 'CampanaResumen_CL' : ''
