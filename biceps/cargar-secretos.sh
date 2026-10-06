#!/usr/bin/env bash
#
# Genera o carga las contrasenas del laboratorio.
#
# Las guarda en .env.local con permisos 600 y fuera de Git, para no tener que
# reescribirlas cada vez que abres una terminal. Es un compromiso: estan en
# disco, pero solo tu usuario las lee y nunca entran en el repositorio ni en la
# linea de comandos de az.
#
# Uso:  source ./cargar-secretos.sh
#
# Con source, no ejecutandolo: si lo ejecutas, las variables mueren con el
# proceso hijo y tu terminal se queda igual que estaba.

ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.env.local"

if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    echo "Secretos cargados de .env.local"
else
    umask 077
    # Solo alfanumericos mas un especial: Azure rechaza +, / y = en las
    # contrasenas de VM, y base64 los produce.
    gen() { openssl rand -base64 24 | tr -d '+/=' | head -c 20; echo -n 'Aa1#'; }

    cat > "$ENV_FILE" <<EOF
# Generado por cargar-secretos.sh. No subir a Git.
export GDAT_PWD_ADMIN='$(gen)'
export GDAT_PWD_DSRM='$(gen)'
# Estas cuatro van con los valores del documento a proposito: svc-sql tiene que
# seguir siendo debil o el Kerberoasting no se puede crackear, y charlie.dev es
# la credencial que se planta en NovaShop.
export GDAT_PWD_NEGOCIO='N0vaSh0p#2026!'
export GDAT_PWD_CHARLIE='Dev3loper2026!'
export GDAT_PWD_SVCSQL='Summer2024!'
export GDAT_PWD_SVCBACKUP='B@ckup#Srv2026'
EOF
    chmod 600 "$ENV_FILE"
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    echo "Secretos generados en .env.local (permisos 600) y cargados."
fi

for v in ADMIN DSRM NEGOCIO CHARLIE SVCSQL SVCBACKUP; do
    eval "n=\${#GDAT_PWD_$v}"
    printf '  GDAT_PWD_%-10s %s caracteres\n' "$v" "$n"
done

# --- IP administrativa -----------------------------------------------------
# Se resuelve en cada carga en lugar de guardarse en .env.local. Una IP
# congelada supera la validacion de formato de deploy.sh y despliega un
# laboratorio al que ya no se puede entrar; resolverla aqui hace que el valor
# acompane siempre a la red desde la que se despliega.
#
# Para una IP fija, o una salida distinta a la de esta maquina, definir
# GDAT_IP_ADMIN_FIJA en .env.local y este bloque la respeta.

if [[ -n "${GDAT_IP_ADMIN_FIJA:-}" ]]; then
    export GDAT_IP_ADMIN="$GDAT_IP_ADMIN_FIJA"
    printf '  GDAT_IP_ADMIN    %s (fijada en .env.local)\n' "$GDAT_IP_ADMIN"
else
    _ip=$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)
    if [[ "$_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        export GDAT_IP_ADMIN="$_ip/32"
        printf '  GDAT_IP_ADMIN    %s\n' "$GDAT_IP_ADMIN"
    else
        printf '  GDAT_IP_ADMIN    sin resolver. Definela a mano antes de desplegar:\n'
        printf '                   export GDAT_IP_ADMIN="$(curl -fsS https://api.ipify.org)/32"\n'
    fi
    unset _ip
fi
