/*
  Laboratorio GDAT · despliegue reproducible
  ==========================================

  Este fichero no es una traduccion literal del documento: es la version
  declarativa del laboratorio que describen las fases 1 a 21. Las fases 10 y 20
  son ataques y no se despliegan.

  Lo que Bicep NO puede reproducir, y se activa encima a mano:

    - el sensor de MDI, que se enciende desde el portal de Defender
    - las politicas de MDO y MDCA, que van por APIs propias de Microsoft 365
    - los usuarios de Entra y la asignacion de licencias E5
    - conectar el workspace como Primary en Defender
    - todo lo de Purview

  Sobre el orden: dependsOn garantiza que ARM termino de desplegar un recurso.
  No demuestra que el DC reinicio, que Kerberos responde, que MDE termino de
  onboardear ni que una tabla de Sentinel existe. Por eso el despliegue va por
  etapas con puertas de validacion reales, y por eso deploy.sh existe: las
  esperas que consultan estado no caben dentro de una plantilla.
*/

targetScope = 'subscription'

// ---------------------------------------------------------------------------
// Parametros generales
// ---------------------------------------------------------------------------

@description('Prefijo de todos los nombres. Permite levantar el lab dos veces sin colisionar.')
@minLength(3)
@maxLength(12)
param prefijo string = 'gdat'

@description('Region de las maquinas virtuales.')
param locationVm string = 'spaincentral'

@description('Region del workspace y de todas las DCR.')
param locationWorkspace string = 'francecentral'

@description('IP publica desde la que se administra el laboratorio, en CIDR /32.')
param ipAdmin string

@description('Usuario administrador de las maquinas Windows.')
param usuarioAdmin string = 'gdatadmin'

@description('Contrasena del administrador local de las maquinas.')
@secure()
param passwordAdmin string

@description('Contrasena del modo de restauracion de directorio del DC.')
@secure()
param passwordDsrm string

@description('Contrasena comun de las cuentas de negocio.')
@secure()
param passwordNegocio string

@description('Contrasena de charlie.dev.')
@secure()
param passwordCharlie string

@description('Contrasena de svc-sql.')
@secure()
param passwordSvcSql string

@description('Contrasena de svc-backup.')
@secure()
param passwordSvcBackup string

@description('Nombre DNS del dominio.')
param nombreDominio string = 'novashop.local'

@description('Nombre NetBIOS del dominio.')
param netbiosDominio string = 'NOVASHOP'

/*
  Nombre del workspace. Se expone porque el borrado de un workspace de Log
  Analytics es blando: reserva el nombre durante 14 dias. Si se acaba de borrar
  uno con este mismo nombre, la creacion falla por conflicto aunque el recurso ya
  no se vea en el portal.

  Dos salidas: borrar el anterior de forma permanente con --force, que libera el
  nombre al momento, o cambiar este parametro.
*/
@description('Nombre del workspace. Cambiarlo si el anterior sigue en periodo de borrado blando.')
param nombreWorkspace string = 'log-${prefijo}-soc'

// ---------------------------------------------------------------------------
// Interruptores de alcance
// ---------------------------------------------------------------------------
// El laboratorio completo no cabe en la cuota de una suscripcion de prueba.
// Estos interruptores permiten levantar solo lo que se va a usar.

@description('Etapa A: red, DC01 y MEMBER01. Consume 4 vCPU.')
param conBase bool = true

@description('Etapa B: NovaShop, storage, Defender for Servers y telemetria.')
param conInstrumentacion bool = true

@description('File Integrity Monitoring. Exige configurar Rules a mano, y no interviene en la cadena de ataque.')
param conFim bool = false

@description('Etapa C: reglas analiticas y automation rules.')
param conDetecciones bool = true

// contentProductId usa el algoritmo publicado por los paquetes oficiales. Las
// reglas propias siguen sin depender de estas soluciones.
@description('Instalar las cuatro soluciones fijadas del Content Hub.')
param conContentHub bool = true

@description('Fase 15: WEC01, colector de eventos reenviados. Consume 2 vCPU mas.')
param conWec bool = false

@description('Marca que fuerza a ejecutar de nuevo la puerta WEF en cada despliegue.')
param marcaValidacionWec string = utcNow('yyyyMMddHHmmss')

@description('Fase 16: FWD01, forwarder de Syslog y CEF. Consume 1 vCPU mas.')
param conForwarder bool = false

@description('Fase 17: DCE, tabla _CL y transformaciones. No consume vCPU.')
param conLogsPersonalizados bool = false

@description('Fase 18: Threat Intelligence. No consume vCPU.')
param conThreatIntel bool = false

@description('Activar el conector TAXII. Necesita servidor y coleccion reales.')
param conConectorTaxii bool = false

@description('URL raiz del servidor TAXII.')
param servidorTaxii string = ''

@description('ID de la coleccion TAXII.')
param coleccionTaxii string = ''

@description('Usuario del servidor TAXII, si lo pide.')
param usuarioTaxii string = ''

@description('Contrasena del servidor TAXII, si lo pide.')
@secure()
param passwordTaxii string = ''

@description('Historico inicial del conector TAXII.')
@allowed([ 'OneDay', 'OneWeek', 'OneMonth', 'All' ])
param periodoTaxii string = 'OneDay'

@description('Fase 19: summary rules. No consume vCPU.')
param conSummaryRules bool = false

/*
  Presupuesto. Imprescindible en cuanto la suscripcion pasa a pago por uso: el
  credito gratuito caduca a los 30 dias del alta, no al agotarse, y el dia 31 las
  maquinas siguen encendidas a tu cuenta.
*/
@description('Crear Sentinel, UEBA y Entity Analytics. Apagar en redespliegues sobre un workspace que ya los tiene.')
param conUeba bool = true

@description('Crear presupuesto con alertas de coste.')
param conPresupuesto bool = false

@description('Importe del presupuesto, en la moneda de facturacion.')
param importePresupuesto int = 200

@description('Correos que reciben las alertas de coste.')
param correosPresupuesto array = []

@description('Accion de las reglas ASR. 2 es Audit, 1 es Block.')
@allowed([ 0, 1, 2, 6 ])
param accionAsr int = 2

/*
  Las IP publicas tambien tienen cuota, y en una suscripcion de prueba son 3.
  El laboratorio base pide exactamente esas 3: una para el NAT Gateway, una para
  el RDP a DC01 y una para el RDP a MEMBER01.

  Si hiciera falta liberar una, la prescindible es la de DC01: con el NAT ya
  tiene salida, y se administra con az vm run-command. La de MEMBER01 no se
  puede quitar, porque el ataque entra por RDP desde Internet y esa IP es lo que
  une la alerta de la SQLi con la del RDP.
*/
@description('Dar IP publica a DC01 para RDP. Apagarlo libera una IP de cuota.')
param conIpPublicaDc bool = true

@description('Tamano de DC01.')
param tamanoDc string = 'Standard_B2as_v2'

@description('Tamano de MEMBER01. Bajarlo a 1 vCPU libera cuota para FWD01.')
param tamanoMember string = 'Standard_B2as_v2'

@description('Clave publica SSH para FWD01. Solo si conForwarder es true.')
param clavePublicaSsh string = ''

@description('Object IDs que reciben Sentinel Responder.')
param responderObjectIds array = []

@description('Object IDs que reciben Sentinel Contributor.')
param contributorObjectIds array = []

@description('Cuentas de administracion excluidas de las reglas de deteccion.')
param cuentasAdmin array = []

@description('Object ID del principal que enviara datos a la DCR de la fase 17. Sin el, la ingesta responde 403.')
param principalIngestaId string = ''

@description('Tipo del principal de ingesta.')
@allowed([ 'ServicePrincipal', 'User', 'Group' ])
param tipoPrincipalIngesta string = 'ServicePrincipal'

// ---------------------------------------------------------------------------
// Grupos de recursos
// ---------------------------------------------------------------------------
// Separados a proposito: el SOC vive en la region del workspace y sobrevive a
// que se borren las maquinas.

var rgVm = '${prefijo}-vm-lab'
var rgSoc = '${prefijo}-soc'
var ipsAdminArray = [ replace(ipAdmin, '/32', '') ]
var cuentasAdminEfectivas = union(cuentasAdmin, [ usuarioAdmin ])

/*
  StorageBlobLogs no dice que maquina subio el blob, solo desde que IP. Este
  mapa traduce la IP publica de salida al host del laboratorio, y es lo que hace
  que la alerta de exfiltracion comparta entidad Host con las del endpoint y el
  incidente salga unico en vez de partido en dos.

  Con NAT Gateway las dos maquinas salen por la misma IP, asi que el mapa apunta
  al endpoint, que es desde donde se ejecuta la exfiltracion.
*/
var mapaIpHostReal = (conBase && conInstrumentacion) ? {
  '${red!.outputs.ipSalida}': 'member01'
} : {}

resource grupoVm 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgVm
  location: locationVm
}

resource grupoSoc 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgSoc
  location: locationWorkspace
}

// ---------------------------------------------------------------------------
// ETAPA 0 · workspace y Sentinel
// ---------------------------------------------------------------------------
// Va primero y no espera a la etapa A: UEBA necesita que su reloj empiece
// cuanto antes, aunque su ventana util no arranque hasta que lleguen datos.

module workspace 'modules/workspace.bicep' = {
  name: 'etapa0-workspace'
  scope: grupoSoc
  params: {
    location: locationWorkspace
    nombreWorkspace: nombreWorkspace
    conUeba: conUeba
    responderObjectIds: responderObjectIds
    contributorObjectIds: contributorObjectIds
  }
}

// ---------------------------------------------------------------------------
// ETAPA A · red y dominio
// ---------------------------------------------------------------------------

module red 'modules/network.bicep' = if (conBase) {
  name: 'etapaA-red'
  scope: grupoVm
  params: {
    location: locationVm
    prefijo: prefijo
    ipAdmin: ipAdmin
  }
}

module dc 'modules/dc.bicep' = if (conBase) {
  name: 'etapaA-dc'
  scope: grupoVm
  params: {
    location: locationVm
    prefijo: prefijo
    subnetId: red!.outputs.subnetId
    tamanoVm: tamanoDc
    nombreDominio: nombreDominio
    netbiosDominio: netbiosDominio
    usuarioAdmin: usuarioAdmin
    passwordAdmin: passwordAdmin
    passwordDsrm: passwordDsrm
    passwordNegocio: passwordNegocio
    passwordCharlie: passwordCharlie
    passwordSvcSql: passwordSvcSql
    passwordSvcBackup: passwordSvcBackup
    accionAsr: accionAsr
    conIpPublica: conIpPublicaDc
  }
}

// MEMBER01 se une al dominio ANTES de que MDE la onboardee, para que no arrastre
// una identidad previa de Workgroup en el inventario.
module member 'modules/member.bicep' = if (conBase) {
  name: 'etapaA-member'
  scope: grupoVm
  params: {
    location: locationVm
    prefijo: prefijo
    subnetId: red!.outputs.subnetId
    ipDns: dc!.outputs.ipPrivada
    tamanoVm: tamanoMember
    nombreDominio: nombreDominio
    netbiosDominio: netbiosDominio
    usuarioAdmin: usuarioAdmin
    passwordAdmin: passwordAdmin
    usuarioJoin: '${usuarioAdmin}@${nombreDominio}'
    passwordJoin: passwordAdmin
  }
}

// ---------------------------------------------------------------------------
// ETAPA B · cargas e instrumentacion
// ---------------------------------------------------------------------------

module aplicacion 'modules/app-storage.bicep' = if (conInstrumentacion) {
  name: 'etapaB-aplicacion'
  scope: grupoVm
  params: {
    location: locationVm
    prefijo: prefijo
    workspaceId: workspace.outputs.workspaceId
    ipAdmin: ipAdmin
  }
}

// P2 solo se activa a nivel de suscripcion, por eso este modulo no lleva scope
// de grupo de recursos.
module defender 'modules/subscription.bicep' = if (conInstrumentacion) {
  name: 'etapaB-defender'
  params: {
    workspaceId: workspace.outputs.workspaceId
    conFim: conFim
  }
}

module telemetria 'modules/telemetry.bicep' = if (conInstrumentacion && conBase) {
  name: 'etapaB-telemetria'
  scope: grupoVm
  params: {
    location: locationVm
    locationWorkspace: locationWorkspace
    prefijo: prefijo
    workspaceId: workspace.outputs.workspaceId
    maquinas: [
      {
        name: dc!.outputs.vmName
      }
      {
        name: member!.outputs.vmName
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// ETAPA C · contenido de SOC
// ---------------------------------------------------------------------------

module contenido 'modules/content.bicep' = if (conContentHub) {
  name: 'etapaC-contenido'
  scope: grupoSoc
  params: {
    nombreWorkspace: workspace.outputs.workspaceName
  }
}

module detecciones 'modules/detections.bicep' = if (conDetecciones) {
  name: 'etapaC-detecciones'
  scope: grupoSoc
  params: {
    nombreWorkspace: workspace.outputs.workspaceName
    ipsAdmin: ipsAdminArray
    cuentasAdmin: cuentasAdminEfectivas
    mapaIpHost: mapaIpHostReal
    nombreApp: conInstrumentacion ? aplicacion!.outputs.appName : 'novashop'
    nombreStorage: conInstrumentacion ? aplicacion!.outputs.storageName : 'storage'
  }
}

// ---------------------------------------------------------------------------
// CAPA 6 · ampliacion, fases 15 a 19 de BUILD_GDAT2.0
// ---------------------------------------------------------------------------

module wec 'modules/wec.bicep' = if (conWec && conBase) {
  name: 'capa6-wec'
  scope: grupoVm
  params: {
    location: locationVm
    locationWorkspace: locationWorkspace
    prefijo: prefijo
    subnetId: red!.outputs.subnetId
    ipDns: dc!.outputs.ipPrivada
    workspaceId: workspace.outputs.workspaceId
    nombreDominio: nombreDominio
    netbiosDominio: netbiosDominio
    nombreVmDc: dc!.outputs.vmName
    nombreVmMember: member!.outputs.vmName
    usuarioAdmin: usuarioAdmin
    passwordAdmin: passwordAdmin
    usuarioJoin: '${usuarioAdmin}@${nombreDominio}'
    passwordJoin: passwordAdmin
    marcaEjecucion: marcaValidacionWec
  }
}

module permisosWec 'modules/wec-permissions.bicep' = if (conWec && conBase) {
  name: 'capa6-wec-permisos'
  scope: grupoSoc
  params: {
    nombreWorkspace: workspace.outputs.workspaceName
    principalId: wec!.outputs.principalId
  }
}

module validarWec 'modules/wec-validation.bicep' = if (conWec && conBase) {
  name: 'capa6-wec-validacion'
  scope: grupoVm
  params: {
    location: locationVm
    nombreVm: wec!.outputs.vmName
    workspaceCustomerId: workspace.outputs.customerId
    marcaEjecucion: marcaValidacionWec
  }
  dependsOn: [ permisosWec ]
}

module forwarder 'modules/linux-forwarder.bicep' = if (conForwarder && conBase) {
  name: 'capa6-forwarder'
  scope: grupoVm
  params: {
    location: locationVm
    locationWorkspace: locationWorkspace
    prefijo: prefijo
    subnetId: red!.outputs.subnetId
    workspaceId: workspace.outputs.workspaceId
    usuarioAdmin: usuarioAdmin
    clavePublicaSsh: clavePublicaSsh
  }
}

// Las tres siguientes no consumen cuota de computo: son plano de control puro.

module logsPersonalizados 'modules/custom-logs.bicep' = if (conLogsPersonalizados) {
  name: 'capa6-logs-personalizados'
  scope: grupoSoc
  params: {
    location: locationWorkspace
    prefijo: prefijo
    nombreWorkspace: workspace.outputs.workspaceName
    principalIngestaId: principalIngestaId
    tipoPrincipalIngesta: tipoPrincipalIngesta
  }
}

module threatIntel 'modules/threat-intel.bicep' = if (conThreatIntel) {
  name: 'capa6-threat-intel'
  scope: grupoSoc
  params: {
    nombreWorkspace: workspace.outputs.workspaceName
    conConectorTaxii: conConectorTaxii
    servidorTaxii: servidorTaxii
    coleccionTaxii: coleccionTaxii
    usuarioTaxii: usuarioTaxii
    passwordTaxii: passwordTaxii
    periodoTaxii: periodoTaxii
  }
}

module summaryRules 'modules/analytics-scale.bicep' = if (conSummaryRules) {
  name: 'capa6-summary-rules'
  scope: grupoSoc
  params: {
    nombreWorkspace: workspace.outputs.workspaceName
    conSummaryRules: conSummaryRules
  }
}

// El presupuesto va a nivel de suscripcion, como Defender. No cuelga de ningun
// grupo de recursos porque el gasto tampoco.
module presupuesto 'modules/budget.bicep' = if (conPresupuesto) {
  name: 'presupuesto'
  params: {
    nombre: '${prefijo}-lab'
    importe: importePresupuesto
    correos: correosPresupuesto
  }
}

// ---------------------------------------------------------------------------
// Salidas
// ---------------------------------------------------------------------------

output grupoVm string = rgVm
output grupoSoc string = rgSoc
output workspaceNombre string = workspace.outputs.workspaceName
output workspaceCustomerId string = workspace.outputs.customerId
output dcIpPublica string = conBase ? dc!.outputs.ipPublica : ''
output memberIpPublica string = conBase ? member!.outputs.ipPublica : ''
output novashopUrl string = conInstrumentacion ? aplicacion!.outputs.appUrl : ''
output uriIngestaCustomLogs string = conLogsPersonalizados ? logsPersonalizados!.outputs.uriIngesta : ''
output dcrImmutableIdCustomLogs string = conLogsPersonalizados ? logsPersonalizados!.outputs.dcrImmutableId : ''
output streamCustomLogs string = conLogsPersonalizados ? logsPersonalizados!.outputs.streamEntrada : ''
output tablaCustomLogs string = conLogsPersonalizados ? logsPersonalizados!.outputs.nombreTabla : ''

@description('vCPU que consume la combinacion elegida. La cuota de una suscripcion de prueba son 4.')
output vcpuEstimados int = (conBase ? 4 : 0) + (conWec ? 2 : 0) + (conForwarder ? 1 : 0)

@description('IP publicas que consume. La cuota de una suscripcion de prueba son 3.')
output ipsPublicasEstimadas int = (conBase ? 1 : 0) + (conBase && conIpPublicaDc ? 1 : 0) + (conBase ? 1 : 0)
