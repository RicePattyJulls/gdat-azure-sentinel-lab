#!/usr/bin/env bash
#
# Borrado del laboratorio. Universal: solo cambian las variables de arriba.
#
# Lo importante que az group delete NO hace: purgar el workspace. Un workspace
# borrado normal entra en soft-delete y su NOMBRE queda reservado 14 dias. Si se
# vuelve a desplegar con el mismo nombre antes de ese plazo, falla por conflicto.
# El force=true lo borra de verdad y libera el nombre al momento.
#
# Uso:  ./teardown.sh          muestra que se borraria
#       ./teardown.sh --si     lo borra

set -uo pipefail

############################ VARIABLES #####################################

RG_VM="gdat-vm-lab"          # grupo de las maquinas
RG_SOC="gdat-soc"            # grupo del workspace
RG_WEB=""                    # grupo de la aplicacion, vacio si no existe
WS="log-gdat-soc"            # workspace a purgar
API_WS="2025-07-01"          # api version de Log Analytics

REGION="spaincentral"        # region para consultar la cuota

############################################################################

CONFIRMA="${1:-}"
[[ "$CONFIRMA" == "--si" ]] || echo ">>> SIMULACION. Nada se borra. Anade --si para ejecutar."

ejecutar() {
    if [[ "$CONFIRMA" == "--si" ]]; then
        "$@"
    else
        printf '   [simulado] %s\n' "$*"
    fi
}

##################### 1. PURGAR EL WORKSPACE ###############################
# Va PRIMERO. Despues de borrar el grupo ya no se puede leer su id.

echo
echo "== 1. Purgando el workspace $WS =="

ID=$(az resource list -g "$RG_SOC" \
        --resource-type "Microsoft.OperationalInsights/workspaces" \
        --query "[?name=='$WS'].id" -o tsv 2>/dev/null)

if [[ -n "$ID" ]]; then
    # Via corta y recomendada: el CLI construye la URI y la api-version.
    ejecutar az monitor log-analytics workspace delete \
        -g "$RG_SOC" -n "$WS" --force --yes

    # Via cruda equivalente, por si el CLI no expusiera --force:
    #   az rest --method delete \
    #     --uri "https://management.azure.com${ID}?api-version=${API_WS}&force=true"
else
    echo "   no existe $WS en $RG_SOC, nada que purgar"
fi

##################### 2. BORRAR LOS GRUPOS #################################

echo
echo "== 2. Borrando los grupos =="

for RG in "$RG_VM" "$RG_WEB" "$RG_SOC"; do
    [[ -z "$RG" ]] && continue
    if [[ "$(az group exists -n "$RG" 2>/dev/null)" == "true" ]]; then
        ejecutar az group delete -n "$RG" --yes --no-wait
        echo "   $RG lanzado"
    else
        echo "   $RG no existe"
    fi
done

##################### 3. DEFENDER FOR SERVERS ##############################
# Se activa a nivel de SUSCRIPCION: borrar los grupos no lo apaga y sigue
# facturando por maquina.

echo
echo "== 3. Devolviendo Defender for Servers al plan gratuito =="
ejecutar az security pricing create --name VirtualMachines --tier Free -o none

##################### 4. CONFIRMAR #########################################

echo
echo "== 4. Estado =="
az group list -o table 2>/dev/null

echo
echo "Cuota en $REGION. Tarda unos minutos en bajar tras el borrado:"
az vm list-usage -l "$REGION" \
    --query "[?contains(name.value,'cores')].{Recurso:localName, Uso:currentValue, Limite:limit}" \
    -o table 2>/dev/null
az network list-usages -l "$REGION" \
    --query "[?contains(name.value,'PublicIPAddresses')].{Recurso:name.localizedValue, Uso:currentValue, Limite:limit}" \
    -o table 2>/dev/null | head -4

echo
echo "NetworkWatcherRG se deja: es del sistema, Azure lo recrea y no gasta cuota."
