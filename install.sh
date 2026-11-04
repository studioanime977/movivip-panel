#!/bin/bash
#===============================================================================
#  MOVIVIP PANEL — Instalador
#  Basado en ingeniería inversa de wilderr19/willzap (fork de MHSanaei/3x-ui)
#  Instala el panel 3x-ui bajo branding MOVIVIP:
#    - Ruta:      /usr/local/movivip
#    - Servicio:  movivip (systemd / openrc)
#    - CLI:       /usr/bin/movivip
#===============================================================================

set -o pipefail

# ------------------------------ Branding / colores ---------------------------
red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
cyan='\033[0;36m'
plain='\033[0m'

PANEL_NAME="MOVIVIP"
PANEL_DIR="/usr/local/movivip"
CLI_BIN="/usr/bin/movivip"
SERVICE_NAME="movivip"
INSTALL_LOG="/var/log/movivip-install.log"
UPSTREAM_REPO="MHSanaei/3x-ui"
REPO_RAW="https://raw.githubusercontent.com/studioanime977/movivip-panel/main"
MIN_VERSION="2.3.5"

# ── Esquema de puertos MOVIVIP PRODUCION (ssl.sh / HAProxy multipuerto) ──────
# Estos puertos NO se tocan jamás. El panel solo usa 54322 (interno) / 54323 (HAProxy).
PANEL_PORT_INTERNAL=54322   # panel 3x-ui HTTP — SOLO 127.0.0.1
PANEL_PORT_HAPROXY=54323    # panel HTTPS externo — frontend HAProxy
HAPROXY_CFG="/etc/haproxy/haproxy.cfg"

# Puertos reservados por ssl.sh / xray / v2ray / xhttp / bhttp / ssh-ws
RESERVED_PORTS=(
    80 443 8080 8443          # HAProxy frontends públicos
    54322 54323               # panel interno / panel HTTPS
    2001 2002 2004 8880       # XHTTP/BHTTP locales
    8765                      # ACME webroot
    10002 10003 10004         # xray payload vmess/vless/trojan
    10012 10013 10014         # xray gRPC
    10015                     # ssh-ws internal / www backend
)

is_reserved_port() {
    local p="$1" r
    for r in "${RESERVED_PORTS[@]}"; do
        [[ "$r" == "$p" ]] && return 0
    done
    return 1
}

haproxy_mode() {
    [[ -f "$HAPROXY_CFG" ]]
}

# ------------------------------ Flags ----------------------------------------
SILENT=0
NO_FIREWALL=0
CUSTOM_PORT=""
TAG_VERSION=""

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo -e "$msg" >>"$INSTALL_LOG" 2>/dev/null
    [[ $SILENT -eq 0 ]] && echo -e "$msg"
}

usage() {
    cat <<EOF
${green}MOVIVIP PANEL installer${plain}

Uso: bash install.sh [opciones] [version_tag]

Opciones:
  --port <N>       Puerto interno del panel (default: 54322)
                   Rechaza puertos reservados por ssl.sh/HAProxy/xray
  --no-firewall    No configurar firewall
  --silent         No imprimir en pantalla (solo log)
  --version <v>    Instalar versión específica (ej. v2.4.0)
  -h, --help       Esta ayuda

Puertos RESERVADOS (no usables por el panel):
  80 443 8080 8443 54323 | 2001 2002 2004 8880 | 8765
  10002-10004 10012-10015  (xray/v2ray/ssh-ws backends)

Ejemplos:
  bash install.sh
  bash install.sh --port 54322
  bash install.sh --version v2.4.0 --no-firewall
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)
            CUSTOM_PORT="$2"; shift 2 ;;
        --no-firewall)
            NO_FIREWALL=1; shift ;;
        --silent)
            SILENT=1; shift ;;
        --version)
            TAG_VERSION="$2"; shift 2 ;;
        -h|--help)
            usage ;;
        v*)
            TAG_VERSION="$1"; shift ;;
        *)
            echo -e "${red}Opción desconocida: $1${plain}"; usage ;;
    esac
done

# Validar puerto personalizado contra lista de reservados
if [[ -n "$CUSTOM_PORT" ]]; then
    if is_reserved_port "$CUSTOM_PORT"; then
        echo -e "${red}ERROR: el puerto ${CUSTOM_PORT} está RESERVADO por ssl.sh/HAProxy/xray.${plain}"
        echo -e "${yellow}Puertos reservados:${plain} ${RESERVED_PORTS[*]}"
        exit 1
    fi
    if [[ "$CUSTOM_PORT" -lt 1 || "$CUSTOM_PORT" -gt 65535 ]]; then
        echo -e "${red}ERROR: puerto inválido: ${CUSTOM_PORT}${plain}"
        exit 1
    fi
fi

# Modo HAProxy: forzar puerto interno fijo (nunca aleatorio)
if haproxy_mode && [[ -z "$CUSTOM_PORT" ]]; then
    CUSTOM_PORT="$PANEL_PORT_INTERNAL"
fi

# ------------------------------ Utilidades -----------------------------------
gen_random_string() {
    LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w "$1" | head -n 1
}

detect_public_ip() {
    local urls=(
        "https://api4.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://v4.api.ipinfo.io/ip"
        "https://ipv4.myexternalip.com/raw"
        "https://4.ident.me"
        "https://check-host.net/ip"
    )
    local ip=""
    for u in "${urls[@]}"; do
        ip=$(curl -s --max-time 3 "$u" 2>/dev/null | tr -d '[:space:]')
        [[ -n "$ip" ]] && break
    done
    echo "$ip"
}

arch() {
    case "$(uname -m)" in
        x86_64|x64|amd64)        echo 'amd64' ;;
        i*86|x86)                echo '386' ;;
        armv8*|armv8|arm64|aarch64) echo 'arm64' ;;
        armv7*|armv7|arm)        echo 'armv7' ;;
        armv6*|armv6)            echo 'armv6' ;;
        armv5*|armv5)            echo 'armv5' ;;
        s390x)                   echo 's390x' ;;
        *)
            echo -e "${red}Arquitectura no soportada${plain}" >&2
            exit 1 ;;
    esac
}

# ------------------------------ Checks iniciales -----------------------------
[[ $EUID -ne 0 ]] && echo -e "${red}Error: ejecuta este script como root.${plain}" && exit 1

if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    echo "No se pudo detectar el SO." >&2
    exit 1
fi

touch "$INSTALL_LOG" 2>/dev/null || INSTALL_LOG="/tmp/movivip-install.log"

log "${cyan}============================================${plain}"
log "${cyan}  ${PANEL_NAME} PANEL — Instalador v1.0.0${plain}"
log "${cyan}============================================${plain}"
log "SO: ${release} | Arch: $(arch) | Log: ${INSTALL_LOG}"

# ------------------------------ Paquetes base --------------------------------
install_base() {
    log "${yellow}Instalando dependencias base...${plain}"
    case "${release}" in
        ubuntu|debian|armbian)
            apt-get update -qq && apt-get install -y -qq wget curl tar tzdata ca-certificates ;;
        centos|rhel|almalinux|rocky|ol)
            yum -y install -q wget curl tar tzdata ca-certificates ;;
        fedora|amzn|virtuozzo)
            dnf -y install -q wget curl tar tzdata ca-certificates ;;
        arch|manjaro|parch)
            pacman -Sy --noconfirm --quiet wget curl tar tzdata ca-certificates ;;
        opensuse-tumbleweed|opensuse-leap)
            zypper -q refresh && zypper -q install -y wget curl tar timezone ca-certificates ;;
        alpine)
            apk add --quiet wget curl tar tzdata ca-certificates ;;
        *)
            apt-get update -qq && apt-get install -y -qq wget curl tar tzdata ca-certificates ;;
    esac
    if [[ $? -ne 0 ]]; then
        log "${red}Error instalando dependencias base.${plain}"
        exit 1
    fi
    log "${green}OK dependencias.${plain}"
}

# ------------------------------ Descarga release -----------------------------
fetch_release_tag() {
    if [[ -n "$TAG_VERSION" ]]; then
        echo "$TAG_VERSION"
        return
    fi
    local tag
    tag=$(curl -Ls "https://api.github.com/repos/${UPSTREAM_REPO}/releases/latest" \
          | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -z "$tag" ]]; then
        tag=$(curl -4 -Ls "https://api.github.com/repos/${UPSTREAM_REPO}/releases/latest" \
              | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    fi
    if [[ -z "$tag" ]]; then
        log "${red}No se pudo obtener la última versión de ${UPSTREAM_REPO}.${plain}"
        exit 1
    fi
    echo "$tag"
}

verify_sha256() {
    # Si existe archivo .sha256 junto al tarball, verificar.
    # Si no existe, solo registrar el hash en el log (modo soft-check).
    local tarball="$1"
    local sha_file="${tarball}.sha256"
    local expected actual
    actual=$(sha256sum "$tarball" | awk '{print $1}')

    if [[ -f "$sha_file" ]]; then
        expected=$(awk '{print $1}' "$sha_file")
        if [[ "$expected" != "$actual" ]]; then
            log "${red}SHA-256 NO coincide. Abortando.${plain}"
            log "esperado: $expected"
            log "obtenido: $actual"
            rm -f "$tarball" "$sha_file"
            exit 1
        fi
        log "${green}SHA-256 verificado OK.${plain}"
    else
        log "${yellow}Sin archivo .sha256 — hash registrado (soft-check): ${actual}${plain}"
    fi
}

# ------------------------------ Instalación ----------------------------------
install_panel() {
    cd /usr/local/ || exit 1

    local tag_version
    tag_version=$(fetch_release_tag)
    log "Versión target: ${tag_version}"

    # Validar versión mínima
    local tag_numeric=${tag_version#v}
    if [[ "$(printf '%s\n' "$MIN_VERSION" "$tag_numeric" | sort -V | head -n1)" != "$MIN_VERSION" ]]; then
        log "${red}Se requiere versión >= v${MIN_VERSION}. Recibido: ${tag_version}${plain}"
        exit 1
    fi

    local tarball="/usr/local/movivip-linux-$(arch).tar.gz"
    local url="https://github.com/${UPSTREAM_REPO}/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz"

    log "Descargando: $url"
    wget --inet4-only -q -N -O "$tarball" "$url"
    if [[ $? -ne 0 ]]; then
        log "${red}Descarga falló. Verifica conectividad a GitHub.${plain}"
        exit 1
    fi

    verify_sha256 "$tarball"

    # CLI (menú)
    log "Descargando CLI movivip.sh..."
    wget --inet4-only -q -O /usr/bin/movivip-temp "${REPO_RAW}/movivip.sh"
    if [[ $? -ne 0 ]]; then
        wget --inet4-only -q -O /usr/bin/movivip-temp \
            "https://raw.githubusercontent.com/${UPSTREAM_REPO}/main/x-ui.sh"
        if [[ $? -ne 0 ]]; then
            log "${red}No se pudo descargar el CLI.${plain}"
            exit 1
        fi
    fi

    # Detener servicio anterior si existe (x-ui o movivip)
    if [[ -e "$PANEL_DIR" ]]; then
        log "Deteniendo instalación anterior..."
        if [[ $release == "alpine" ]]; then
            rc-service x-ui stop 2>/dev/null
            rc-service $SERVICE_NAME stop 2>/dev/null
        else
            systemctl stop x-ui 2>/dev/null
            systemctl stop $SERVICE_NAME 2>/dev/null
        fi
        rm -rf "$PANEL_DIR"
    fi

    # Extraer
    log "Extrayendo a ${PANEL_DIR}..."
    mkdir -p "$PANEL_DIR"
    tar zxf "$tarball" -C /usr/local/ 2>/dev/null
    if [[ -d /usr/local/x-ui ]]; then
        mv /usr/local/x-ui/* "$PANEL_DIR/" 2>/dev/null
        rm -rf /usr/local/x-ui
    fi
    rm -f "$tarball"

    cd "$PANEL_DIR" || exit 1
    chmod +x x-ui 2>/dev/null
    chmod +x x-ui.sh 2>/dev/null
    [[ -f bin/xray-linux-$(arch) ]] && chmod +x "bin/xray-linux-$(arch)"

    # Normalizar nombre de binario xray para arm
    if [[ $(arch) == "armv5" || $(arch) == "armv6" || $(arch) == "armv7" ]]; then
        [[ -f "bin/xray-linux-$(arch)" ]] && mv "bin/xray-linux-$(arch)" bin/xray-linux-arm && chmod +x bin/xray-linux-arm
    fi

    # CLI definitivo
    mv -f /usr/bin/movivip-temp "$CLI_BIN"
    chmod +x "$CLI_BIN"
    [[ -f x-ui.sh ]] && cp -f x-ui.sh "$PANEL_DIR/movivip.sh" && chmod +x "$PANEL_DIR/movivip.sh"

    log "${green}Binarios instalados en ${PANEL_DIR}.${plain}"
}

# ------------------------------ Config post-instal ---------------------------
config_after_install() {
    local settings=$("$PANEL_DIR/x-ui" setting -show true 2>/dev/null)
    local hasDefaultCredential=$(echo "$settings" | grep -Eo 'hasDefaultCredential: .+' | awk '{print $2}')
    local existing_webBasePath=$(echo "$settings" | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(echo "$settings" | grep -Eo 'port: .+' | awk '{print $2}')

    local server_ip
    server_ip=$(detect_public_ip)

    # Puerto del panel: SIEMPRE el interno fijo (54322) o el custom validado.
    # NUNCA aleatorio — evita colisionar con backends de ssl.sh/HAProxy.
    local config_port="${CUSTOM_PORT:-$PANEL_PORT_INTERNAL}"

    if is_reserved_port "$config_port"; then
        log "${red}Puerto ${config_port} reservado — forzando ${PANEL_PORT_INTERNAL}.${plain}"
        config_port="$PANEL_PORT_INTERNAL"
    fi

    if [[ ${#existing_webBasePath} -lt 4 ]]; then
        if [[ "$hasDefaultCredential" == "true" ]]; then
            local config_webBasePath config_username config_password
            config_webBasePath=$(gen_random_string 18)
            config_username=$(gen_random_string 10)
            config_password=$(gen_random_string 10)

            "$PANEL_DIR/x-ui" setting \
                -username "$config_username" \
                -password "$config_password" \
                -port "$config_port" \
                -webBasePath "$config_webBasePath"

            echo ""
            echo -e "${green}###############################################${plain}"
            echo -e "${green}  ${PANEL_NAME} PANEL — Credenciales de acceso${plain}"
            echo -e "${green}###############################################${plain}"
            echo -e "  ${yellow}Usuario:${plain}    ${config_username}"
            echo -e "  ${yellow}Password:${plain}   ${config_password}"
            echo -e "  ${yellow}Puerto interno:${plain} ${config_port} (solo 127.0.0.1)"
            echo -e "  ${yellow}BasePath:${plain}   ${config_webBasePath}"
            if haproxy_mode; then
                echo -e "  ${yellow}URL externa:${plain} https://${server_ip}:${PANEL_PORT_HAPROXY}/${config_webBasePath}"
                echo -e "  ${yellow}URL interna:${plain} http://127.0.0.1:${config_port}/${config_webBasePath}"
            else
                echo -e "  ${yellow}URL:${plain}        http://${server_ip}:${config_port}/${config_webBasePath}"
            fi
            echo -e "${green}###############################################${plain}"
            echo ""
            log "Credenciales generadas (también en $INSTALL_LOG)."
        else
            local config_webBasePath
            config_webBasePath=$(gen_random_string 18)
            "$PANEL_DIR/x-ui" setting -webBasePath "$config_webBasePath" -port "$config_port"
            log "${yellow}webBasePath faltante — regenerado: ${config_webBasePath}${plain}"
            log "Puerto interno: ${config_port}"
        fi
    else
        # Asegurar puerto fijo aunque ya exista configuración
        if [[ -n "$existing_port" && "$existing_port" != "$config_port" ]]; then
            if ! is_reserved_port "$config_port"; then
                "$PANEL_DIR/x-ui" setting -port "$config_port"
                log "Puerto del panel ajustado a ${config_port} (interno)."
            fi
        fi
        if [[ "$hasDefaultCredential" == "true" ]]; then
            local config_username config_password
            config_username=$(gen_random_string 10)
            config_password=$(gen_random_string 10)
            "$PANEL_DIR/x-ui" setting -username "$config_username" -password "$config_password"
            echo -e "${yellow}Credenciales default detectadas — regeneradas.${plain}"
            echo -e "  Usuario:  ${green}${config_username}${plain}"
            echo -e "  Password: ${green}${config_password}${plain}"
        else
            log "${green}Credenciales y webBasePath correctos.${plain}"
        fi
    fi

    "$PANEL_DIR/x-ui" migrate >/dev/null 2>&1
}

# ------------------------------ HAProxy: frontend panel ----------------------
# Replica el bloque xui_frontend/xui_backend de MOVIVIP PRODUCION/protocolos/xui.sh
# bind *:54323 ssl → server 127.0.0.1:<panel_port>
setup_haproxy_panel_frontend() {
    haproxy_mode || return 0
    command -v haproxy >/dev/null 2>&1 || return 0

    local panel_port
    panel_port=$("$PANEL_DIR/x-ui" setting -show true 2>/dev/null | grep -Eo 'port: .+' | awk '{print $2}')
    [[ -z "$panel_port" ]] && panel_port="$PANEL_PORT_INTERNAL"

    local cert_dir="/etc/haproxy/certs"
    local cert_file="$cert_dir/xui-selfsigned.pem"
    local CFG="$HAPROXY_CFG"
    local ip
    ip=$(detect_public_ip)
    [[ -z "$ip" ]] && ip=$(hostname -I | awk '{print $1}')

    mkdir -p "$cert_dir"

    if [[ ! -f "$cert_file" ]]; then
        log "Generando certificado autofirmado para IP: ${ip}"
        openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -keyout "$cert_dir/key.pem" -out "$cert_dir/cert.pem" \
            -subj "/CN=$ip" -addext "subjectAltName=IP:$ip" 2>/dev/null
        cat "$cert_dir/cert.pem" "$cert_dir/key.pem" > "$cert_file"
        chmod 600 "$cert_file"
    fi

    # Limpiar bloque previo del panel (idempotente, igual que xui.sh)
    python3 - "$CFG" <<'PYEOF'
import sys, re
p = sys.argv[1]
with open(p, 'r', encoding='utf-8', errors='replace') as f:
    txt = f.read()
txt = re.sub(r'^\s*# MOVIVIP Panel config[^\n]*\ninclude /etc/haproxy/haproxy-3xui\.cfg[^\n]*\n?', '', txt, flags=re.M)
txt = re.sub(r'^\s*include /etc/haproxy/haproxy-3xui\.cfg[^\n]*\n?', '', txt, flags=re.M)
txt = re.sub(r'\n?frontend xui_frontend\n(?:    [^\n]*\n)+', '\n', txt)
txt = re.sub(r'\n?backend xui_backend\n(?:    [^\n]*\n)+', '\n', txt)
with open(p, 'w', encoding='utf-8') as f:
    f.write(txt)
PYEOF

    cat >> "$CFG" <<EOF

# MOVIVIP Panel config — HTTPS externo (por IP, cert autofirmado)
frontend xui_frontend
    mode http
    bind *:${PANEL_PORT_HAPROXY} ssl crt $cert_file
    http-request set-header X-Forwarded-Proto https
    http-request set-header X-Forwarded-For %[src]
    default_backend xui_backend

backend xui_backend
    mode http
    server xui_local 127.0.0.1:${panel_port} check inter 2000 rise 2 fall 3
EOF

    rm -f /etc/haproxy/haproxy-3xui.cfg

    if haproxy -c -f "$CFG" >/dev/null 2>&1; then
        systemctl reload haproxy 2>/dev/null || true
        log "${green}HAProxy frontend del panel configurado → https://${ip}:${PANEL_PORT_HAPROXY}${plain}"
    else
        log "${red}haproxy.cfg inválido tras añadir panel — revísalo manualmente.${plain}"
        haproxy -c -f "$CFG" 2>&1 | tail -5
    fi
}

# Restringe el puerto interno del panel: solo lo, DROP externo (como xui.sh)
restrict_panel_port_local() {
    local port="${1:-$PANEL_PORT_INTERNAL}"
    command -v iptables >/dev/null 2>&1 || return 0

    while iptables -C INPUT -i lo -p tcp --dport "$port" -j ACCEPT 2>/dev/null; do
        iptables -D INPUT -i lo -p tcp --dport "$port" -j ACCEPT 2>/dev/null || break
    done
    iptables -I INPUT 1 -i lo -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true

    if ! iptables -C INPUT -p tcp --dport "$port" -j DROP 2>/dev/null; then
        iptables -I INPUT 2 -p tcp --dport "$port" -j DROP 2>/dev/null || true
    fi

    if command -v ip6tables >/dev/null 2>&1; then
        while ip6tables -C INPUT -i lo -p tcp --dport "$port" -j ACCEPT 2>/dev/null; do
            ip6tables -D INPUT -i lo -p tcp --dport "$port" -j ACCEPT 2>/dev/null || break
        done
        ip6tables -I INPUT 1 -i lo -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
        if ! ip6tables -C INPUT -p tcp --dport "$port" -j DROP 2>/dev/null; then
            ip6tables -I INPUT 2 -p tcp --dport "$port" -j DROP 2>/dev/null || true
        fi
    fi

    mkdir -p /etc/iptables 2>/dev/null
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true

    log "${green}Puerto interno ${port} restringido a 127.0.0.1 (DROP externo).${plain}"
}

# ------------------------------ Firewall -------------------------------------
open_firewall_ports() {
    if [[ $NO_FIREWALL -eq 1 ]]; then
        log "${yellow}Firewall omitido (--no-firewall).${plain}"
        return
    fi

    local panel_port
    panel_port=$("$PANEL_DIR/x-ui" setting -show true 2>/dev/null | grep -Eo 'port: .+' | awk '{print $2}')
    [[ -z "$panel_port" ]] && panel_port="$PANEL_PORT_INTERNAL"

    if haproxy_mode; then
        # MODO HAPROXY (ssl.sh multipuerto):
        #  • NO abrir 80/443/8080/8443 — ya los maneja HAProxy
        #  • Abrir solo 54323 (HTTPS panel) si hace falta
        #  • Restringir puerto interno del panel a lo
        log "${yellow}Modo HAProxy detectado — NO se tocan 80/443/8080/8443.${plain}"
        log "Puerto interno panel: ${panel_port} (solo lo) | Externо: ${PANEL_PORT_HAPROXY}"

        restrict_panel_port_local "$panel_port"

        # Asegurar 54323 aceptado (frontend del panel)
        if command -v iptables >/dev/null 2>&1; then
            iptables -C INPUT -p tcp --dport "$PANEL_PORT_HAPROXY" -j ACCEPT >/dev/null 2>&1 \
                || iptables -I INPUT -p tcp --dport "$PANEL_PORT_HAPROXY" -j ACCEPT >/dev/null 2>&1
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
        if command -v ufw >/dev/null 2>&1; then
            ufw allow "${PANEL_PORT_HAPROXY}/tcp" >/dev/null 2>&1
        fi
        if command -v firewall-cmd >/dev/null 2>&1; then
            firewall-cmd --zone=public --add-port=${PANEL_PORT_HAPROXY}/tcp --permanent >/dev/null 2>&1
            firewall-cmd --reload >/dev/null 2>&1
        fi

        setup_haproxy_panel_frontend

        log "${green}✓ Firewall modo HAProxy: panel vía :${PANEL_PORT_HAPROXY} (HTTPS).${plain}"
        log "${yellow}Nota cloud:${plain} abre ${PANEL_PORT_HAPROXY}/tcp en Ingress Rules si usas Oracle/AWS/GCP/Azure."
        return
    fi

    # MODO SIN HAPROXY (instalación aislada)
    log "${yellow}Sin HAProxy — configurando firewall para panel :${panel_port} (+22).${plain}"

    restrict_panel_port_local "$panel_port"

    # En modo sin haproxy el panel puede ser accesible externamente si el usuario lo desea
    # pero por defecto mantenemos lo-only + aviso. Abrimos solo 22 y el puerto si es custom.
    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --zone=public --add-port=22/tcp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        log "${green}✓ firewalld: 22/tcp.${plain}"
    fi
    if command -v ufw >/dev/null 2>&1; then
        ufw allow 22/tcp >/dev/null 2>&1
        log "${green}✓ ufw: 22/tcp.${plain}"
    fi
    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p tcp --dport 22 -j ACCEPT >/dev/null 2>&1 \
            || iptables -I INPUT -p tcp --dport 22 -j ACCEPT >/dev/null 2>&1
        command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1
    fi

    log "${yellow}Nota:${plain} el panel queda en 127.0.0.1:${panel_port}."
    log "Para acceso externo instala HAProxy (ssl.sh) o libera el puerto tú mismo."
}

# ------------------------------ Servicio -------------------------------------
install_service() {
    if [[ $release == "alpine" ]]; then
        wget --inet4-only -q -O /etc/init.d/$SERVICE_NAME \
            "https://raw.githubusercontent.com/${UPSTREAM_REPO}/main/x-ui.rc"
        if [[ $? -ne 0 ]]; then
            log "${red}No se pudo descargar x-ui.rc${plain}"
            exit 1
        fi
        sed -i "s/x-ui/${SERVICE_NAME}/g" /etc/init.d/$SERVICE_NAME
        chmod +x /etc/init.d/$SERVICE_NAME
        rc-update add $SERVICE_NAME
        rc-service $SERVICE_NAME start
    else
        cat >"/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=${PANEL_NAME} Panel (3x-ui based)
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=${PANEL_DIR}
ExecStart=${PANEL_DIR}/x-ui
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable $SERVICE_NAME >/dev/null 2>&1
        systemctl restart $SERVICE_NAME
        sleep 2
        systemctl is-active --quiet $SERVICE_NAME \
            && log "${green}Servicio ${SERVICE_NAME} activo.${plain}" \
            || log "${red}Servicio ${SERVICE_NAME} NO arrancó — revisa: journalctl -u ${SERVICE_NAME}${plain}"
    fi
}

# ------------------------------ Main -----------------------------------------
main() {
    install_base
    install_panel
    config_after_install
    install_service
    open_firewall_ports

    log "${green}${PANEL_NAME} PANEL instalado correctamente.${plain}"
    cat <<EOF

${cyan}┌──────────────────────────────────────────────────────────┐${plain}
${cyan}│  ${PANEL_NAME} — Comandos CLI (subcomandos):                       │${plain}
${cyan}│                                                          │${plain}
${cyan}│  movivip${plain}              - Menú de administración        ${cyan}│${plain}
${cyan}│  movivip start${plain}        - Iniciar                       ${cyan}│${plain}
${cyan}│  movivip stop${plain}         - Detener                       ${cyan}│${plain}
${cyan}│  movivip restart${plain}      - Reiniciar                     ${cyan}│${plain}
${cyan}│  movivip status${plain}       - Estado actual                 ${cyan}│${plain}
${cyan}│  movivip settings${plain}     - Ver ajustes                   ${cyan}│${plain}
${cyan}│  movivip log${plain}          - Ver logs                      ${cyan}│${plain}
${cyan}│  movivip update${plain}       - Actualizar panel              ${cyan}│${plain}
${cyan}│  movivip uninstall${plain}    - Desinstalar                   ${cyan}│${plain}
${cyan}└──────────────────────────────────────────────────────────┘${plain}

Log de instalación: ${INSTALL_LOG}
EOF
}

main
