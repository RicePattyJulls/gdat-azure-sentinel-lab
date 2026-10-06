#!/usr/bin/env bash
#
# Puerta de validacion de la etapa B.
#
# Comprueba con KQL que las tablas responden de verdad antes de dejar que la
# etapa C empiece a crear contenido de SOC. Una regla analitica sobre una tabla
# que aun no existe se crea sin protestar y no dispara nunca.
#
# Uso: validate-soc.sh <resource-group> <workspace> [minutos-de-espera]

set -euo pipefail

GRUPO="${1:?Falta el grupo de recursos}"
WORKSPACE="${2:?Falta el nombre del workspace}"
ESPERA_MIN="${3:-45}"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

WS_ID=$(az monitor log-analytics workspace show \
    --resource-group "$GRUPO" --workspace-name "$WORKSPACE" \
    --query customerId -o tsv)

log "Workspace $WORKSPACE resuelto."

# Tabla y numero minimo de filas que se considera senal viva.
TABLAS=(
    "Heartbeat:1"
    "SecurityEvent:1"
)

LIMITE=$(( $(date +%s) + ESPERA_MIN * 60 ))

for entrada in "${TABLAS[@]}"; do
    tabla="${entrada%%:*}"
    minimo="${entrada##*:}"

    log "Esperando datos en $tabla (minimo $minimo filas)."

    while :; do
        filas=$(az monitor log-analytics query \
            --workspace "$WS_ID" \
            --analytics-query "${tabla} | where TimeGenerated > ago(1h) | count" \
            --query "[0].Count" -o tsv 2>/dev/null || echo "0")

        if [[ "${filas:-0}" -ge "$minimo" ]]; then
            log "$tabla responde con $filas filas."
            break
        fi

        if [[ $(date +%s) -ge $LIMITE ]]; then
            log "ERROR: $tabla no entrego datos en $ESPERA_MIN minutos."
            exit 1
        fi

        log "$tabla aun vacia. Reintentando en 60s."
        sleep 60
    done
done

log "Etapa B validada. La etapa C puede empezar."
