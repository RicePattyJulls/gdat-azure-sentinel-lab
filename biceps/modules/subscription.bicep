/*
  Fase 5 · Defender for Cloud, plan Servers P2
  La puerta real de onboarding de MDE es la fase 7.
  Cobertura Bicep: ~70%. El plan es declarativo; el onboarding real de MDE en
  cada maquina es asincrono y no termina cuando ARM devuelve.

  P2 solo se activa a nivel de SUSCRIPCION, por eso este modulo tiene ese scope.
  P1 si admite alcance de recurso, pero pierde FIM, agentless scanning y el
  beneficio de ingesta de 500 MB por maquina y dia.
*/

targetScope = 'subscription'

@description('ID del workspace donde P2 guarda FIM y aplica el beneficio de ingesta.')
param workspaceId string

@description('Activar tambien el plan de Storage. Cuesta aparte.')
param conPlanStorage bool = false

/*
  File Integrity Monitoring queda fuera por defecto.

  La extension no se conforma con el workspace: exige ademas una propiedad Rules
  con la configuracion de que rutas y claves de registro vigilar. Es una
  estructura propia, sin equivalente documentado en plantilla, y FIM no
  interviene en ninguna parte de la cadena de ataque del laboratorio.

  Se activa desde el portal si algun dia hace falta:
    Defender for Cloud > Environment settings > la suscripcion > Settings >
    File Integrity Monitoring
*/
@description('Activar File Integrity Monitoring. Requiere configurar Rules a mano.')
param conFim bool = false

@description('Activar el escaneo sin agente de las VM.')
param conAgentlessScanning bool = true

resource planServidores 'Microsoft.Security/pricings@2024-01-01' = {
  name: 'VirtualMachines'
  properties: {
    pricingTier: 'Standard'
    subPlan: 'P2'
    // Solo se declaran las extensiones que se quieren encendidas. Declarar una
    // con isEnabled False y propiedades incompletas hace fallar el despliegue
    // igual que si estuviera encendida.
    extensions: union(
      [
        {
          name: 'AgentlessVmScanning'
          isEnabled: conAgentlessScanning ? 'True' : 'False'
        }
      ],
      conFim ? [
        {
          name: 'FileIntegrityMonitoring'
          isEnabled: 'True'
          additionalExtensionProperties: {
            // Se llama DefinedWorkspaceId, no WorkspaceId. Y ademas exige Rules,
            // que es lo que hace que esto no sea practico por plantilla.
            DefinedWorkspaceId: workspaceId
          }
        }
      ] : []
    )
  }
}

resource planStorage 'Microsoft.Security/pricings@2024-01-01' = if (conPlanStorage) {
  name: 'StorageAccounts'
  properties: {
    pricingTier: 'Standard'
    subPlan: 'DefenderForStorageV2'
  }
}

output planServidoresTier string = planServidores.properties.pricingTier
