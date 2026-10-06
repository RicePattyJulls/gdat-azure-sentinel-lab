/*
  Parametros del laboratorio.

  Aqui NO van contrasenas. Se pasan en la linea de comandos o se leen de Key
  Vault, para que no acaben en Git ni en el historial de despliegues.

  El bloque de interruptores esta pensado para una suscripcion de prueba: la
  base consume los 4 vCPU regulares y WEC01 + FWD01 los 3 low-priority.
*/

using '../main.bicep'

param prefijo = 'gdat'
param locationVm = 'spaincentral'
param locationWorkspace = 'francecentral'

// IP publica de administracion. Se recibe del entorno para no versionar la IP
// personal del operador y para obligar a revisarla en cada tenant:
//   export GDAT_IP_ADMIN="$(curl -fsS https://api.ipify.org)/32"
param ipAdmin = readEnvironmentVariable('GDAT_IP_ADMIN')

param usuarioAdmin = 'gdatadmin'
param nombreDominio = 'novashop.local'
param netbiosDominio = 'NOVASHOP'

// Si acabas de borrar un workspace con este nombre, su nombre sigue reservado 14
// dias. O lo borras con --force, o cambias este valor.
param nombreWorkspace = 'log-gdat-soc'

// --- Alcance ---------------------------------------------------------------
// Combinacion por defecto: laboratorio base instrumentado y con detecciones.
// 4 vCPU, que es exactamente la cuota de una suscripcion de prueba.

param conBase = true
param conInstrumentacion = true
param conDetecciones = true

// Content Hub usa el mismo contentProductId determinista que los paquetes del
// catalogo. Las 7 reglas propias siguen sin depender de estas soluciones.
param conContentHub = true

// Capa 6 con maquina. Las DOS son Spot y usan el contador Low-priority, que va
// aparte de la cuota regular: WEC01 pide 2 vCPU y FWD01 uno, y llenan justo 3/3.
// Ninguna obliga a encoger MEMBER01.
param conWec = false
param conForwarder = false

// Capa 6 sin maquina. Se pueden encender con la cuota al limite.
param conLogsPersonalizados = false
param conThreatIntel = false
param periodoTaxii = 'OneDay'
param conSummaryRules = false

// Cuota de IP publicas en una suscripcion de prueba: 3. El lab base pide las
// tres. Poner esto en false libera la de DC01, que se administra entonces con
// az vm run-command.
param conIpPublicaDc = true

// Sentinel, UEBA y Entity Analytics. deploy.sh los activa solo si no existen y
// los omite en las etapas y despliegues posteriores para evitar el error ETag.
param conUeba = true

// --- Presupuesto -----------------------------------------------------------
// Enciendelo el dia que pases a pago por uso. Avisa al 50, 80 y 100% del gasto
// real, y ademas cuando Azure proyecta que vas a llegar al 80%. Ese ultimo es el
// que te da tiempo a reaccionar.
//
// No corta nada: para cortar esta ./teardown.sh
param conPresupuesto = true
param importePresupuesto = 200
param correosPresupuesto = [ 'tu-correo@ejemplo.com' ]

// --- Tamanos ---------------------------------------------------------------
param tamanoDc = 'Standard_B2as_v2'
param tamanoMember = 'Standard_B2as_v2'

// ASR en Audit. Cambiar a 1 para el segundo recorrido de la fase 20.
param accionAsr = 2

// Cuentas de administracion adicionales que las reglas no deben alertar.
// main.bicep siempre anade usuarioAdmin (gdatadmin) a esta lista.
param cuentasAdmin = []

// Separacion de roles del SOC. Rellenar con object IDs de Entra.
param responderObjectIds = []
param contributorObjectIds = []

param clavePublicaSsh = ''

// Fase 17: object ID del service principal que enviara datos por la Logs
// Ingestion API. Si se activa la fase sin rellenarlo, la validacion del modulo
// falla: nunca se despliega una DCR condenada a responder 403.
param principalIngestaId = ''
param tipoPrincipalIngesta = 'ServicePrincipal'

// --- Contrasenas -----------------------------------------------------------
// Se leen del entorno del proceso. Ni se escriben aqui, ni viajan por la linea
// de comandos donde cualquier usuario de la maquina las veria en la tabla de
// procesos, ni quedan en un fichero temporal.
//
// Exportarlas antes de desplegar:
//   export GDAT_PWD_ADMIN='...'   y las cinco restantes
//
// Si falta alguna, readEnvironmentVariable falla y el despliegue no arranca,
// que es justo lo que se quiere: mejor no desplegar que desplegar con vacios.

param passwordAdmin = readEnvironmentVariable('GDAT_PWD_ADMIN')
param passwordDsrm = readEnvironmentVariable('GDAT_PWD_DSRM')
param passwordNegocio = readEnvironmentVariable('GDAT_PWD_NEGOCIO')
param passwordCharlie = readEnvironmentVariable('GDAT_PWD_CHARLIE')
param passwordSvcSql = readEnvironmentVariable('GDAT_PWD_SVCSQL')
param passwordSvcBackup = readEnvironmentVariable('GDAT_PWD_SVCBACKUP')
