#!/usr/bin/env bash
#
# Fase 16 · receptor Syslog/CEF compatible con Azure Monitor Agent.
#
# AMA es el unico propietario del reenvio a 127.0.0.1:28330. Este fichero solo
# abre TCP/UDP 514; el emisor debe enviar CEF con facility local4.

set -euo pipefail

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

if [[ $EUID -ne 0 ]]; then
    printf '%s\n' 'Este script necesita privilegios de root.' >&2
    exit 1
fi

log 'Asegurando rsyslog instalado.'
if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq rsyslog
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q rsyslog
else
    printf '%s\n' 'Gestor de paquetes no reconocido.' >&2
    exit 1
fi

AMA_CONF=/etc/rsyslog.d/10-azuremonitoragent-omfwd.conf
limite=$((SECONDS + 600))
while [[ ! -s "$AMA_CONF" && $SECONDS -lt $limite ]]; do
    log 'Esperando la configuracion omfwd que genera AMA.'
    sleep 10
done
if [[ ! -s "$AMA_CONF" ]]; then
    printf 'AMA no creo %s; no se configura un reenvio alternativo que pueda duplicar datos.\n' "$AMA_CONF" >&2
    exit 1
fi

CONF=/etc/rsyslog.d/20-gdat-listeners.conf
LEGACY_CONF=/etc/rsyslog.d/10-gdat-cef.conf
temporal=$(mktemp)
respaldo=$(mktemp)
respaldo_legacy=$(mktemp)
tenia_anterior=0
tenia_legacy=0
trap 'rm -f -- "$temporal" "$respaldo" "$respaldo_legacy"' EXIT

cat > "$temporal" <<'CONFEOF'
# Gestionado por GDAT. AMA conserva en su propio fichero el unico omfwd.
module(load="imudp")
input(type="imudp" port="514")
module(load="imtcp")
input(type="imtcp" port="514")
CONFEOF

rsyslogd -N1 -f "$temporal"
if [[ -f "$CONF" ]]; then
    tenia_anterior=1
    cp -- "$CONF" "$respaldo"
fi

# Retira la configuracion de la version anterior de este mismo laboratorio,
# que intentaba crear su propio omfwd y reescribir una propiedad de solo lectura.
if [[ -f "$LEGACY_CONF" ]]; then
    tenia_legacy=1
    cp -- "$LEGACY_CONF" "$respaldo_legacy"
    rm -f -- "$LEGACY_CONF"
fi

if [[ ! -f "$CONF" ]] || ! cmp -s -- "$temporal" "$CONF"; then
    log "Convergiendo $CONF."
    install -o root -g root -m 0644 "$temporal" "$CONF"
else
    log "$CONF ya coincide con la configuracion deseada."
fi

if ! rsyslogd -N1; then
    if [[ $tenia_anterior -eq 1 ]]; then
        install -o root -g root -m 0644 "$respaldo" "$CONF"
    else
        rm -f -- "$CONF"
    fi
    if [[ $tenia_legacy -eq 1 ]]; then
        install -o root -g root -m 0644 "$respaldo_legacy" "$LEGACY_CONF"
    fi
    printf '%s\n' 'La configuracion completa de rsyslog no es valida; se restauro la anterior.' >&2
    exit 1
fi

# Tiene que existir un solo destino 28330 y debe ser el que administra AMA.
coincidencias=$(grep -RhoE 'port="?28330"?' /etc/rsyslog.d 2>/dev/null || true)
if [[ -z "$coincidencias" ]]; then
    cantidad_reenvios=0
else
    cantidad_reenvios=$(printf '%s\n' "$coincidencias" | wc -l)
fi
if [[ $cantidad_reenvios -ne 1 ]]; then
    printf 'Se esperaban 1 y se encontraron %s reenvios a 28330.\n' "$cantidad_reenvios" >&2
    exit 1
fi
if grep -qE 'port="?28330"?' "$CONF"; then
    printf '%s\n' 'La configuracion GDAT no puede competir con el omfwd de AMA.' >&2
    exit 1
fi

systemctl enable --now rsyslog
systemctl restart rsyslog
systemctl is-active --quiet rsyslog

udp_escucha=0
tcp_escucha=0
ss -H -lnu | awk '{print $5}' | grep -Eq '(^|:)514$' && udp_escucha=1 || true
ss -H -lnt | awk '{print $4}' | grep -Eq '(^|:)514$' && tcp_escucha=1 || true
if [[ $udp_escucha -ne 1 || $tcp_escucha -ne 1 ]]; then
    printf 'Puerto 514 incompleto: udp=%s, tcp=%s.\n' "$udp_escucha" "$tcp_escucha" >&2
    exit 1
fi

logger -p local4.info -t GDAT 'CEF:0|GDAT|Forwarder|1|100|Prueba local4|1|msg=validacion'
log 'rsyslog converge: TCP/UDP 514 y un unico omfwd de AMA a 28330.'
