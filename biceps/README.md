# Laboratorio GDAT · despliegue reproducible con Bicep

Version declarativa del laboratorio que describen las fases 1 a 21 de
`gdat/BUILD_GDAT2.0.md`. Las fases 10 y 20 son ataques y no se despliegan.

## Qué hace y qué no

Bicep resuelve la capa de Azure y Sentinel casi entera. Lo que se resiste es
todo lo de Microsoft 365 e identidad, que va por APIs propias.

| Fase | Módulo | Cobertura |
| --- | --- | --- |
| 2 · red | `network.bicep` | 100% |
| 6 · storage | `app-storage.bicep` | 100% |
| 14 · Content Hub | `content.bicep` | 60% |
| 19 y 20 · detecciones | `detections.bicep` | 85% |
| 9 y 18 · workspace | `workspace.bicep` | 90% |
| 27 · logs personalizados | `custom-logs.bicep` | 90% |
| 5 y 11 · NovaShop | `app-storage.bicep` | 70% |
| 29 · summary rules | `analytics-scale.bicep` | 40% |
| 15 · telemetría | `telemetry.bicep` | 80% |
| 4 · MEMBER01 | `member.bicep` | 75% |
| 28 · threat intel | `threat-intel.bicep` | 75% |
| 10 · Defender for Servers | `subscription.bicep` | 70% |
| 25 · WEC01 | `wec.bicep` | 70% |
| 26 · forwarder | `linux-forwarder.bicep` | 70% |
| 3, 7 y 11 · DC01 | `dc.bicep` | 60% |

Fuera de Bicep, y se activa a mano: el sensor de MDI, las políticas de MDO y
MDCA, los usuarios de Entra, las licencias E5, conectar el workspace como
Primary en Defender, y todo Purview.

## Cuota

La cuota de una suscripción de prueba son **4 vCPU**, y no se puede ampliar sin
convertirla a pago por uso.

**Azure lleva dos contadores separados**, y confundirlos hace creer que no cabe
lo que sí cabe:

```text
Total Regional vCPUs                4    VM normales
Total Regional Low-priority vCPUs   3    VM Spot. Contador aparte
```

```text
DC01 + MEMBER01     4 vCPU   REGULAR. Consumen la cuota entera
WEC01 (fase 15)     2 vCPU   SPOT. Cabe aunque la regular este al 100%
FWD01 (fase 16)     1 vCPU   SPOT. Con WEC01 llena los 3 low-priority
Fases 17, 18 y 19   0 vCPU   plano de control puro
```

O sea: `WEC01`, `FWD01` y las tres últimas se pueden levantar con la cuota
regular al límite. WEC01 y FWD01 llenan juntas los 3 vCPU low-priority.

A cambio, una VM Spot puede ser desalojada si falta capacidad en la región. Por
eso `WEC01` lleva `evictionPolicy: Deallocate`: si la desalojan, se conserva y
basta con arrancarla.

## Uso

En una suscripción nueva, **primero esto**, o el despliegue falla a mitad con
`NoRegisteredProviderFound`:

```bash
./deploy.sh preparar
```

Registra los diez resource providers que el laboratorio necesita y espera a que
estén listos. En una suscripción donde ya se ha trabajado, termina en segundos.

```bash
export GDAT_PWD_ADMIN='...'
export GDAT_PWD_DSRM='...'
export GDAT_PWD_NEGOCIO='...'
export GDAT_PWD_CHARLIE='...'
export GDAT_PWD_SVCSQL='...'
export GDAT_PWD_SVCBACKUP='...'
export GDAT_IP_ADMIN="$(curl -fsS https://api.ipify.org)/32"

./deploy.sh preview      # compila y muestra what-if, no toca nada
./deploy.sh desplegar
./deploy.sh publicar-app # usa ./novashop; admite una ruta alternativa
./deploy.sh validar      # espera a que las tablas respondan de verdad
./deploy.sh destruir
```

`GDAT_IP_ADMIN` abre el RDP en el NSG y autoriza NovaShop. Si la IP pública
cambia, hay que volver a exportarla y redesplegar.

## La capa 1: lo que no es ARM

Bicep resuelve Azure. Microsoft 365 e identidad van por APIs propias; el script
se ejecuta **desde tu máquina**, no dentro de una VM.

```bash
# Fase 2: usuarios, licencias E5, Purview y politicas de MDO
pwsh ./scripts/configure-m365.ps1 -Dominio tutenant.onmicrosoft.com

# Ver que haria sin tocar nada
pwsh ./scripts/configure-m365.ps1 -Dominio tutenant.onmicrosoft.com -SoloComprobar
```

Lánzalo **antes o durante** el despliegue de Bicep, no después: MDCA no arranca
hasta que hay licencias asignadas y su reloj tarda más de 24 horas. Cuanto antes
empiece, antes tienes el laboratorio útil.

Las reglas Standard/Strict de MDO no se pueden crear de forma soportada por
PowerShell. Si el script indica que faltan, activarlas una vez en `Defender >
Email & collaboration > Policies & rules > Threat policies > Preset Security
Policies` y repetir; el script converge y verifica el estado y el dominio.

La fase 8 no tiene instalador: en Windows Server 2025 el sensor MDI v3 se
**activa** en `security.microsoft.com > System > Settings > Identities >
Activation`, cuando DC01 ya aparece en *Device inventory*. No pide paquete,
Access Key ni reinicio.

### Lo único que queda a mano

```text
Comprar la licencia E5      implica un pago, no hay API
Conector de M365 en MDCA    un clic, y arranca su reloj de 24 h
Activar MDI v3 en DC01      paso de portal; no existe instalador para Server 2025
Fases 10 y 20               son ataques. El objetivo es que los hagas tu
```

Y uno que probablemente ya no haga falta: conectar el workspace como *Primary* en
Defender. Los tenants incorporados desde julio de 2025 con permisos de *Owner* o
*User Access Administrator* se conectan solos, y con un único workspace ese queda
designado como primario. Compruébalo antes de hacerlo.

## Por qué el despliegue va por etapas

`dependsOn` garantiza que ARM terminó de desplegar un recurso. No demuestra que
el DC reinició, que Kerberos y DNS responden, que MDE terminó de onboardear ni
que una tabla de Sentinel ya existe.

```text
ETAPA 0   workspace, Sentinel y UEBA prehabilitado
ETAPA A   red > DC01 > promocion y reinicio > puerta: DNS 53, Kerberos 88, LDAP 389
          > MEMBER01 y domain join
ETAPA B   Defender for Servers P2 > NovaShop y storage > AMA, DCR y DCRA
          > puerta: las tablas responden por KQL
ETAPA C   Content Hub > reglas analiticas > automation rules
```

UEBA se prehabilita en la etapa 0, pero un workspace vacío no genera
aprendizaje: su ventana útil empieza con el primer dato recibido, no con la
línea que lo activa.

## Las consultas

El KQL de las siete reglas vive en `queries/`, un fichero por regla, extraído
del documento. Los datos del entorno están parametrizados con marcadores que
`detections.bicep` sustituye en el despliegue:

```text
__IPS_ADMIN__        IPs de administracion excluidas
__CUENTAS_ADMIN__    cuentas de administracion excluidas
__MAPA_IP_HOST__     mapa de IP publica a host del laboratorio
__NOMBRE_APP__       nombre de la aplicacion NovaShop
__NOMBRE_STORAGE__   nombre de la cuenta de almacenamiento
```

Así el KQL se versiona en Git sin arrastrar direcciones ni nombres de cuenta
reales.

## La regla 7 y su SACL

La regla del DCSync sobre el evento `4662` necesita algo que no es la regla: una
**SACL de auditoría en el objeto de dominio**. La subcategoría *Directory Service
Access* enciende la auditoría; la SACL decide qué objeto y qué operación se
auditan. Sin ella la tabla no recibe ningún `4662` y la consulta devuelve cero
indefinidamente.

Eso lo aplica `scripts/configure-audit.ps1`, que además lee los GUID de
subcategoría de la propia máquina con `auditpol` en vez de escribirlos a mano.

## Lo que solo se descubre desplegando

Siete cosas que pasaron compilacion, what-if y `az deployment sub validate`, y
que solo aparecieron al desplegar contra Azure de verdad. Quedan aqui porque son
exactamente el tipo de fallo que una revision estatica no puede encontrar.

| Sintoma | Causa | Solucion |
| --- | --- | --- |
| `NoRegisteredProviderFound ... for type 'settings'` | `Microsoft.SecurityInsights/settings` **no tiene version GA**, solo preview. El aviso `BCP081` que llevabamos ignorando era exactamente esto | `2023-12-01-preview` |
| `Update request should provide ETag` | La API de SecurityInsights usa concurrencia optimista. Un segundo despliegue sobre unos settings que ya existen exige el ETag actual | Son recursos de *activar una vez*: parametro `conUeba`, en `false` al redesplegar |
| `Could not find member 'etag' on object of type 'TemplateResource'` | Bicep acepta `etag` en el recurso, pero ARM lo rechaza. No se puede declarar desde plantilla | No usar `etag`. Ver la fila anterior |
| `Missing required property ... 'DefinedWorkspaceId'` | La propiedad de FIM se llama `DefinedWorkspaceId`, no `WorkspaceId`. `additionalExtensionProperties` es un objeto libre, asi que compila igual | Nombre correcto |
| `Missing required property ... 'Rules'` | FIM exige ademas la configuracion de rutas y claves a vigilar. El portal la rellena sola al marcar *Recommended to monitor*; una plantilla no | Parametro `conFim`, apagado. Se activa desde el portal |
| Extensiones de Defender rechazadas | Azure valida las propiedades de una extension **aunque la declares con `isEnabled: 'False'`** | Construir el array con `union()` y declarar solo lo encendido |
| `contentPackages` sin `contentProductId` | Es un identificador determinista que el catálogo genera con `solutionId-Solution-solutionId-version` | Se usa el mismo `take(...)-sl-uniqueString(...)` de los paquetes oficiales; Content Hub queda separado de las reglas propias |

El patron que se repite: **compilar no es desplegar, y `validate` tampoco.** Las
tres capas de verificacion estatica dieron verde en los siete casos.

## Criterio de terminado

```text
[x] az bicep build termina sin errores en los 15 ficheros
[x] los scripts PowerShell pasan el analizador de sintaxis, los bash pasan bash -n
[x] ningun secreto aparece en Git, outputs ni parametros versionados
[x] las contrasenas viajan por fichero temporal 600, no por linea de comandos
[x] las siete reglas conservan #INC_CORR# y su entity mapping, DCSync incluida
[x] las cuatro VM llevan identidad administrada, que AMA exige
[x] las VM sin IP publica tienen salida por NAT Gateway
[x] la etapa C no empieza hasta que las tablas respondan por KQL
[x] existe un procedimiento de borrado explicito, y apaga Defender P2
[ ] what-if no muestra cambios inesperados
[ ] desplegar dos veces no duplica recursos ni objetos de AD
```

**Estado real del despliegue:**

```text
Desplegado y verificado   etapa base, instrumentacion y detecciones.
                          Dominio promocionado, SACL del 4662 aplicada,
                          telemetria fluyendo, 7 reglas creadas y activas
Nunca desplegado          wec, linux-forwarder, custom-logs, threat-intel,
                          analytics-scale, budget, y los scripts
                          configure-wef, configure-cef
Ejecutado a medias        configure-m365.ps1, solo en modo -SoloComprobar
```

Lo que sigue sin demostrarse es la **idempotencia**: hizo falta apagar `conUeba`
para que un segundo despliegue no fallara, así que la repetibilidad completa
todavía no está probada.

### Dónde está la frontera

> El laboratorio de Azure y Sentinel base está terminado, desplegado y operativo.
> La equivalencia completa con las fases 1 a 21 todavía tiene pendientes las
> extensiones opcionales, Microsoft 365 y las pruebas de extremo a extremo.

Lo que la verificación en verde **sí** demuestra:

```text
infraestructura, dominio, NovaShop, Storage y Defender P2
auditoria y telemetria reales, con datos fluyendo
la SACL del 4662 aplicada y el evento emitiendose
7 reglas y 2 automation rules desplegadas y activas
```

Lo que **no** demuestra, y conviene no confundir:

```text
Microsoft 365      licencias, MDO, MDCA, Purview y MDI sin tocar
Extensiones        Content Hub queda habilitado para el siguiente despliegue;
                   WEC, CEF, logs personalizados, threat intelligence,
                   summary rules y presupuesto no se han ejecutado todavía
Deteccion real     6 de 7 reglas sin probar contra un ataque. La del DCSync SI:
                   probada de extremo a extremo con DSInternals, alerta High,
                   6 minutos entre el ataque y la alerta
Fases 10 y 20      son campanas manuales, por definicion no automatizables
Idempotencia       un segundo despliegue completo sin apagar nada
```

Los hallazgos de WEF, CEF, logs personalizados, TAXII, Content Hub y summary
rules se aplicaron antes de habilitar esos caminos. El estado operativo y las
puertas de validación vigentes quedan en `../gdat/BUILD_GDAT2.0.md`.

## Lo que sigue sin estar cubierto

Revisión cruzada de Codex, aplicada casi entera. Lo que queda abierto:

```text
NovaShop        Bicep crea el App Service y NOVASHOP_LAB_MODE. El codigo se
                publica despues con `deploy.sh publicar-app`; una ruta alternativa
                es opcional
Content Hub     instala 4 paquetes de los 12 de la fase 5, y no despliega el
                mainTemplate del contenido de cada solucion
Automation      las dos reglas son de triaje y cierre, no la asignacion a
                operator1 ni el etiquetado por origen de la fase 5
Fase 19         la summary rule es ARM; el onboarding irreversible del data
                lake, el KQL job y el notebook quedan como pasos de portal/VS Code
Fase 17         DCE, tabla, transformación y RBAC están declarados; falta el POST
                real del emisor y comprobar las filas
SDProp          la ACE de svc-sql sobre Domain Admins la revierte AdminSDHolder
                en unos 60 minutos. Hay que reponerla antes del ataque
```
