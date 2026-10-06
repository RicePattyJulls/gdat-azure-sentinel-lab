#!/usr/bin/env bash
#
# Verificacion completa del laboratorio, de una sola pasada.
#
# No modifica nada. Comprueba lo que Bicep dejo en pie y lo que la telemetria
# dice de verdad, no lo que deberia decir.
#
# Uso:  ./verificar.sh            todo
#       ./verificar.sh rapido     salta las consultas KQL, que son las lentas

set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARAMETROS="$AQUI/parameters/lab.bicepparam"

PREFIJO=$(grep -oP "prefijo\s*=\s*'\K[^']+" "$PARAMETROS" || echo 'gdat')
WS_NOMBRE=$(grep -oP "nombreWorkspace\s*=\s*'\K[^']+" "$PARAMETROS" || echo "log-${PREFIJO}-soc")
REGION_VM=$(grep -oP "locationVm\s*=\s*'\K[^']+" "$PARAMETROS" || echo 'spaincentral')
RG_VM="${PREFIJO}-vm-lab"
RG_SOC="${PREFIJO}-soc"
MODO="${1:-completo}"

OK=0; AVISO=0; FALLO=0

titulo() { printf '\n\033[1;36m== %s %s\033[0m\n' "$1" "$(printf '=%.0s' $(seq 1 $((60 - ${#1}))))"; }
ok()     { printf '  \033[1;32m[OK]\033[0m    %s\n' "$1"; OK=$((OK+1)); }
aviso()  { printf '  \033[1;33m[AVISO]\033[0m %s\n' "$1"; AVISO=$((AVISO+1)); }
fallo()  { printf '  \033[1;31m[FALLO]\033[0m %s\n' "$1"; FALLO=$((FALLO+1)); }
dato()   { printf '          %s\n' "$1"; }

az account show >/dev/null 2>&1 || { echo "No hay sesion de Azure. az login"; exit 1; }
SUB=$(az account show --query id -o tsv)

############################################################################
titulo "1. Grupos y cuota"
############################################################################

for rg in "$RG_VM" "$RG_SOC"; do
    if [[ "$(az group exists -n "$rg" 2>/dev/null)" == "true" ]]; then
        n=$(az resource list -g "$rg" --query "length(@)" -o tsv 2>/dev/null)
        ok "$rg existe, $n recursos"
    else
        fallo "$rg no existe"
    fi
done

CORES=$(az vm list-usage -l "$REGION_VM" --query "[?contains(name.value,'cores')].currentValue|[0]" -o tsv 2>/dev/null)
LIMITE=$(az vm list-usage -l "$REGION_VM" --query "[?contains(name.value,'cores')].limit|[0]" -o tsv 2>/dev/null)
IPS=$(az network list-usages -l "$REGION_VM" --query "[?contains(name.value,'PublicIPAddresses')].currentValue|[0]" -o tsv 2>/dev/null)
dato "vCPU ${CORES:-?}/${LIMITE:-?}   IP publicas ${IPS:-?}/3"

############################################################################
titulo "2. Maquinas virtuales"
############################################################################

VMS=$(az vm list -g "$RG_VM" --show-details \
    --query "[].{n:name, p:powerState, ip:publicIps, priv:privateIps, id:identity.type}" -o json 2>/dev/null)

if [[ "$(echo "$VMS" | jq 'length')" == "0" ]]; then
    fallo "no hay ninguna VM en $RG_VM"
else
    echo "$VMS" | jq -r '.[] | "\(.n)|\(.p)|\(.ip // "-")|\(.priv)|\(.id // "NINGUNA")"' | while IFS='|' read -r n p ip priv id; do
        if [[ "$p" == "VM running" ]]; then ok "$n  $p"; else aviso "$n  $p"; fi
        dato "privada $priv   publica ${ip:--}   identidad $id"
        # AMA no funciona sin identidad administrada
        [[ "$id" == "NINGUNA" ]] && fallo "$n sin identidad administrada: AMA no podra autenticar"
    done
fi

############################################################################
titulo "3. runCommands: los scripts que corrieron dentro"
############################################################################

for vm in $(az vm list -g "$RG_VM" --query "[].name" -o tsv 2>/dev/null); do
    printf '  %s\n' "$vm"
    salida=$(az vm run-command list -g "$RG_VM" --vm-name "$vm" \
        --query "[].{n:name, e:provisioningState}" -o tsv 2>/dev/null)
    if [[ -z "$salida" ]]; then
        aviso "    sin runCommands"
        continue
    fi
    while IFS=$'\t' read -r n e; do
        if [[ "$e" == "Succeeded" ]]; then ok "    $n"; else fallo "    $n -> $e"; fi
    done <<< "$salida"
done

############################################################################
titulo "4. La SACL del 4662"
############################################################################
# Es lo que le faltaba al laboratorio anterior y la razon de que la regla del
# DCSync no tuviera datos que consultar.

DC=$(az vm list -g "$RG_VM" --query "[?contains(name,'DC01')].name|[0]" -o tsv 2>/dev/null)
if [[ -z "$DC" ]]; then
    aviso "no se encontro el controlador de dominio"
else
    OUT=$(az vm run-command show -g "$RG_VM" --vm-name "$DC" \
        --run-command-name configurar-auditoria --instance-view \
        --query "instanceView.output" -o tsv 2>/dev/null)

    grep -q "Get-Changes-All" <<< "$OUT" && ok "SACL de replicacion aplicada" \
        || fallo "no consta la SACL de DS-Replication-Get-Changes-All"
    grep -q "Directory Service Access activa" <<< "$OUT" && ok "Directory Service Access activa" \
        || aviso "auditpol no confirmo Directory Service Access"
    grep -q "Extension de Advanced Audit Policy registrada" <<< "$OUT" && ok "CSE de auditoria registrada en la GPO" \
        || aviso "la extension de auditoria pudo no registrarse"
fi

############################################################################
titulo "5. Reglas analiticas y automation rules"
############################################################################

API="2023-12-01-preview"
BASE="https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG_SOC/providers/Microsoft.OperationalInsights/workspaces/$WS_NOMBRE/providers/Microsoft.SecurityInsights"

REGLAS=$(az rest --method get --url "$BASE/alertRules?api-version=$API" \
    --query "value[].{n:properties.displayName, k:kind, s:properties.severity, e:properties.enabled, d:properties.description}" -o json 2>/dev/null)

if [[ -z "$REGLAS" || "$REGLAS" == "null" ]]; then
    fallo "no se pudieron leer las reglas"
else
    PROPIAS=$(echo "$REGLAS" | jq '[.[] | select(.k != "Fusion")] | length')
    [[ "$PROPIAS" -ge 7 ]] && ok "$PROPIAS reglas propias creadas" || fallo "solo $PROPIAS reglas propias, esperadas 7"

    echo "$REGLAS" | jq -r '.[] | select(.k != "Fusion") | "\(.n)|\(.k)|\(.s)|\(.e)|\(.d)"' | while IFS='|' read -r n k s e d; do
        [[ "$e" == "true" ]] && printf '  \033[1;32m[OK]\033[0m    %-42s %-10s %s\n' "$n" "$k" "$s" \
                             || printf '  \033[1;31m[FALLO]\033[0m %-42s DESHABILITADA\n' "$n"
        # Sin el tag la alerta queda fuera del motor de correlacion de XDR
        [[ "$d" != \#INC_CORR#* ]] && printf '          \033[1;33mfalta #INC_CORR# en la descripcion\033[0m\n'
    done

    NRT=$(echo "$REGLAS" | jq -r '[.[] | select(.k=="NRT")] | length')
    [[ "$NRT" -ge 1 ]] && ok "la regla de grupo privilegiado es NRT" || fallo "ninguna regla NRT: la de grupo privilegiado deberia serlo"
fi

AUTO=$(az rest --method get --url "$BASE/automationRules?api-version=$API" \
    --query "length(value)" -o tsv 2>/dev/null)
[[ "${AUTO:-0}" -ge 2 ]] && ok "$AUTO automation rules" || aviso "${AUTO:-0} automation rules, esperadas 2"

############################################################################
titulo "6. Telemetria"
############################################################################

if [[ "$MODO" == "rapido" ]]; then
    dato "saltado por modo rapido"
else
    WSID=$(az monitor log-analytics workspace show -g "$RG_SOC" --workspace-name "$WS_NOMBRE" \
        --query customerId -o tsv 2>/dev/null)

    if [[ -z "$WSID" ]]; then
        fallo "no se pudo resolver el workspace $WS_NOMBRE"
    else
        consultar() {
            az monitor log-analytics query -w "$WSID" --analytics-query "$1" -o json 2>/dev/null
        }

        for t in Heartbeat SecurityEvent; do
            n=$(consultar "$t | where TimeGenerated > ago(2h) | count" | jq -r '.[0].Count // 0')
            [[ "${n:-0}" -gt 0 ]] && ok "$t: $n filas en 2h" || fallo "$t vacia"
        done

        printf '\n  EventID mas frecuentes:\n'
        consultar "SecurityEvent | where TimeGenerated > ago(2h) | summarize C=count() by EventID | top 8 by C desc" \
            | jq -r '.[] | "          \(.EventID)  \(.C)"' 2>/dev/null

        # El 4662 solo aparece tras un DCSync, pero si la SACL falta no aparece nunca
        n=$(consultar "SecurityEvent | where EventID == 4662 | count" | jq -r '.[0].Count // 0')
        if [[ "${n:-0}" -gt 0 ]]; then
            ok "4662 presente: $n filas. La regla del DCSync tiene datos"
        else
            dato "4662 aun sin filas. Es lo normal hasta que se ejecute un DCSync"
        fi
    fi
fi

############################################################################
titulo "7. NovaShop y almacenamiento"
############################################################################

APP=$(az webapp list -g "$RG_VM" --query "[0].{n:name, e:state, h:defaultHostName}" -o json 2>/dev/null)
if [[ "$(echo "$APP" | jq -r '.n // "null"')" == "null" ]]; then
    aviso "no hay App Service en $RG_VM"
else
    NOMBRE=$(echo "$APP" | jq -r '.n'); HOST=$(echo "$APP" | jq -r '.h')
    ok "NovaShop: $NOMBRE ($(echo "$APP" | jq -r '.e'))"
    dato "https://$HOST"

    LAB=$(az webapp config appsettings list -g "$RG_VM" -n "$NOMBRE" \
        --query "[?name=='NOVASHOP_LAB_MODE'].value|[0]" -o tsv 2>/dev/null)
    [[ "$LAB" == "on" ]] && ok "NOVASHOP_LAB_MODE=on, la ruta vulnerable esta expuesta" \
                         || fallo "NOVASHOP_LAB_MODE='${LAB:-vacio}'. Sin 'on' no hay SQLi que explotar"

    CODIGO=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$HOST" 2>/dev/null)
    case "$CODIGO" in
        200)
            if curl -fsS --max-time 10 "https://$HOST" 2>/dev/null \
                | grep -q 'NovaShop Security Lab'; then
                ok "responde 200 y el codigo de NovaShop esta publicado"
            else
                fallo "responde 200, pero sigue la pagina predeterminada de Azure. Ejecuta: ./deploy.sh publicar-app"
            fi
            ;;
        403) aviso "responde 403: la IP actual no coincide con la lista blanca. Actualiza GDAT_IP_ADMIN y ejecuta ./deploy.sh desplegar" ;;
        *)   aviso "responde $CODIGO" ;;
    esac
fi

ST=$(az storage account list -g "$RG_VM" --query "[0].name" -o tsv 2>/dev/null)
if [[ -n "$ST" ]]; then
    ok "storage $ST"
    CONT=$(az storage container list --account-name "$ST" --auth-mode login \
        --query "[].name" -o tsv 2>/dev/null | tr '\n' ' ')
    [[ "$CONT" == *exfil* ]] && ok "contenedor 'exfil' presente" \
                             || aviso "contenedores: ${CONT:-ninguno visible}. El ataque escribe en 'exfil'"
fi

############################################################################
titulo "8. Defender for Servers"
############################################################################

PLAN=$(az security pricing show --name VirtualMachines --query "{t:pricingTier, s:subPlan}" -o json 2>/dev/null)
TIER=$(echo "$PLAN" | jq -r '.t // "?"'); SUBP=$(echo "$PLAN" | jq -r '.s // "?"')
if [[ "$TIER" == "Standard" && "$SUBP" == "P2" ]]; then
    ok "Defender for Servers $TIER $SUBP"
else
    aviso "Defender for Servers: $TIER $SUBP (se esperaba Standard P2)"
fi

############################################################################
titulo "Resumen"
############################################################################

printf '  \033[1;32m%d OK\033[0m   \033[1;33m%d avisos\033[0m   \033[1;31m%d fallos\033[0m\n' "$OK" "$AVISO" "$FALLO"

if [[ "$FALLO" -eq 0 ]]; then
    cat <<'FIN'

  El laboratorio esta en pie. Lo que queda es lo que no es ARM:

    pwsh ./scripts/configure-m365.ps1 -Dominio <tutenant>.onmicrosoft.com
    el sensor de MDI en DC01, cuando MDE la haya onboardeado
    MDCA, FIM y comprobar el Primary en el portal de Defender

FIN
else
    printf '\n  Hay %d fallo(s). Revisalos antes de dar el lab por bueno.\n\n' "$FALLO"
    exit 1
fi
