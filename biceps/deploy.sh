#!/usr/bin/env bash
#
# Despliegue del laboratorio GDAT.
#
# Bicep describe el estado final. Lo que no cabe en una plantilla son las
# esperas que consultan estado real, y por eso existe este script: dependsOn
# garantiza que ARM termino, no que el servicio responda.
#
# Uso:
#   ./deploy.sh preparar         registra los resource providers de la suscripcion
#   ./deploy.sh preview          compila y muestra what-if, no despliega nada
#   ./deploy.sh validar-plantilla validacion completa del servicio, VM incluidas
#   ./deploy.sh desplegar        despliega de verdad
#   ./deploy.sh publicar-app [DIR] publica NovaShop; sin DIR usa ./novashop
#   ./deploy.sh validar          comprueba que las tablas responden
#   ./deploy.sh destruir         borra los dos grupos de recursos
#
# Este script solo las lee; cargar-secretos.sh puede guardarlas en .env.local (600):
#
#   export GDAT_PWD_ADMIN='...'      administrador local de las VM
#   export GDAT_PWD_DSRM='...'       modo restauracion del DC
#   export GDAT_PWD_NEGOCIO='...'    cuentas de negocio
#   export GDAT_PWD_CHARLIE='...'    charlie.dev
#   export GDAT_PWD_SVCSQL='...'     svc-sql
#   export GDAT_PWD_SVCBACKUP='...'  svc-backup

set -euo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLANTILLA="$AQUI/main.bicep"
PARAMETROS="$AQUI/parameters/lab.bicepparam"
DESPLIEGUE="gdat-$(date +%Y%m%d-%H%M%S)"

log()   { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
fatal() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

comprobar_entorno() {
    command -v az >/dev/null 2>&1 || fatal "Azure CLI no esta instalado."
    az bicep version >/dev/null 2>&1 || fatal "Bicep no esta instalado. Ejecuta: az bicep install"
    az account show >/dev/null 2>&1 || fatal "No hay sesion de Azure. Ejecuta: az login"

    local sub
    sub=$(az account show --query name -o tsv)
    log "Suscripcion activa: $sub"
}

comprobar_secretos() {
    local faltan=()
    for v in GDAT_PWD_ADMIN GDAT_PWD_DSRM GDAT_PWD_NEGOCIO GDAT_PWD_CHARLIE GDAT_PWD_SVCSQL GDAT_PWD_SVCBACKUP; do
        [[ -n "${!v:-}" ]] || faltan+=("$v")
    done
    if [[ ${#faltan[@]} -gt 0 ]]; then
        fatal "Faltan variables de entorno: ${faltan[*]}"
    fi
}

# Las contrasenas no se pasan por argumento ni por fichero: lab.bicepparam las
# lee del entorno con readEnvironmentVariable. Asi no aparecen en la tabla de
# procesos ni quedan en disco. Este script solo comprueba que estan puestas.

# En una suscripcion recien creada los resource providers no estan registrados.
# El despliegue falla a mitad con NoRegisteredProviderFound, y registrar cada uno
# tarda minutos, asi que se hace antes y en paralelo.
PROVIDERS=(
    Microsoft.Compute
    Microsoft.Network
    Microsoft.Storage
    Microsoft.Web
    Microsoft.ManagedIdentity
    Microsoft.OperationalInsights
    Microsoft.OperationsManagement
    Microsoft.SecurityInsights
    Microsoft.Insights
    Microsoft.Security
)

registrar_providers() {
    log "Comprobando resource providers."
    local pendientes=()

    for prov in "${PROVIDERS[@]}"; do
        local estado
        estado=$(az provider show --namespace "$prov" --query registrationState -o tsv 2>/dev/null || echo "NotFound")
        if [[ "$estado" != "Registered" ]]; then
            printf '  %-32s %s -> registrando\n' "$prov" "$estado"
            az provider register --namespace "$prov" -o none 2>/dev/null || true
            pendientes+=("$prov")
        else
            printf '  %-32s Registered\n' "$prov"
        fi
    done

    [[ ${#pendientes[@]} -eq 0 ]] && { log "Todos registrados."; return 0; }

    log "Esperando a ${#pendientes[@]} provider(s). Suele tardar entre 1 y 5 minutos."
    local limite=$(( $(date +%s) + 900 ))

    while [[ ${#pendientes[@]} -gt 0 ]]; do
        local quedan=()
        for prov in "${pendientes[@]}"; do
            local estado
            estado=$(az provider show --namespace "$prov" --query registrationState -o tsv 2>/dev/null || echo "Unknown")
            if [[ "$estado" == "Registered" ]]; then
                printf '  %-32s Registered\n' "$prov"
            else
                quedan+=("$prov")
            fi
        done
        pendientes=("${quedan[@]}")

        [[ ${#pendientes[@]} -eq 0 ]] && break

        if [[ $(date +%s) -ge $limite ]]; then
            fatal "Estos providers siguen sin registrarse: ${pendientes[*]}"
        fi
        sleep 20
    done

    log "Providers listos."
}

# Comprobaciones que Bicep no puede hacer solo: combinaciones de parametros que
# compilan pero que Azure rechaza al desplegar.
comprobar_coherencia() {
    local forwarder clave miembro presupuesto

    [[ -n "${GDAT_IP_ADMIN:-}" ]] || fatal "Falta GDAT_IP_ADMIN. Define la IP publica actual:

    export GDAT_IP_ADMIN=\"\$(curl -fsS https://api.ipify.org)/32\""

    [[ "$GDAT_IP_ADMIN" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ ]] \
        || fatal "GDAT_IP_ADMIN debe tener formato IPv4/32; recibido: $GDAT_IP_ADMIN"

    log "IP administrativa declarada: $GDAT_IP_ADMIN"

    forwarder=$(grep -oP "conForwarder\s*=\s*\K\w+" "$PARAMETROS" || echo 'false')
    clave=$(grep -oP "clavePublicaSsh\s*=\s*'\K[^']*" "$PARAMETROS" || echo '')
    miembro=$(grep -oP "tamanoMember\s*=\s*'\K[^']+" "$PARAMETROS" || echo '')
    presupuesto=$(grep -oP "conPresupuesto\s*=\s*\K\w+" "$PARAMETROS" || echo 'false')

    if [[ "$presupuesto" == "true" ]] \
       && grep -qP "correosPresupuesto\s*=\s*\[\s*\]" "$PARAMETROS"; then
        fatal "conPresupuesto esta en true pero correosPresupuesto esta vacio.
  Anade al menos un correo de facturacion antes de desplegar."
    fi

    if [[ "$forwarder" == "true" && -z "$clave" ]]; then
        fatal "conForwarder esta en true pero clavePublicaSsh esta vacio.
  Azure rechaza una VM Linux sin clave ni contrasena. Genera una:

    ssh-keygen -t ed25519 -f ~/.ssh/gdat_lab -N ''
    cat ~/.ssh/gdat_lab.pub

  y pega el contenido en clavePublicaSsh, en parameters/lab.bicepparam"
    fi

    # WEC01 y FWD01 son las dos Spot: usan el contador Low-priority, que va aparte
    # de la regular. Ninguna obliga ya a encoger MEMBER01. Este aviso solo salta
    # si se les quita el Spot a mano.
    if [[ "$forwarder" == "true" && "$miembro" == "Standard_B2as_v2" && "$(grep -oP "usarSpot\s*=\s*\K\w+" "$PARAMETROS" || echo true)" == "false" ]]; then
        cat <<'AVISO'

  AVISO de cuota: conForwarder esta en true y MEMBER01 sigue con 2 vCPU.
  DC01 (2) + MEMBER01 (2) + FWD01 (1) son 5 y el tope son 4.

  Y no basta con cambiar las dos cosas a la vez: ARM puede intentar crear FWD01
  antes de haber liberado el core de MEMBER01, y en ese instante pide 5. Van en
  DOS pasadas:

    1. tamanoMember = 'Standard_B1ms', conForwarder = false  ->  desplegar
       (esto reinicia MEMBER01: redimensionar desasigna la VM)
       comprobar que la cuota baja a 3 de 4
    2. conForwarder = true  ->  desplegar

AVISO
    fi
}

comprobar_cuota() {
    local region
    region=$(grep -oP "locationVm\s*=\s*'\K[^']+" "$PARAMETROS" || echo 'spaincentral')

    log "Cuotas de computo en $region:"
    # Azure lleva DOS contadores independientes. Las VM Spot no consumen la cuota
    # regular: van contra 'Low-priority'. Mirar solo la primera lleva a creer que
    # no cabe una maquina Spot cuando si cabe.
    az vm list-usage --location "$region" \
        --query "[?localName=='Total Regional vCPUs' || localName=='Total Regional Low-priority vCPUs' || localName=='Standard DASv5 Family vCPUs'].{Recurso:localName, Uso:currentValue, Limite:limit}" \
        -o table 2>/dev/null || log "No se pudo consultar la cuota."

    cat <<'AVISO'

  Como se reparte:
    DC01 y MEMBER01   4 vCPU   cuota REGULAR: en trial son 4, la consumen entera
    WEC01             2 vCPU   cuota SPOT (Low-priority), que va aparte y son 3
    FWD01             1 vCPU   cuota SPOT tambien. Con WEC01 llenan justo 3/3

  Ninguna de las dos toca la cuota regular, asi que no hay que encoger MEMBER01.

  Las suscripciones de prueba no admiten ampliar cuota; hay que pasarlas a pago
  por uso. Una VM Spot puede ser desalojada si falta capacidad en la region.

AVISO
}

# Los settings de UEBA exigen ETag cuando ya existen, pero la plantilla no
# permite enviarlo de forma valida. En un workspace nuevo se crean una vez; en
# las etapas y despliegues posteriores se omiten. Esto hace que el parametro
# seguro para un tenant nuevo sea true sin romper la segunda ejecucion.
determinar_ueba_base() {
    UEBA_BASE=true

    local rg_soc="${PREFIJO}-soc"
    local ws
    ws=$(grep -oP "nombreWorkspace\s*=\s*'\K[^']+" "$PARAMETROS" || echo "log-${PREFIJO}-soc")

    if ! az monitor log-analytics workspace show -g "$rg_soc" -n "$ws" >/dev/null 2>&1; then
        log "UEBA: workspace nuevo; se activara en la etapa base."
        return
    fi

    local ws_id cantidad
    ws_id=$(az monitor log-analytics workspace show -g "$rg_soc" -n "$ws" --query id -o tsv)
    cantidad=$(az rest --method get \
        --url "https://management.azure.com${ws_id}/providers/Microsoft.SecurityInsights/settings?api-version=2023-12-01-preview" \
        --query "length(value[?name=='EntityAnalytics' || name=='Ueba'])" -o tsv 2>/dev/null || echo 0)

    case "$cantidad" in
        0)
            log "UEBA: no existen settings; se activaran en la etapa base."
            ;;
        2)
            UEBA_BASE=false
            log "UEBA: EntityAnalytics y Ueba ya existen; se omiten para preservar idempotencia."
            ;;
        *)
            fatal "UEBA esta en estado parcial ($cantidad de 2 settings).
  Revisa EntityAnalytics y Ueba antes de desplegar; no se sobrescriben a ciegas."
            ;;
    esac
}

case "${1:-preview}" in

    preparar)
        comprobar_entorno
        registrar_providers
        comprobar_cuota
        log "Suscripcion preparada. Siguiente: ./deploy.sh preview"
        ;;

    validar-plantilla)
        comprobar_entorno
        comprobar_coherencia
        comprobar_secretos
        log "Validando la plantilla completa contra el servicio."
        log "Esto SI evalua las VM, que what-if omite por llevar parametros seguros."
        az deployment sub validate \
            --name "validate-$DESPLIEGUE" \
            --location "$(grep -oP "locationWorkspace\s*=\s*'\K[^']+" "$PARAMETROS" || echo 'francecentral')" \
            --template-file "$PLANTILLA" \
            --parameters "$PARAMETROS" \
            --query "{estado:properties.provisioningState, error:error}" -o json
        log "Si estado es Succeeded y error es null, la plantilla es desplegable."
        ;;

    preview)
        comprobar_entorno
        comprobar_coherencia
        log "Compilando la plantilla."
        az bicep build --file "$PLANTILLA" --stdout > /dev/null
        log "Compila sin errores."
        comprobar_cuota
        comprobar_secretos
        log "Calculando what-if. Nada se despliega."
        az deployment sub what-if \
            --name "$DESPLIEGUE" \
            --location "$(grep -oP "locationWorkspace\s*=\s*'\K[^']+" "$PARAMETROS" || echo 'francecentral')" \
            --template-file "$PLANTILLA" \
            --parameters "$PARAMETROS"
        ;;

    publicar-app)
        comprobar_entorno
        command -v zip >/dev/null 2>&1 || fatal "Falta zip en el equipo local."

        # Orden de resolucion: argumento, variable de entorno y, por ultimo, la
        # copia incluida en el repositorio. El tercero es el que hace que una
        # entrega funcione sin configurar nada.
        origen="${2:-${GDAT_NOVASHOP_DIR:-$AQUI/novashop}}"
        [[ -n "$origen" ]] || fatal "Indica el directorio del codigo de NovaShop:

    ./deploy.sh publicar-app /ruta/LAB_SC200_NOVASHOP

  Tambien puedes definir GDAT_NOVASHOP_DIR."

        [[ -d "$origen" ]] || fatal "No existe el directorio: $origen"
        for requerido in app.py requirements.txt schema.sql templates static; do
            [[ -e "$origen/$requerido" ]] || fatal "NovaShop incompleta: falta $origen/$requerido"
        done

        prefijo=$(grep -oP "prefijo\s*=\s*'\K[^']+" "$PARAMETROS" || echo 'gdat')
        rg_app="${prefijo}-vm-lab"
        app=$(az webapp list -g "$rg_app" \
            --query "[?starts_with(name, '${prefijo}-novashop-')].name | [0]" -o tsv)
        [[ -n "$app" ]] || fatal "No se encontro ${prefijo}-novashop-* en $rg_app.
  Despliega primero la fase 5."

        temporal=$(mktemp -d)
        paquete="$temporal/novashop.zip"
        trap 'rm -rf "$temporal"' EXIT

        log "Empaquetando NovaShop desde $origen."
        (
            cd "$origen"
            zip -qr "$paquete" app.py requirements.txt schema.sql templates static
        )

        log "Publicando $app mediante Zip Deploy; Oryx instalara requirements.txt."
        az webapp deploy \
            --resource-group "$rg_app" \
            --name "$app" \
            --src-path "$paquete" \
            --type zip \
            --clean true \
            --restart true \
            --timeout 900000 \
            -o none

        host=$(az webapp show -g "$rg_app" -n "$app" --query defaultHostName -o tsv)
        log "NovaShop publicada: https://$host"
        log "Siguiente puerta: comprobar la pagina y AppServiceConsoleLogs antes del ataque."
        ;;

    desplegar)
        comprobar_entorno
        comprobar_coherencia
        comprobar_secretos
        registrar_providers
        comprobar_cuota

        read -r -p "Desplegar el laboratorio ahora? Escribe 'si' para continuar: " respuesta
        [[ "$respuesta" == "si" ]] || fatal "Cancelado."

        REGION_WS="$(grep -oP "locationWorkspace\s*=\s*'\K[^']+" "$PARAMETROS" || echo 'francecentral')"
        PREFIJO="$(grep -oP "prefijo\s*=\s*'\K[^']+" "$PARAMETROS" || echo 'gdat')"
        determinar_ueba_base

        # Tres despliegues incrementales del mismo fichero, con una puerta real
        # entre ellos. Un unico despliegue crearia las reglas analiticas antes
        # de que existan las tablas sobre las que consultan: se crean sin
        # protestar y no disparan nunca.
        desplegar_etapa() {
            local nombre="$1"; shift

            # La ultima etapa no lleva overrides. Un --parameters sin argumento
            # detras hace fallar al CLI, asi que solo se anade si hay algo.
            local extra=()
            if [[ $# -gt 0 ]]; then
                extra=(--parameters "$@")
            fi

            log "Desplegando $nombre."
            az deployment sub create \
                --name "${DESPLIEGUE}-${nombre}" \
                --location "$REGION_WS" \
                --template-file "$PLANTILLA" \
                --parameters "$PARAMETROS" \
                "${extra[@]}" \
                -o none
            log "$nombre completada."
        }

        # --- Etapa 0 y A: workspace, red y dominio -------------------------
        # La promocion del DC reinicia la maquina. El runCommand esperar-ad no
        # deja avanzar hasta que DNS, Kerberos y LDAP responden de verdad.
        desplegar_etapa "base" conInstrumentacion=false conDetecciones=false \
            conWec=false conForwarder=false conUeba="$UEBA_BASE"

        # --- Etapa B: cargas e instrumentacion -----------------------------
        desplegar_etapa "instrumentacion" conInstrumentacion=true \
            conDetecciones=false conUeba=false

        # --- Puerta: las tablas tienen que responder por KQL ----------------
        log "Puerta de validacion: esperando telemetria real antes de crear detecciones."
        if ! "$AQUI/scripts/validate-soc.sh" "${PREFIJO}-soc" "log-${PREFIJO}-soc"; then
            fatal "Las tablas no respondieron. La etapa C no se despliega: las reglas quedarian mudas."
        fi

        # --- Etapa C: contenido de SOC -------------------------------------
        desplegar_etapa "detecciones" conUeba=false

        log "Salidas del despliegue:"
        az deployment sub show --name "${DESPLIEGUE}-detecciones" --query properties.outputs -o json

        cat <<'PENDIENTE'

  Bicep ha terminado. Lo que queda es lo que no es ARM y se activa a mano:

    1. Publicar NovaShop: ./deploy.sh publicar-app
    2. Comprobar o conectar el workspace como Primary en Defender
    3. Activar el sensor de MDI en DC01, despues de comprobar que MDE
       la ha onboardeado

  Microsoft 365, MDO, MDCA y Purview se convergen ANTES con
  scripts/configure-m365.ps1; aqui solo se comprueba su estado.

  MDE, MDI, UEBA y MDCA conservan sus latencias. Bicep elimina clics, no
  acelera los servicios.

PENDIENTE
        ;;

    validar)
        comprobar_entorno
        local_rg=$(grep -oP "prefijo\s*=\s*'\K[^']+" "$PARAMETROS" || echo 'gdat')
        "$AQUI/scripts/validate-soc.sh" "${local_rg}-soc" "log-${local_rg}-soc"
        ;;

    destruir)
        comprobar_entorno
        prefijo=$(grep -oP "prefijo\s*=\s*'\K[^']+" "$PARAMETROS" || echo 'gdat')

        cat <<AVISO

  Se van a borrar estos dos grupos de recursos y todo lo que contienen:

    ${prefijo}-vm-lab
    ${prefijo}-soc

  El segundo incluye el workspace y con el toda la telemetria recogida.
  Bicep no tiene comando destroy: esto es un borrado manual explicito.

AVISO
        read -r -p "Escribe el prefijo '$prefijo' para confirmar: " confirmacion
        [[ "$confirmacion" == "$prefijo" ]] || fatal "Cancelado."

        # El workspace PRIMERO y con --force. Un borrado normal lo deja en
        # soft-delete y reserva su nombre 14 dias, asi que el siguiente
        # despliegue con el mismo nombre falla por conflicto. Y hay que leerlo
        # antes de borrar el grupo, o ya no se puede.
        WS=$(grep -oP "nombreWorkspace\s*=\s*'\K[^']+" "$PARAMETROS" || echo "log-${prefijo}-soc")
        if az monitor log-analytics workspace show -g "${prefijo}-soc" -n "$WS" >/dev/null 2>&1; then
            log "Purgando el workspace $WS con --force."
            az monitor log-analytics workspace delete -g "${prefijo}-soc" -n "$WS" --force --yes -o none 2>/dev/null \
                || log "No se pudo purgar. El nombre quedara reservado 14 dias."
        fi

        # Defender for Servers P2 se activa a nivel de SUSCRIPCION: borrar los
        # grupos de recursos no lo apaga y sigue facturando por maquina.
        log "Devolviendo Defender for Servers al plan gratuito."
        az security pricing create --name VirtualMachines --tier Free -o none 2>/dev/null \
            || log "No se pudo cambiar el plan. Revisalo a mano en Defender for Cloud."

        for rg in "${prefijo}-vm-lab" "${prefijo}-soc"; do
            if az group exists --name "$rg" | grep -q true; then
                log "Borrando $rg."
                az group delete --name "$rg" --yes --no-wait
            else
                log "$rg no existe."
            fi
        done
        log "Borrado lanzado en segundo plano."
        ;;

    *)
        sed -n '3,25p' "${BASH_SOURCE[0]}"
        exit 1
        ;;
esac
