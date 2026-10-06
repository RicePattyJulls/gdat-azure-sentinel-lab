#!/usr/bin/env bash
#
# Ejecuta un DCSync controlado en MEMBER01 y comprueba si la regla 7 dispara.
#
# Uso:  source ./cargar-secretos.sh && ./probar-dcsync.sh

set -uo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARAMETROS="$AQUI/parameters/lab.bicepparam"

PREFIJO=$(grep -oP "prefijo\s*=\s*'\K[^']+" "$PARAMETROS" || echo 'gdat')
USUARIO=$(grep -oP "usuarioAdmin\s*=\s*'\K[^']+" "$PARAMETROS" || echo 'gdatadmin')
DOMINIO=$(grep -oP "nombreDominio\s*=\s*'\K[^']+" "$PARAMETROS" || echo 'novashop.local')
NETBIOS=$(grep -oP "netbiosDominio\s*=\s*'\K[^']+" "$PARAMETROS" || echo 'NOVASHOP')
WS_NOMBRE=$(grep -oP "nombreWorkspace\s*=\s*'\K[^']+" "$PARAMETROS" || echo "log-${PREFIJO}-soc")
RG_VM="${PREFIJO}-vm-lab"; RG_SOC="${PREFIJO}-soc"

log() { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
[[ -n "${GDAT_PWD_ADMIN:-}" ]] || { echo "Falta GDAT_PWD_ADMIN. source ./cargar-secretos.sh"; exit 1; }

log "Ejecutando el DCSync en ${PREFIJO}-MEMBER01 como $NETBIOS\\$USUARIO."
echo "  Tarda un par de minutos: instala DSInternals la primera vez."

az vm run-command invoke \
    -g "$RG_VM" -n "${PREFIJO}-MEMBER01" \
    --command-id RunPowerShellScript \
    --scripts "@$AQUI/scripts/probar-dcsync.ps1" \
    --parameters "Usuario=$USUARIO" "Password=$GDAT_PWD_ADMIN" \
                 "Dominio=$DOMINIO" "Netbios=$NETBIOS" \
    --query "value[0].message" -o tsv

WSID=$(az monitor log-analytics workspace show -g "$RG_SOC" --workspace-name "$WS_NOMBRE" --query customerId -o tsv)

log "Esperando el 4662 con los derechos de replicacion (hasta 10 min)."
LIMITE=$(( $(date +%s) + 600 ))
KQL='SecurityEvent
| where TimeGenerated > ago(20m)
| where EventID == 4662
| where Properties has_any ("1131f6aa-9c07-11d1-f79f-00c04fc2dcd2","1131f6ad-9c07-11d1-f79f-00c04fc2dcd2")
| extend Cuenta = tolower(iff(Account contains "\\", tostring(split(Account,"\\")[1]), Account))
| where Cuenta !endswith "$"
| summarize Intentos=count(), Ultimo=max(TimeGenerated) by Cuenta, Computer'

while :; do
    R=$(az monitor log-analytics query -w "$WSID" --analytics-query "$KQL" -o json 2>/dev/null)
    N=$(echo "$R" | jq 'length' 2>/dev/null || echo 0)
    if [[ "${N:-0}" -gt 0 ]]; then
        echo
        echo "  EVENTO DETECTADO. El 4662 llego con cuenta de usuario, no de equipo:"
        echo "$R" | jq -r '.[] | "    \(.Cuenta) en \(.Computer): \(.Intentos) intentos"'
        break
    fi
    [[ $(date +%s) -ge $LIMITE ]] && { echo "  El 4662 no llego en 10 min. La ingesta puede tardar mas."; break; }
    printf '.'
    sleep 30
done

log "Esperando la ALERTA de la regla 7 (hasta 15 min)."
echo "  La regla corre cada 5 minutos, asi que esto es normal que tarde."
LIMITE=$(( $(date +%s) + 900 ))
while :; do
    A=$(az monitor log-analytics query -w "$WSID" \
        --analytics-query 'SecurityAlert | where TimeGenerated > ago(1h) | where AlertName has "DCSync" | project TimeGenerated, AlertName, AlertSeverity' \
        -o json 2>/dev/null)
    N=$(echo "$A" | jq 'length' 2>/dev/null || echo 0)
    if [[ "${N:-0}" -gt 0 ]]; then
        echo
        echo "  ALERTA DISPARADA. La regla 7 funciona de extremo a extremo:"
        echo "$A" | jq -r '.[] | "    \(.TimeGenerated)  \(.AlertName)  \(.AlertSeverity)"'
        echo
        echo "  Con esto queda probada la unica frontera del nucleo que faltaba:"
        echo "  que un ataque real dispare la deteccion."
        exit 0
    fi
    [[ $(date +%s) -ge $LIMITE ]] && break
    printf '.'
    sleep 60
done

echo
echo "  La alerta no salio en 15 min. El evento SI llego, asi que la tuberia"
echo "  funciona. Revisa la regla en el portal:"
echo "    security.microsoft.com > Configuration > Analytics > DCSync mediante el evento 4662"
