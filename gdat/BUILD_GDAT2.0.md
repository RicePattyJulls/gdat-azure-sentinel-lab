# GDAT 2.0 · laboratorio reproducible de detección y respuesta

Guía única para construir, comprobar, atacar y desmontar GDAT en un tenant y
una suscripción nuevos. La infraestructura se declara con Bicep; PowerShell y
Bash convergen lo que ARM no administra; el portal queda reservado para los
servicios que necesitan activación o consentimiento manual.

El objetivo de esta versión no es repetir los clics de la primera construcción.
Cada fase explica por qué existe una pieza, indica quién la implementa y termina
con una condición verificable. Que un recurso aparezca en el portal no significa
que esté operativo.

Todos los comandos locales parten del directorio `biceps/` del repositorio:

```bash
cd <repositorio>/biceps
```

## Cómo se usa este documento

La fuente de verdad se reparte así:

```text
Azure y Sentinel       main.bicep, modules/ y parameters/lab.bicepparam
Configuración del SO   scripts/configure-*.ps1, plant-*.ps1 y configure-cef.sh
Microsoft 365          scripts/configure-m365.ps1
Detecciones            modules/detections.bicep y queries/*.kql
Orquestación           deploy.sh
Comprobación           verificar.sh y scripts/validate-soc.sh
Ataque DCSync          probar-dcsync.sh
Desmontaje             teardown.sh
Explicación y orden     este documento
```

No se copian aquí cuerpos ARM, JSON de DCR, creación manual de recursos ni
PowerShell que ya viva en un script. Para saber exactamente qué configura una
pieza se lee el fichero versionado correspondiente.

Cada fase puede terminar en uno de estos estados:

```text
PREPARADA     parámetros y requisitos comprobados, sin desplegar
DESPLEGADA    Azure aceptó la configuración
OPERATIVA     el servicio entrega el estado o los datos esperados
PROBADA       un estímulo real produjo la detección o respuesta esperada
```

No se da una fase por terminada con `Provisioning succeeded`, `Connected`, una
extensión instalada o un servicio `Running` si su puerta exige datos reales.

## Arquitectura en una página

```text
Tenant Microsoft Entra ID
├── seis identidades de negocio con Microsoft 365 E5
├── MDO Standard, Purview Audit y conector M365 de MDCA
└── diagnostic settings de Entra cuando se habiliten

Suscripción Azure
├── gdat-vm-lab
│   ├── gdat-DC01      Windows Server 2025, AD DS, auditoría, SACL y MDE
│   ├── gdat-MEMBER01  miembro del dominio y datos financieros sintéticos
│   ├── NovaShop       App Service vulnerable únicamente en modo laboratorio
│   └── Storage        contenedor de exfiltración
├── gdat-soc
│   └── log-gdat-soc   Log Analytics, Sentinel, UEBA, contenido y detecciones
└── extensiones opcionales
    ├── gdat-WEC01     Windows Event Forwarding
    ├── gdat-FWD01     Syslog y CEF
    ├── NovaShop_CL    Logs Ingestion API
    ├── Threat Intelligence
    └── Summary rules, Data Lake y notebooks
```

La cadena controlada es:

```text
SQLi → credencial de Charlie → RDP → reconocimiento → Kerberoasting
     → cambio de grupo privilegiado → exfiltración → DCSync
```

Los nombres internos de Windows son `DC01` y `MEMBER01`; los recursos Azure se
llaman `gdat-DC01` y `gdat-MEMBER01`. No se mezclan en comandos.

## Mapa de las 21 fases

| Parte | Fases | Resultado |
| --- | --- | --- |
| Preparar sin consumir Azure | 1–4 | Tenant, M365, secretos, parámetros y plantilla validados |
| Construcción reproducible | 5–8 | Núcleo desplegado, fuentes manuales terminadas, MDE y MDI operativos |
| Detección y ataque base | 9–11 | Reglas comprendidas, siete señales probadas y entorno restaurado |
| Ampliaciones | 12–19 | Cloud, MDE avanzado, ASR, WEF, CEF, custom logs, TI y escala |
| Demostración final | 20–21 | Recorridos A/B, evidencias, coste y desmontaje |

# Parte I · Preparar sin consumir Azure

## Fase 1 · Identidad, tenant, suscripción y relojes

### Objetivo

Impedir que una ejecución alcance el tenant o la suscripción anteriores. Una
cuenta propietaria creada desde Gmail puede quedar como invitada `#EXT#`; Graph
y varias APIs de Defender deben operarse con una cuenta nativa.

### Cuenta de administración

Crear una sola vez:

```text
entra.microsoft.com
> Identity > Users > All users > New user > Create new user
  User principal name   admin@<tenant>.onmicrosoft.com
  Display name          Admin GDAT
> usuario > Assigned roles > Add assignments > Global Administrator
> cerrar toda la sesión, entrar con la cuenta nativa y cambiar la contraseña
```

Global Administrator gobierna el tenant, pero no sustituye `Owner` o `User
Access Administrator` sobre la suscripción.

Anotar antes de continuar:

```text
Dominio del tenant
Tenant ID
Subscription ID y fecha de expiración del crédito Azure
Fecha de expiración de Microsoft 365 E5
```

Definir los identificadores en la terminal actual:

```bash
export GDAT_TENANT_DOMAIN='<tenant>.onmicrosoft.com'
export GDAT_TENANT_ID='<tenant-id>'
export GDAT_SUBSCRIPTION_ID='<subscription-id-nuevo>'
export GDAT_IP_ADMIN="$(curl -fsS https://api.ipify.org)/32"
```

Abrir Azure expresamente contra esos valores:

```bash
az login --tenant "$GDAT_TENANT_ID"
az account list -o table
az account set --subscription "$GDAT_SUBSCRIPTION_ID"

az account show \
  --query "{Cuenta:user.name,Tenant:tenantId,Suscripcion:id,Nombre:name,Estado:state}" \
  -o table

az group list --query "[].{Grupo:name,Region:location}" -o table
```

### Puerta de salida

- La cuenta es nativa del tenant nuevo.
- Tenant ID y Subscription ID coinciden con los anotados.
- `Estado` es `Enabled`.
- El crédito Azure no muestra `0 days left` ni `Upgrade to keep going`.
- En una suscripción supuestamente vacía no existen grupos `gdat-*` inesperados.

Si falla cualquiera, se detiene el recorrido. Que una VM antigua aún responda
durante unos minutos no convierte una suscripción caducada en un entorno válido.

## Fase 2 · Microsoft 365 primero

### Por qué va antes de Azure

MDCA puede tardar más de 24 horas en producir actividad. Se inicia su reloj
mientras Bicep construye Azure. El script no compra licencias ni crea el preset
MDO; converge usuarios, asignaciones y estados existentes.

### Dos acciones manuales previas

En `admin.microsoft.com`, activar Microsoft 365 E5, confirmar plazas suficientes,
anotar su expiración y desactivar la renovación automática si es un trial.

Crear una vez el preset Standard:

```text
security.microsoft.com
> Email & collaboration
> Policies & rules
> Threat policies
> Preset Security Policies
> Standard protection > Manage
```

### Secretos

```bash
source ./cargar-secretos.sh

[[ -n ${GDAT_PWD_CHARLIE:-} ]] \
  && printf '%s\n' 'OK: GDAT_PWD_CHARLIE definida' \
  || printf '%s\n' 'FALTA: GDAT_PWD_CHARLIE'
```

No imprimir secretos. `configure-m365.ps1` restablece deliberadamente la
contraseña de `charlie.dev` al valor de `GDAT_PWD_CHARLIE`.

### Preflight sin escritura

```bash
pwsh ./scripts/configure-m365.ps1 \
  -Dominio "$GDAT_TENANT_DOMAIN" \
  -SoloComprobar -SaltarMdo

pwsh ./scripts/configure-m365.ps1 \
  -Dominio "$GDAT_TENANT_DOMAIN" \
  -SoloComprobar
```

En un tenant nuevo es normal que enumere deriva y termine en fallo. El segundo
preflight debe demostrar que Exchange abrió el mismo tenant. Si el preset existe
pero no contiene el dominio, debe informar `FALTA alcance ... en EOP/ATP`; una
excepción por valor nulo no es una salida válida.

### Convergencia

```bash
pwsh ./scripts/configure-m365.ps1 \
  -Dominio "$GDAT_TENANT_DOMAIN"
```

Aceptar el consentimiento delegado solicitado. La convergencia de la contraseña
de Charlie necesita `User-PasswordProfile.ReadWrite.All`; `User.ReadWrite.All`
por sí solo no basta.

Repetir en modo lectura:

```bash
pwsh ./scripts/configure-m365.ps1 \
  -Dominio "$GDAT_TENANT_DOMAIN" \
  -SoloComprobar
```

### Conector Microsoft 365 de MDCA

No usar `Automatic log upload`, destinado a firewalls y proxies:

```text
security.microsoft.com
> System > Settings > Cloud Apps
> Connected apps > App Connectors
> Connect an app > Microsoft 365
> componentes predeterminados > Connect > Done
```

Entrar en Outlook Web con un usuario de laboratorio para producir actividad.

### Puerta de salida

```text
Graph y Exchange apuntan al tenant esperado
seis perfiles existen
los seis tienen SPE_E5
Purview Unified Audit está activo
EOP y ATP incluyen el dominio
Microsoft 365 aparece Connected en MDCA
```

Las tablas de Defender XDR se comprueban después de producir actividad:

```kql
CloudAppEvents
| where Timestamp > ago(24h)
| summarize Actividades=count() by Application, ActionType
```

```kql
EmailEvents
| where Timestamp > ago(24h)
| summarize Correos=count() by SenderFromAddress, RecipientEmailAddress, DeliveryAction
```

No copiar telemetría cruda de Defender al workspace salvo que se haya decidido
pagar expresamente esa ingesta.

## Fase 3 · Preparar el entorno local y el presupuesto

### Parámetros

Revisar `parameters/lab.bicepparam` antes de ejecutar cualquier deployment:

```text
ipAdmin
locationVm y locationWorkspace
tamanoDc y tamanoMember
conBase, conInstrumentacion, conDetecciones y conContentHub
conWec, conForwarder, conLogsPersonalizados, conThreatIntel
conConectorTaxii, conSummaryRules y conFim
conPresupuesto, importePresupuesto y correosPresupuesto
accionAsr
object IDs para RBAC e ingesta
```

El presupuesto alerta; no detiene recursos. `ipAdmin` abre RDP y NovaShop. Si la
IP pública cambia, ambos parecen caídos hasta actualizar el parámetro y volver a
desplegar.

Cargar los seis secretos en la misma terminal:

```bash
source ./cargar-secretos.sh
```

El cargador debe confirmar longitud/presencia sin mostrar valores.

### Providers y cuotas

```bash
./deploy.sh preparar

az vm list-usage -l spaincentral \
  --query "[?localName=='Total Regional vCPUs' || localName=='Total Regional Low-priority vCPUs'].{Cuota:localName,Uso:currentValue,Limite:limit}" \
  -o table
```

Los contadores son distintos:

```text
DC01 + MEMBER01     4 vCPU regulares
WEC01               2 vCPU low-priority, Spot
FWD01               1 vCPU low-priority, Spot
Fases 17–19         0 vCPU adicionales
```

### Puerta de salida

- Todos los secretos requeridos están definidos.
- `ipAdmin` corresponde a la IP actual.
- Los flags opcionales reflejan solo lo que se desplegará ahora.
- La cuota permite esa combinación.
- El presupuesto y sus destinatarios son deliberados.

## Fase 4 · Validación estática y what-if

```bash
./deploy.sh preview
./deploy.sh validar-plantilla
```

`preview` compila y calcula el what-if; puede omitir VM mediante parámetros
seguros. `validar-plantilla` pide a Azure validar el despliegue completo.

### Puerta de salida

```json
{"estado":"Succeeded","error":null}
```

Además:

- Bicep compila sin errores.
- Los cambios del what-if son los esperados.
- No aparece otra suscripción o grupo histórico.
- Ningún secreto aparece en parámetros versionados, outputs o comandos.

# Parte II · Construcción reproducible

## Fase 5 · Desplegar el núcleo automatizado

### Ejecución

```bash
./deploy.sh desplegar
```

Confirmar la suscripción cuando el script lo solicite. La orquestación divide el
trabajo porque `dependsOn` solo espera a ARM, no a que DNS, Kerberos o una tabla
respondan:

```text
base
  workspace y Sentinel
  red y NAT
  gdat-DC01 → promoción → reinicio → puerta AD
  gdat-MEMBER01 → unión al dominio

instrumentación
  NovaShop y Storage
  Defender for Servers P2
  diagnostic settings
  identidades administradas, AMA, DCR y DCRA
  puerta de tablas

detecciones
  cuatro paquetes fijados de Content Hub
  siete reglas analíticas
  dos automation rules
```

Bicep dispara dentro de Windows, de forma idempotente:

```text
configure-dc.ps1       promueve el bosque novashop.local
wait-ad.ps1            espera DNS, Kerberos y LDAP
configure-audit.ps1    GPO, audit policy y SACL de DCSync
plant-chain.ps1        OU, cuentas, SPN, grupos y ACE del escenario
plant-endpoint.ps1     RDP de Charlie y datos financieros sintéticos
configure-asr.ps1      GPO de ASR con la acción parametrizada
```

No se ejecutan manualmente las instrucciones equivalentes de la versión 1.0.

### Observación sin interferir

Desde otra terminal:

```bash
watch -n 30 'az resource list -g gdat-vm-lab --query "[].{Tipo:type,Nombre:name}" -o table 2>/dev/null; echo; az vm list -g gdat-vm-lab --show-details --query "[].{VM:name,Estado:powerState,IP:publicIps}" -o table 2>/dev/null'
```

Revisar los runCommands:

```bash
az vm run-command list \
  -g gdat-vm-lab --vm-name gdat-DC01 \
  --query "[].{Comando:name,Estado:provisioningState}" -o table
```

Orden esperado en DC01: `promover-dc`, `esperar-ad`,
`configurar-auditoria`, `plantar-cadena`, `configurar-asr`. En MEMBER01:
`plantar-endpoint`.

Si falla alguno:

```bash
az vm run-command show \
  -g gdat-vm-lab --vm-name gdat-DC01 \
  --run-command-name esperar-ad --instance-view \
  --query "instanceView.{Estado:executionState,Salida:output,Error:error}" -o json
```

No se continúa a los ataques con un runCommand en `Failed`.

### Verificación automatizada

```bash
./verificar.sh

# Diagnóstico rápido sin la puerta KQL
./verificar.sh rapido
```

La ejecución completa comprueba grupos, cuota, VM, identidades administradas,
runCommands, pertenencia al dominio, SACL del 4662, NovaShop, Storage, Defender
P2, telemetría, reglas y datos.

### Idempotencia

Con los mismos interruptores, ejecutar una segunda vez:

```bash
./deploy.sh desplegar
./verificar.sh
```

No se marca idempotencia como probada hasta obtener de nuevo `0 fallos` sin
duplicar usuarios, SPN, ACE, GPO, recursos ni reglas. Si un recurso de activación
única como UEBA exige desactivar temporalmente un flag, se documenta como deuda;
no se declara repetibilidad completa.

### Puerta de salida

- `./verificar.sh` termina con `0 fallos`.
- No hay runCommands fallidos.
- Las tablas requeridas tienen filas reales.
- La segunda ejecución no produce duplicados ni cambios inesperados.

## Fase 6 · Completar únicamente las piezas no automatizadas

### Publicar el código de NovaShop

`app-storage.bicep` crea plan, App Service, configuración, restricciones de IP
para sitio y SCM, y diagnostic settings, pero no contiene el proyecto Flask.
Publicar el paquete sobre el nombre creado por el deployment; no volver a crear
el App Service con `az webapp up`.

El código viaja dentro del repositorio, en `biceps/novashop/`, y el subcomando
lo toma de ahí sin configurar nada:

```bash
./deploy.sh publicar-app
```

Para publicar otra copia, por ejemplo una rama de trabajo, se pasa la ruta como
argumento o se define `GDAT_NOVASHOP_DIR`; el procedimiento no cambia:

```bash
./deploy.sh publicar-app /ruta/a/otra/copia
```

El subcomando exige `app.py`, `requirements.txt`, `schema.sql`, `templates/` y
`static/`; empaqueta solo esos artefactos y ejecuta Zip Deploy con limpieza,
reinicio y build de Oryx. Excluye `instance/`, evidencias, bytecode y scripts
históricos. La ruta es una entrada local: no se fija dentro de Bicep.

Obtener el destino:

```bash
GDAT_APP=$(az webapp list -g gdat-vm-lab --query '[0].name' -o tsv)
az webapp show -g gdat-vm-lab -n "$GDAT_APP" \
  --query "{Nombre:name,Estado:state,Host:defaultHostName,Https:httpsOnly}" -o table
```

La publicación debe conservar `NOVASHOP_LAB_MODE` y los app settings declarados
por Bicep. El repositorio de la aplicación nunca debe contener las contraseñas
del laboratorio; la credencial sintética se recibe por el mecanismo seguro que
use la aplicación.

Después de abrir la página, generar una búsqueda normal y comprobar la emisión:

```kql
AppServiceConsoleLogs
| where TimeGenerated > ago(30m)
| where ResultDescription has "novashop_security"
| project TimeGenerated, ResultDescription
| order by TimeGenerated desc
```

Comprobar sitio y SCM desde la IP autorizada y, con datos móviles, que desde una
IP no autorizada ambos quedan bloqueados. La restricción SCM importa tanto como
la del sitio porque Kudu permite acceso al sistema de archivos.

### Workspace de Defender

```text
security.microsoft.com
> System > Settings > Microsoft Sentinel > SIEM workspaces
> log-gdat-soc
```

Debe figurar `Connected` y `Primary`. Los tenants recientes pueden hacerlo
automáticamente. No crear otra conexión si ya aparece así.

### Content Hub

`content.bicep` instala versiones fijadas de:

```text
Threat Essentials
Microsoft Entra ID
Microsoft Defender for Endpoint
Windows Security Events
```

No se conserva la obligación artificial de “instalar doce”. Se añade otro
paquete únicamente cuando una fase utilice contenido suyo. Instalar por cantidad
no prueba una integración y hace menos reproducible el despliegue.

### Fuentes de servicio no cubiertas por telemetry.bicep

`telemetry.bicep` cubre AMA/DCR/DCRA de Security, System y Application. No se
repite manualmente. Siguen fuera:

```text
Entra ID       diagnostic setting de tenant → SigninLogs, AuditLogs y riesgo
Azure Activity diagnostic setting de suscripción → AzureActivity
Conectores que solicitan OAuth o consentimiento propio
```

Antes de crear un diagnostic setting, listar los existentes y comprobar si ya
apuntan a `log-gdat-soc`. Entra es de ámbito tenant y sobrevive al borrado de una
suscripción; Azure Activity es de ámbito suscripción. No crear duplicados.

### Puerta de salida

- NovaShop responde desde la IP permitida y queda bloqueada desde otra.
- El código vulnerable solo actúa con el modo laboratorio habilitado.
- El workspace aparece `Connected / Primary`.
- Cada fuente habilitada tiene un único destino deliberado.
- Las tablas correspondientes reciben un evento generado después de activarlas.

## Fase 7 · Puerta real de Defender for Endpoint

MDI v3 depende del onboarding real de MDE. `Sense Running` no es suficiente.

### Defender for Cloud

```text
portal.azure.com
> Microsoft Defender for Cloud
> Management > Environment settings
> suscripción actual
> Defender plans > Servers > Monitoring coverage > Settings
> Endpoint protection = On
```

Comprobar que la VM correcta está viva:

```bash
az vm list -d \
  --query "[?name=='gdat-DC01'].{VM:name,Estado:powerState,Grupo:resourceGroup}" \
  -o table
```

En Defender:

```text
security.microsoft.com > Assets > Devices > dc01
  Onboarding status = Onboarded
  Health state      = Active
  Last seen         = reciente
  Domain            = novashop.local, no Workgroup
```

Comprobación local de solo lectura:

```bash
az vm run-command invoke \
  --resource-group gdat-vm-lab \
  --name gdat-DC01 \
  --command-id RunPowerShellScript \
  --scripts '$s=Get-Service Sense -ErrorAction SilentlyContinue; $o=Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status" -ErrorAction SilentlyContinue; [pscustomobject]@{SenseStatus=$s.Status; OnboardingState=$o.OnboardingState; OrgIdPresent=(-not [string]::IsNullOrWhiteSpace($o.OrgId)); UTC=(Get-Date).ToUniversalTime()} | Format-List'
```

### Puerta de salida

```text
SenseStatus     Running
OnboardingState 1
OrgIdPresent    True
```

Un registro viejo, `Inactive`, `Workgroup`, con `Last seen` atrasado,
`OnboardingState` vacío o `OrgIdPresent: False` no pasa. El primer onboarding
puede tardar horas. No se diagnostica sobre una suscripción caducada.

### FIM opcional

File Integrity Monitoring solo se habilita si una prueba va a modificar una
ruta vigilada y se medirá su resultado:

```text
portal.azure.com
> Microsoft Defender for Cloud > Environment settings
> suscripción > Settings > File Integrity Monitoring = On
  workspace = log-gdat-soc
  Recommended to monitor = Enabled
```

No se activa por costumbre: genera datos y coste.

## Fase 8 · Activar Defender for Identity v3

No existe instalador, ZIP ni Access Key para el sensor v3 de Windows Server
2025. La cuenta necesita `Security Administrator`; los cambios de Sentinel
requieren además el RBAC de Azure apropiado. Tras asignar roles, renovar sesión.

```text
security.microsoft.com
> System > Settings > Identities > Activation
> Manually select servers to activate
> dc01 > Activate
```

La acción correcta es `Activate new sensor`, no `Install classic sensor`.

Después:

```text
System > Settings > Identities > Sensors
  dc01: Onboarding → Running

System > Settings > Identities > Advanced features
  Automatic Windows auditing configuration = On

System > Settings > Identities > Microsoft Defender for Identity
> Manage action accounts
  Automatically use the sensor's local system account = On
```

La GPO y la SACL creadas por los scripts se conservan: también alimentan
Sentinel mediante AMA.

### Puerta de salida

- Sensor `dc01` en `Running`.
- La ficha corresponde al dispositivo activo del tenant actual.
- Se produce y observa actividad de identidad posterior a la activación.
- No se confunde un registro histórico con el host recién desplegado.

# Parte III · Detectar, atacar y responder

## Fase 9 · Modelo de detección, correlación y automatización

Esta fase no crea recursos. Explica lo que ya despliega `detections.bicep` y qué
debe observarse al probarlo.

### Evento, alerta e incidente

```text
Evento      telemetría cruda, por ejemplo 4769 o PutBlob
Alerta      una regla o producto interpreta una señal
Incidente   agrupa alertas relacionadas para investigación
```

La correlación une alertas, no eventos. Por eso el RDP necesita su propia regla:
la alerta comparte IP con la SQLi y cuenta con las señales de dominio.

### Las siete reglas versionadas

| Nº | Señal | Fuente principal |
| --- | --- | --- |
| 1 | SQL injection en NovaShop | `AppServiceConsoleLogs` |
| 2 | Kerberoasting | `SecurityEvent` 4769 |
| 3 | Adición a grupo privilegiado | `SecurityEvent` 4728 |
| 4 | Exfiltración a Storage | `StorageBlobLogs` |
| 5 | Creación sospechosa de recursos | `AzureActivity` |
| 6 | RDP entrante desde Internet | `SecurityEvent` 4624 tipo 10 |
| 7 | DCSync | `SecurityEvent` 4662 y derechos de replicación |

El KQL vive en `queries/`. Bicep sustituye nombres, IP y cuentas mediante
parámetros; no deben aparecer IDs de suscripción ni direcciones históricas.

### Entity mapping

Una regla debe mapear las entidades que realmente contiene su resultado:

```text
Account  nombre, UPN o SID
Host     hostname y dominio
IP       dirección que conecta señales
CloudApplication, AzureResource o URL cuando corresponda
```

`#INC_CORR#` identifica las reglas diseñadas para correlacionarse. Compartir el
tag no obliga al motor a unirlas: hacen falta entidades coincidentes y ventanas
temporales solapadas.

La cadena se cose con este mapa exacto:

```text
SQLi ↔ RDP             IP pública de la máquina atacante
RDP ↔ Kerberoasting    cuenta charlie.dev
RDP ↔ exfiltración     host MEMBER01
```

La operación de Storage usa `AccountKey` y no identifica a `charlie.dev`. La
regla deriva `MEMBER01` mediante el mapa parametrizado IP pública → host; no se
debe atribuir a Storage una cuenta que su registro no contiene.

### Automation rules actuales

El código vigente crea:

```text
Orden 1  incidentes High → conservar High y Active
Orden 2  incidentes Informational → cerrar como BenignPositive esperado
```

No se afirma que asignen `operator1` ni que etiqueten NovaShop: ese era el
diseño histórico y no coincide con `detections.bicep`.

### SACL del DCSync

Activar `Directory Service Access` no basta. La SACL del objeto de dominio
decide qué operaciones producen el 4662. `configure-audit.ps1` aplica los GUID
de `DS-Replication-Get-Changes` y `DS-Replication-Get-Changes-All`; la DCR usa
un XPath compatible con AMA. AMA no admite `contains()` en ese XPath, por lo
que el filtrado textual se hace después, en KQL.

## Fase 10 · Campaña base y prueba de las siete reglas

### Preparación obligatoria

Antes del primer estímulo:

- `./verificar.sh` termina con `0 fallos`.
- NovaShop está publicada y en modo laboratorio.
- DC01 y MEMBER01 están encendidas y en `novashop.local`.
- MDE está onboarded y MDI está `Running` si se comparará su detección nativa.
- La ACE de `svc-sql` sobre Domain Admins sigue presente; SDProp puede revertirla
  aproximadamente cada hora. Si falta, volver a ejecutar el mecanismo idempotente
  de `plant-chain.ps1` mediante el deployment, no pegar ACE manuales.
- Las fuentes que usa cada regla contienen filas recientes.
- Ataques y horas se anotan en UTC.

### 1. SQL injection

Obtener el host actual:

```bash
GDAT_APP_HOST=$(az webapp list -g gdat-vm-lab --query '[0].defaultHostName' -o tsv)
printf 'https://%s/search\n' "$GDAT_APP_HOST"
```

Desde el navegador de la máquina atacante, ejecutar el payload controlado de
unión contra `integration_config`. La respuesta debe exponer únicamente la
credencial sintética de `charlie.dev` y NovaShop debe registrar
`candidate_injection_executed`. No escribir la contraseña esperada en esta guía.

### 2. RDP real a MEMBER01

Obtener la IP actual:

```bash
GDAT_MEMBER_IP=$(az vm show -d -g gdat-vm-lab -n gdat-MEMBER01 --query publicIps -o tsv)
xfreerdp3 /v:"$GDAT_MEMBER_IP" /u:'NOVASHOP\charlie.dev' /dynamic-resolution +clipboard
```

Introducir la contraseña cuando la solicite el cliente, no como argumento. SQLi
y RDP deben salir de la misma IP pública para compartir esa entidad. La señal
esperada es un 4624 tipo 10.

### 3. Reconocimiento y Kerberoasting

Dentro de MEMBER01:

```powershell
whoami /groups
net user /domain
net group "Domain Admins" /domain
setspn -Q */*

Add-Type -AssemblyName System.IdentityModel
New-Object System.IdentityModel.Tokens.KerberosRequestorSecurityToken `
  -ArgumentList "MSSQLSvc/db01.novashop.local:1433"
```

La GPO debe producir 4688 con línea de comandos y DC01 debe producir 4769 para
el SPN sintético. No es necesario crackear el ticket para validar la detección.

### 4. Escalada controlada

Usar `Get-Credential 'NOVASHOP\svc-sql'` y la ACE plantada para añadir
`charlie.dev` a Domain Admins. No escribir la contraseña de servicio ni dejarla
en el historial. La señal esperada es 4728 y una alerta NRT.

### 5. Exfiltración sintética

Comprimir `C:\Datos_Financieros` y subir el ZIP al contenedor `exfil` usando la
clave de la cuenta del laboratorio. Resolver dinámicamente la cuenta:

```bash
GDAT_STORAGE=$(az storage account list -g gdat-vm-lab --query '[0].name' -o tsv)
az storage account keys list -g gdat-vm-lab -n "$GDAT_STORAGE" \
  --query '[0].value' -o tsv
```

La clave es material sensible: no se pega en el documento ni en capturas. La
señal esperada es `PutBlob` con `AuthenticationType = AccountKey` sobre datos
sintéticos.

### 6. Creación sospechosa de recursos

Crear un recurso de prueba identificado como tal desde una cuenta no excluida,
esperar la alerta y retirarlo tras exportar evidencia. No confundir esta regla
independiente con la secuencia SQLi–DCSync.

### 7. DCSync

La única prueba automatizada de ataque es:

```bash
source ./cargar-secretos.sh
./probar-dcsync.sh
```

El script ejecuta el DCSync con identidad de usuario, espera el 4662 y después
la alerta. Ejecutarlo como SYSTEM generaría una cuenta terminada en `$`, que la
regla descarta, y produciría un falso verde.

### Verificación de resultados

Cada regla debe tener su propio registro:

```text
hora UTC del estímulo
evento o fila de origen
alerta propia
alerta nativa de Defender, si aparece
incidente y entidades
latencia
resultado PASS/FAIL
```

Correlación por entidades:

```kql
SecurityAlert
| where TimeGenerated > ago(4h)
| mv-expand Entidad = parse_json(Entities)
| extend Tipo=tostring(Entidad.Type),
         Valor=tolower(coalesce(tostring(Entidad.Name),
                                tostring(Entidad.Address),
                                tostring(Entidad.HostName)))
| where isnotempty(Valor)
| summarize Alertas=make_set(AlertName, 20) by Tipo, Valor
| where array_length(Alertas) > 1
| order by Tipo asc
```

Línea temporal:

```kql
union
  (SecurityEvent
   | where EventID in (4624, 4662, 4688, 4728, 4769)
   | extend Fuente="SecurityEvent", Detalle=strcat(tostring(EventID), " ", Account)),
  (StorageBlobLogs
   | where OperationName == "PutBlob"
   | extend Fuente="StorageBlobLogs", Detalle=strcat(OperationName, " ", Uri)),
  (AppServiceConsoleLogs
   | where ResultDescription has "candidate_injection_executed"
   | extend Fuente="NovaShop", Detalle="SQLi ejecutada")
| where TimeGenerated > ago(4h)
| project TimeGenerated, Fuente, Detalle
| order by TimeGenerated asc
```

Un único incidente es el resultado ideal, no una garantía. Si se separa, indicar
qué entidad o ventana no cruzó. Eso es evidencia técnica, no un fracaso que deba
ocultarse.

## Fase 11 · Investigación, contención y restauración

### Investigación

En el incidente:

1. Revisar reglas, entidades y línea temporal.
2. Separar acciones de automation rules de `Attack disruption` de Defender XDR.
3. Comprobar en Action Center quién inició cada acción.
4. Registrar alertas nativas de MDE/MDI además de las siete propias.

### Orden de contención

```text
1. Aislar MEMBER01 si sigue comprometida
2. Deshabilitar Charlie en AD y Entra
3. Revocar sesiones de Entra
4. Rotar las claves de Storage
5. Retirar Charlie de Domain Admins
6. Preservar y exportar evidencia antes de limpiar artefactos
```

Attack disruption puede contener o deshabilitar al usuario automáticamente. No
atribuir esa acción a Sentinel si `Action source` indica Defender XDR.

### Restauración mínima

El siguiente recorrido comienza con Charlie habilitada en AD y Entra, fuera de
Domain Admins, MEMBER01 sin aislamiento, clave de Storage rotada y NovaShop en
el modo elegido para la prueba.

En DC01:

```powershell
Enable-ADAccount -Identity charlie.dev
Get-ADUser charlie.dev -Properties Enabled |
  Select-Object SamAccountName, Enabled

Get-ADGroupMember "Domain Admins" | Select-Object Name
# Solo si aparece:
# Remove-ADGroupMember "Domain Admins" -Members charlie.dev -Confirm:$false
```

En Entra, usar `$GDAT_TENANT_DOMAIN`; no escribir un dominio histórico:

```bash
GDAT_CHARLIE="charlie.dev@$GDAT_TENANT_DOMAIN"
az ad user update --id "$GDAT_CHARLIE" --account-enabled true
az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/users/$GDAT_CHARLIE?\$select=userPrincipalName,accountEnabled" \
  -o json
```

Si `Contain user` no ofrece Undo en el panel, revisar la barra superior de
Action Center y documentar la retención. No afirmar que MEMBER01 fue aislada si
la respuesta automática solo afectó a la identidad.

# Parte IV · Ampliaciones

## Fase 12 · Pivote cloud, Graph, Purview y eDiscovery

### Alcance

`configure-m365.ps1` ya crea/converge los usuarios, asigna E5, activa Unified
Audit y aplica el alcance MDO. Esta fase no repite esas operaciones. Añade datos
y demuestra investigación cloud.

### Sembrar actividad

Con usuarios de laboratorio y datos sintéticos:

- iniciar sesión en Microsoft 365;
- enviar y leer correo de prueba;
- crear o modificar un archivo no sensible;
- realizar una acción administrativa pequeña y reversible;
- esperar la latencia propia de MDCA, MDO y Purview.

### Fuentes no retroactivas

Si se requieren, habilitar una sola vez y verificar el destino:

```text
SigninLogs
AuditLogs
RiskyUsers
UserRiskEvents
MicrosoftGraphActivityLogs
```

No activar `MicrosoftGraphActivityLogs` sin una prueba concreta: puede aumentar
la ingesta. Retirarlo al terminar si no se seguirá usando.

### Regla cloud

La regla adicional de pivote cloud permanece manual hasta que tenga un fichero
KQL y un recurso Bicep propios. Debe documentar fuente, entidad, ventana,
agrupación y estímulo; no se copia una regla suelta mediante portal sin versión.

### Purview y eDiscovery

Comprobar con dos búsquedas de Audit separadas y la misma ventana temporal:

```text
Exchange              usuario de laboratorio + MailItemsAccessed
OneDrive/SharePoint   usuario de laboratorio + FileAccessed o FileDownloaded
```

`MailItemsAccessed` solo demuestra acceso a mensajes de Exchange; nunca prueba
una descarga de OneDrive. Exigir al menos un resultado posterior al estímulo en
cada workload que forme parte del recorrido y guardar ambas evidencias por
separado.

Después crear una búsqueda eDiscovery limitada a los buzones y fechas del
laboratorio. eDiscovery busca contenido; no sustituye las dos búsquedas de
actividad de Audit. Una búsqueda vacía se interpreta junto con licencia,
actividad producida y latencia, no automáticamente como fallo de configuración.

### Puerta de salida

- Actividad de M365 visible en su almacén correcto.
- Audit demuestra al menos una acción posterior a su activación.
- La búsqueda eDiscovery queda documentada con rango y criterio.
- Se distingue telemetría de Defender XDR de tablas copiadas a Sentinel.

## Fase 13 · Investigación y respuesta avanzada con MDE

Esta fase es manual porque las acciones son parte del aprendizaje operativo:

1. Habilitar Live Response según la política del tenant.
2. Crear o comprobar Device groups únicamente si aportan separación real.
3. Aislar MEMBER01 desde la ficha correcta.
4. Recoger Investigation package.
5. Abrir Live Response y ejecutar solo comandos de diagnóstico autorizados.
6. Verificar Action Center y Timeline.
7. Liberar MEMBER01.

### Puerta de salida

- Se demuestra qué rol autorizó cada acción.
- El aislamiento aparece completado y luego revertido.
- El paquete corresponde a la ejecución actual.
- Live Response no deja scripts ni sesiones activas.

## Fase 14 · Prevención mediante ASR

`configure-asr.ps1`, invocado por `dc.bicep`, crea y enlaza la GPO. El parámetro
`accionAsr` controla Audit o Block. No se vuelve a construir la GPO a mano.

### Recorrido

1. Desplegar con las reglas en Audit.
2. Comprobar que MEMBER01 recibió la política.
3. Ejecutar el estímulo controlado y guardar `DeviceEvents`.
4. Cambiar `accionAsr` a Block y redesplegar.
5. Repetir exactamente el mismo estímulo.
6. Comparar ejecución, evento y alerta.

### Puerta de salida

- La configuración efectiva coincide con el parámetro.
- Audit permite y registra.
- Block impide y registra.
- El cambio no se deduce solo del portal; se demuestra en el endpoint y KQL.

## Fase 15 · Windows Event Forwarding

### Automatización

Con `conWec=true`, Bicep y los scripts crean:

```text
gdat-WEC01 Spot y unión a novashop.local
servicio Windows Event Collector y WinRM
suscripción GDAT-Baseline
GPO de los orígenes
AMA, DCR y DCRA de ForwardedEvents
validación del colector
```

No se repiten los pasos manuales de creación de VM, XML de suscripción, GPO ni
DCR.

### Prueba

Generar un evento conocido en DC01 y MEMBER01. Ejecutar la validación del
proyecto y demostrar:

```text
origen correcto
EventRecordId preservado
evento presente en ForwardedEvents del colector
fila correspondiente en el workspace
LastError = 0
```

Los parsers ASIM son opcionales y se añaden solo después de tener datos.

## Fase 16 · Syslog y CEF mediante AMA

### Antes de habilitar

`gdat-FWD01` consume un vCPU low-priority y, junto con los dos de WEC01, llena
los tres disponibles de la cuota Spot. No improvisar una cuarta VM fuera de
Bicep ni convertirla a prioridad regular sin recalcular antes la cuota.

Con `conForwarder=true`, `linux-forwarder.bicep` y `configure-cef.sh` crean la
VM, paquetes, demonios, AMA, DCR y asociaciones. No se repite el aprovisionamiento
manual.

### Prueba

Enviar un mensaje Syslog y uno CEF con identificadores únicos. Comprobar:

```text
Syslog       Facility, SeverityLevel, HostName y mensaje
CommonSecurityLog DeviceVendor, DeviceProduct, Activity y extensiones CEF
```

Una extensión `Succeeded` sin filas no pasa.

## Fase 17 · Logs personalizados y transformaciones DCR

### Automatización

Con `conLogsPersonalizados=true`, Bicep crea en la región del workspace:

```text
DCE
tabla NovaShop_CL
DCR y stream
transformación que conserva Sensibilidad == "alta"
RBAC Monitoring Metrics Publisher para el principal de ingesta
outputs de endpoint, immutableId, stream y tabla
```

No se construye la URI a mano y no se vuelve a crear la tabla o DCR por REST.

### Lo manual: emitir y demostrar

Obtener los outputs del deployment y un token del principal autorizado. Enviar
un lote con al menos una fila `alta` y otra que deba descartarse. No guardar el
token ni el cuerpo con secretos.

```kql
NovaShop_CL
| where TimeGenerated > ago(1h)
| summarize Filas=count(), Sensibilidades=make_set(Sensibilidad) by Lote
```

### Puerta de salida

- El POST recibe una respuesta de éxito.
- La fila alta aparece.
- La fila filtrada no se factura ni almacena.
- Un principal sin el rol recibe 403.

## Fase 18 · Threat Intelligence y enriquecimiento

Con `conThreatIntel=true`, Bicep instala la solución fijada. Con
`conConectorTaxii=true`, declara el conector a partir de parámetros seguros.

Lo que sigue siendo manual:

1. Elegir un feed autorizado y documentar su colección.
2. Proporcionar credenciales sin versionarlas.
3. Esperar la primera sincronización o usar Upload API para un indicador
   sintético.
4. Confirmar que el indicador llega a `ThreatIntelIndicators` o
   `ThreatIntelObjects`, según el conector actual.
5. Probar una regla que lo cruce con telemetría del laboratorio.

No usar indicadores públicos reales para contactar infraestructura maliciosa.
La prueba usa dominios/IP reservados o datos sintéticos.

## Fase 19 · Summary rules, Data Lake y notebooks

Esta fase tiene fronteras explícitas:

```text
Summary rule      declarada por analytics-scale.bicep
Data Lake         onboarding manual e irreversible según el servicio
KQL job           manual
Notebook          manual
```

Con `conSummaryRules=true`, desplegar y comprobar que la tabla de resumen recibe
una ventana cerrada de datos. Antes de activar Data Lake, revisar coste, región,
retención y reversibilidad. El notebook debe leer datos del lab, construir una
cronología y no contener tokens, IDs históricos ni secretos.

### Puerta de salida

- El resumen coincide con la fuente para la misma ventana.
- El job puede reejecutarse sin duplicar resultados.
- El notebook declara entradas, periodo y limitaciones.
- No se marca Data Lake como hecho si solo existe la summary rule.

# Parte V · Demostración final

## Fase 20 · Campaña completa en dos recorridos

Los recorridos A y B son pruebas distintas y nunca se mezclan en una sola línea
temporal.

### Preparación común

- Exportar estado inicial y hora UTC.
- Confirmar usuarios, grupos, ACE, MDE, MDI, telemetría y reglas.
- Rotar o recuperar las credenciales sintéticas mediante el procedimiento
  seguro.
- Confirmar que NovaShop y los controles ASR están en el modo del recorrido.

### Recorrido A · observación

1. ASR en Audit.
2. Ejecutar la campaña base.
3. Añadir las señales de WEF, CEF, custom logs y TI que estén habilitadas.
4. Observar detecciones y respuestas sin bloquear prematuramente la cadena.
5. Exportar la evidencia A.

### Restauración entre recorridos

Aplicar íntegramente la fase 11. Además:

- comprobar que no queda `PSEXESVC` ni otro servicio de prueba;
- soltar aislamientos y contenciones reversibles;
- retirar blobs y recursos de prueba después de exportarlos;
- reponer la ACE del escenario si SDProp la retiró;
- confirmar de nuevo el estado inicial.

Cerrar el incidente A no vacía las ventanas de las reglas Scheduled. Con la
configuración actual, varias se ejecutan cada cinco minutos y miran una hora
hacia atrás. Para impedir que vuelvan a alertar sobre A durante B:

1. Registrar `A_FIN_UTC`, la hora del último estímulo de A.
2. Esperar al menos **una hora más diez minutos** desde `A_FIN_UTC`.
3. Confirmar durante esos diez minutos finales que no aparecen alertas nuevas
   atribuibles a eventos de A.
4. Registrar `B_INICIO_UTC` y comenzar B únicamente después de esa puerta.
5. Comparar A y B por sus intervalos UTC, no solo por `IncidentId`.

Si en el futuro cambian `queryPeriod` o la latencia máxima aceptada, el corte se
ajusta al mayor de esos valores más su margen; no se conserva ciegamente 70
minutos.

### Recorrido B · prevención

1. ASR en Block.
2. Repetir los mismos estímulos, en el mismo orden.
3. Registrar el primer control que interrumpe cada rama.
4. No “arreglar” la campaña para que llegue artificialmente al final.
5. Exportar la evidencia B.

### Comparación

```text
estímulo
resultado A y resultado B
evento
alerta
acción preventiva
latencia
impacto sobre la continuidad del ataque
```

El valor del recorrido B es demostrar dónde se corta la cadena, no producir el
mismo incidente que A.

## Fase 21 · Evidencias, coste y desmontaje

### Evidencia mínima

Guardar fuera de los recursos que se eliminarán:

```text
identificadores de tenant/suscripción parcialmente redactados
fecha y ventana UTC
parámetros sin secretos
resultado de preview, validación e idempotencia
salida resumida de verificar.sh
estado MDE y MDI
tabla PASS/FAIL de las siete reglas
incidentes, entidades y latencias
comparación A/B
coste aproximado
pendientes reales
```

Una captura no sustituye el dato consultable. Siempre que sea posible guardar
KQL, intervalo y resultado exportado.

### Apagar frente a destruir

Deallocate detiene cómputo, pero discos, IP, Log Analytics, Defender y otros
servicios pueden seguir generando coste. Para revisar qué eliminaría el proyecto:

```bash
./teardown.sh
```

Después de exportar la evidencia:

```bash
./teardown.sh --si
```

El teardown purga el workspace cuando corresponde y devuelve Defender for
Servers a Free. Borrar solo grupos de recursos no apaga el plan de suscripción.

### Puerta final

- Evidencia exportada y legible fuera de Azure.
- Recursos y planes de pago revisados.
- Diagnostic settings de tenant que apuntaban al workspace eliminado retirados
  o redirigidos deliberadamente.
- Renovaciones automáticas revisadas.
- Estado final y costes anotados.

# Apéndice A · Conceptos SC-200 que sostienen el laboratorio

## Licenciamiento y coste

No existe una “licencia Sentinel por usuario”. En este laboratorio conviven:

```text
Microsoft 365 E5     por usuario; habilita capacidades de Defender y Purview
Defender for Servers por recurso/suscripción; protege las VM de Azure
Microsoft Sentinel   por ingesta y retención del workspace
```

Asignar E5 a una identidad no envía automáticamente sus datos a Sentinel. Cada
workload tiene su sensor, conector, almacén y mecanismo de facturación.

## Dos almacenes, una experiencia unificada

Defender XDR y Log Analytics no son la misma base de datos:

```text
Defender XDR       Device*, Identity*, Email*, CloudAppEvents
Log Analytics      SecurityEvent, AzureActivity, SigninLogs, tablas *_CL
```

El portal unificado permite investigar ambos, pero una consulta o licencia no
mueve físicamente los datos. Copiar tablas crudas al workspace puede duplicar
coste sin aportar detección.

## Solución, conector e ingesta

```text
Solución instalada   añade contenido versionado
Conector conectado   configura una relación o consentimiento
Datos presentes      demuestra que la fuente emitió y el destino recibió
```

Son estados independientes. `Connected` con una tabla vacía puede significar
latencia, falta de actividad o una configuración rota; la prueba debe producir
un evento conocido.

## Mecanismos de entrada

| Mecanismo | Ejemplo | Ámbito |
| --- | --- | --- |
| AMA + DCR/DCRA | Windows Security Events | VM |
| Diagnostic setting | Entra, Azure Activity, App Service, Storage | tenant, suscripción o recurso |
| Servicio a servicio | Defender XDR | tenant/workspace |
| Logs Ingestion API | `NovaShop_CL` | DCE/DCR |
| Forwarder | WEF, Syslog y CEF | host colector |

UEBA no ingiere. Deriva comportamiento y entidades a partir de datos que ya
existen. Su reloj útil empieza con las primeras filas, no solo al activar el
toggle.

## Detección y respuesta

Una analytic rule crea alertas. Una automation rule modifica o enruta incidentes.
Un playbook ejecuta una Logic App. Una acción nativa de Defender puede aislar un
dispositivo o contener una identidad sin intervención de Sentinel. Siempre se
registra qué motor ejecutó la respuesta.

La contención sigue este orden general:

```text
aislar activo → cortar identidad/sesiones → rotar secretos → retirar privilegios
→ preservar evidencia → limpiar → restaurar de forma controlada
```

# Apéndice B · Cobertura: antiguo 1–30 frente a GDAT 2.0

| Contenido antiguo | Destino 2.0 | Tratamiento |
| --- | --- | --- |
| 1, 8, 13 y parte de 22 | Fase 2 | `configure-m365.ps1`; solo compra/preset/MDCA manuales |
| 2–4 | Fase 5 | Red, DC y MEMBER01 declarados; desaparecen clics y RDP de construcción |
| 5–6 | Fases 5–6 | Infraestructura automática; publicación de código permanece |
| 7 y 11 | Fase 5 | AD, GPO, SACL y diagnostic settings mediante scripts/Bicep |
| 9–10 | Fases 5 y 7 | Workspace/Defender declarados; onboarding se valida aparte |
| 12 | Fase 8 | Activación MDI manual tras la puerta MDE |
| 14–15 | Fases 5–6 | Cuatro paquetes y telemetría Windows automáticos; fuentes OAuth quedan |
| 16 | Puertas de fases 5–8 | Validaciones colocadas junto a su causa |
| 17, 19 y 20 | Fase 9 | Conceptos conservados; creación manual eliminada |
| “Checkpoint verde” | Eliminado | Sus comprobaciones se distribuyen como puertas, no como fase |
| Ejecución del ataque | Fase 10 | Se conserva, parametrizada y sin contraseñas fijas |
| 22 | Fase 12 | Solo ampliación cloud e investigación, sin repetir M365 |
| 23 | Fase 13 | Se conserva manual por ser aprendizaje de respuesta |
| 24 | Fase 14 | Configuración automática; contraste Audit/Block manual |
| 25 | Fase 15 | WEC/WEF automático; estímulo y prueba manuales |
| 26 | Fase 16 | Forwarder automático; emisión y prueba manuales |
| 27 | Fase 17 | DCE/DCR/tabla/RBAC automáticos; POST real manual |
| 28 | Fase 18 | Solución/TAXII declarativos; feed y prueba manuales |
| 29 | Fase 19 | Summary declarativa; Data Lake/job/notebook manuales |
| 30 | Fase 20 | Dos recorridos separados y restauración explícita |
| Anexo Bicep propuesto | Eliminado | Bicep ya es la implementación actual |

La revisión del código se dividió en dos bloques. El primero conserva una
correspondencia directa por contenido:

| Fase antigua | Contenido | Fase 2.0 |
| ---: | --- | ---: |
| 21 | Ejecución del ataque | 10 |
| 22 | Pivote cloud y auditoría M365 | 12 |
| 23 | Investigación y respuesta con MDE | 13 |
| 24 | Prevención con ASR | 14 |
| 25 | Windows Event Forwarding | 15 |
| 26 | Syslog y CEF mediante AMA | 16 |
| 27 | Logs personalizados y DCR | 17 |
| 28 | Threat Intelligence | 18 |
| 29 | Summary rules, Data Lake y notebooks | 19 |
| 30 | Campaña completa en dos recorridos | 20 |

El segundo bloque reúne fases manuales que el 2.0 absorbió o separó entre
creación y prueba:

| Fase antigua | Contenido | Fase 2.0 y criterio |
| ---: | --- | --- |
| 2 | Red VNET-GDAT y SN-LAB | 5 |
| 3 | DC01 y promoción del bosque | 5 |
| 4 | MEMBER01 | 5 |
| 5 | NovaShop en App Service | 5; código publicado en la 6 |
| 6 | Storage de exfiltración | 5 |
| 7 | Plantar la cadena de escalada | 5 |
| 9 | Workspace y Sentinel | 5 |
| 10 | Defender for Servers P2 y MDE | 5; puerta MDE en la 7 |
| 11 | Auditoría y diagnostic settings | 5 |
| 14 | Content Hub | 5 |
| 15 | Conectores | 5 |
| 18 | Checkpoint verde | 5; sus puertas quedan distribuidas |
| 19 | Detection Rules | 5; se prueban en la 10 |
| 20 | Automation rules y contención | 5 para su creación |
| 1 | Identidades de negocio | 2 |
| 8 | Licencias Microsoft 365 E5 | 2 |
| 13 | MDO y MDCA | 2 |
| 22 | Habilitación de Purview Audit | 2; se explota en la 12 |
| 12 | Sensor MDI en DC01 | 8 |

La renumeración del código quedó verificada de forma independiente. Fueron
**58 referencias en 29 ficheros**: 32 correspondencias directas del antiguo
21–30 al nuevo 10 y 12–20, y 26 referencias de fases absorbidas por la fase 5,
M365 por la fase 2 y MDI por la fase 8. El número indica dónde se crea el
recurso; cuando su puerta vive después, el comentario lo declara aparte:
NovaShop se publica en la fase 6, MDE se acredita en la 7 y las siete reglas se
prueban en la 10.

El caso de control fue `telemetry.bicep`: la antigua fase 15 significaba AMA y
DCR, mientras que la fase 15 del 2.0 significa WEF. Ahora apunta a la fase 5.
No quedan referencias superiores a 21 en `biceps/`; Bicep compila, los siete
Bash y los once PowerShell pasan análisis sintáctico y las cinco pruebas de
NovaShop terminan correctamente. `BUILD_GDAT.md` conserva intacta la numeración
histórica de 30 fases.

# Apéndice C · Fallos conocidos que no deben reaparecer

```text
RecipientDomainIs nulo
  El lector de configure-m365.ps1 tolera entradas nulas.

403 al cambiar passwordProfile
  La sesión Graph necesita User-PasswordProfile.ReadWrite.All.

Sense Running sin onboarding
  Exigir OnboardingState=1 y OrgIdPresent=True, además de Device inventory activo.

Registro viejo de DC01
  Comprobar Last seen, dominio y tenant; no reutilizar un dispositivo Inactive.

XPath AMA con contains()
  No está soportado. telemetry.bicep usa band() y el filtrado de contenido va en KQL.

Subscription ID fijo en DCR
  Usar IDs calculados por Bicep y outputs, nunca GUID históricos.

AMA instalado pero sin datos
  Verificar identidad administrada, DCR, DCRA, stream y filas reales.

Content Hub instalado pero conector vacío
  Solución, conector e ingesta son estados distintos.

SDProp revierte la ACE del escenario
  Comprobarla justo antes del ataque y reponerla mediante el script idempotente.

Borrar grupos pero dejar Defender P2
  Ejecutar teardown.sh; el plan es de suscripción.
```

# Apéndice D · Registro de validaciones

Cada tenant nuevo añade una entrada, sin convertir los resultados históricos en
instrucciones vigentes:

```text
Fecha:
Tenant abreviado:
Subscription abreviada:
E5 expira:
Azure expira:
Fases completadas:
Idempotencia:
Reglas probadas:
Coste:
Pendientes:
```

## Ensayo del 26/08/2026

En el tenant anterior se demostró `configure-m365.ps1` de extremo a extremo:
seis usuarios con SPE_E5, Purview Audit, alcance MDO, MDCA `Connected` y el
workspace `Connected / Primary`. Se corrigieron la lectura nula de
`RecipientDomainIs` y el scope para `passwordProfile`.

MDI no quedó validado. La suscripción Azure tenía el crédito agotado y la ficha
de DC01 era histórica: `Inactive`, `Workgroup`, `OnboardingState` vacío y sin
OrgId. Esa observación justifica las puertas de las fases 1 y 7; no constituye
una prueba fallida del despliegue nuevo.
