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
# El panel NUNCA usa estos para su web ni para inbounds (inbounds van en 11000+)
RESERVED_PORTS=(
    80 443 8080 8443          # HAProxy frontends públicos
    54322 54323               # panel interno / panel HTTPS
    2001 2002 2004 8880       # XHTTP/BHTTP locales
    8765                      # ACME webroot
    10002 10003 10004         # XRAY MANAGER vmess/vless/trojan (NO tocar)
    10012 10013 10014         # XRAY MANAGER gRPC (NO tocar)
    10015                     # ssh-ws internal / www backend
    10022 10023 10024         # V2Ray vmess/vless/trojan (NO tocar)
    10032 10033 10034         # V2Ray gRPC (NO tocar)
)

# Puertos PROPIOS del panel para inbounds (separados de xray/v2ray)
PANEL_INBOUND_PORTS=(11002 11003 11004 11012 11013 11014)

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
    return 0
}

copy_install_source() {
    local relative_path="$1" destination="$2"
    if [[ -n "${MOVIVIP_SOURCE_DIR:-}" ]]; then
        local source_path="${MOVIVIP_SOURCE_DIR%/}/${relative_path}"
        if [[ ! -s "$source_path" ]]; then
            log "${red}No existe el archivo local requerido: ${source_path}${plain}"
            return 1
        fi
        cp "$source_path" "$destination"
    else
        wget --inet4-only -q -O "$destination" "${REPO_RAW}/${relative_path}"
    fi
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
  10002-10004 10012-10015  (XRAY MANAGER)
  10022-10024 10032-10034  (V2RAY)
  El panel usa inbounds en 11002-11004 / 11012-11014 (paths /mx-*)

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
            apt-get update -qq && apt-get install -y -qq wget curl tar tzdata ca-certificates python3 openssl ;;
        centos|rhel|almalinux|rocky|ol)
            yum -y install -q wget curl tar tzdata ca-certificates python3 openssl ;;
        fedora|amzn|virtuozzo)
            dnf -y install -q wget curl tar tzdata ca-certificates python3 openssl ;;
        arch|manjaro|parch)
            pacman -Sy --noconfirm --quiet wget curl tar tzdata ca-certificates python openssl ;;
        opensuse-tumbleweed|opensuse-leap)
            zypper -q refresh && zypper -q install -y wget curl tar timezone ca-certificates python3 openssl ;;
        alpine)
            apk add --quiet wget curl tar tzdata ca-certificates python3 openssl ;;
        *)
            apt-get update -qq && apt-get install -y -qq wget curl tar tzdata ca-certificates python3 openssl ;;
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

    # CLI del repositorio MOVIVIP-PANEL
    log "Descargando CLI movivip.sh..."
    if ! copy_install_source "movivip.sh" /usr/bin/movivip-temp; then
        rm -f /usr/bin/movivip-temp
        log "${red}No se pudo descargar el CLI MOVIVIP-PANEL.${plain}"
        exit 1
    fi

    # Detener versiones anteriores antes de reemplazar sus binarios.
    log "Deteniendo servicios anteriores del panel..."
    if [[ $release == "alpine" ]]; then
        rc-service x-ui stop 2>/dev/null || true
        rc-service "$SERVICE_NAME" stop 2>/dev/null || true
        rc-update del x-ui 2>/dev/null || true
        rm -f /etc/init.d/x-ui
    else
        systemctl stop x-ui 2>/dev/null || true
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true
        systemctl disable x-ui 2>/dev/null || true
        rm -f /etc/systemd/system/x-ui.service
        systemctl daemon-reload || {
            log "${red}No se pudo recargar systemd tras migrar el servicio x-ui.${plain}"
            return 1
        }
    fi
    if [[ -e "$PANEL_DIR" ]]; then
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

    mkdir -p "$PANEL_DIR/lib" "$PANEL_DIR/presets"
    local routes_helper="$PANEL_DIR/lib/haproxy_panel_routes.py.tmp"
    if ! copy_install_source "lib/haproxy_panel_routes.py" "$routes_helper" \
       || [[ ! -s "$routes_helper" ]]; then
        rm -f "$routes_helper"
        log "${red}No se pudo instalar el helper de rutas HAProxy del panel.${plain}"
        exit 1
    fi
    mv -f "$routes_helper" "$PANEL_DIR/lib/haproxy_panel_routes.py"
    chmod 644 "$PANEL_DIR/lib/haproxy_panel_routes.py"

    local inbounds_helper="$PANEL_DIR/lib/haproxy_panel_inbounds.py.tmp"
    if ! copy_install_source "lib/haproxy_panel_inbounds.py" "$inbounds_helper" \
       || [[ ! -s "$inbounds_helper" ]]; then
        rm -f "$inbounds_helper"
        log "${red}No se pudo instalar el helper de sincronización de inbounds.${plain}"
        exit 1
    fi
    mv -f "$inbounds_helper" "$PANEL_DIR/lib/haproxy_panel_inbounds.py"
    chmod 644 "$PANEL_DIR/lib/haproxy_panel_inbounds.py"

    local inbound_preset="$PANEL_DIR/presets/haproxy-inbounds.json.tmp"
    if ! copy_install_source "presets/haproxy-inbounds.json" "$inbound_preset" \
       || [[ ! -s "$inbound_preset" ]]; then
        rm -f "$inbound_preset"
        log "${red}No se pudo instalar el preset de los seis inbounds.${plain}"
        exit 1
    fi
    mv -f "$inbound_preset" "$PANEL_DIR/presets/haproxy-inbounds.json"
    chmod 644 "$PANEL_DIR/presets/haproxy-inbounds.json"

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

            save_panel_credentials "$config_username" "$config_password"

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
            save_panel_credentials "$config_username" "$config_password"
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
# The panel installer owns the panel HTTPS frontend.
setup_haproxy_panel_frontend() {
    haproxy_mode || return 0
    command -v haproxy >/dev/null 2>&1 || {
        log "${red}HAProxy está configurado pero no se encontró el binario haproxy.${plain}"
        return 1
    }
    command -v openssl >/dev/null 2>&1 || {
        log "${red}Se requiere openssl para crear el certificado del panel.${plain}"
        return 1
    }
    command -v python3 >/dev/null 2>&1 || {
        log "${red}Se requiere python3 para actualizar la configuración HAProxy.${plain}"
        return 1
    }

    local panel_port backup
    panel_port=$("$PANEL_DIR/x-ui" setting -show true 2>/dev/null | grep -Eo 'port: .+' | awk '{print $2}')
    [[ -z "$panel_port" ]] && panel_port="$PANEL_PORT_INTERNAL"

    local cert_dir="${HAPROXY_CERT_DIR:-/etc/haproxy/certs}"
    local cert_file="$cert_dir/xui-selfsigned.pem"
    local CFG="$HAPROXY_CFG"
    local ip
    ip=$(detect_public_ip)
    [[ -z "$ip" ]] && ip=$(hostname -I | awk '{print $1}')
    [[ -n "$ip" ]] || {
        log "${red}No se pudo detectar la IP para el certificado del panel.${plain}"
        return 1
    }

    mkdir -p "$cert_dir"

    if [[ ! -f "$cert_file" ]]; then
        log "Generando certificado autofirmado para IP: ${ip}"
        local key_tmp="${cert_dir}/key.pem.tmp.$$"
        local cert_tmp="${cert_dir}/cert.pem.tmp.$$"
        local bundle_tmp="${cert_file}.tmp.$$"
        if ! (umask 077; openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -keyout "$key_tmp" -out "$cert_tmp" \
            -subj "/CN=$ip" -addext "subjectAltName=IP:$ip") 2>/dev/null \
            || ! cat "$cert_tmp" "$key_tmp" > "$bundle_tmp" \
            || ! chmod 600 "$bundle_tmp" \
            || ! mv -f "$key_tmp" "$cert_dir/key.pem" \
            || ! mv -f "$cert_tmp" "$cert_dir/cert.pem" \
            || ! mv -f "$bundle_tmp" "$cert_file"; then
            rm -f "$key_tmp" "$cert_tmp" "$bundle_tmp"
            log "${red}No se pudo crear el certificado autofirmado del panel.${plain}"
            return 1
        fi
    fi

    backup=$(mktemp "${CFG}.panel-frontend-backup.XXXXXX") || {
        log "${red}No se pudo respaldar la configuración HAProxy.${plain}"
        return 1
    }
    if ! cp -p "$CFG" "$backup"; then
        rm -f "$backup"
        log "${red}No se pudo respaldar la configuración HAProxy.${plain}"
        return 1
    fi

    # Eliminar el bloque administrado anterior y las variantes xui heredadas.
    if ! python3 - "$CFG" <<'PYEOF'
import os
import sys, re
import tempfile
import stat

p = sys.argv[1]
with open(p, 'r', encoding='utf-8', errors='replace') as f:
    txt = f.read()
txt = re.sub(
    r'(?ms)^# BEGIN MOVIVIP-PANEL FRONTEND\n.*?^# END MOVIVIP-PANEL FRONTEND\n?',
    '', txt
)
txt = re.sub(r'(?m)^[ \t]*# (?:3x-ui|MOVIVIP Panel) config[^\n]*\n?', '', txt)
txt = re.sub(r'(?m)^[ \t]*include /etc/haproxy/haproxy-3xui\.cfg[^\n]*\n?', '', txt)
txt = re.sub(r'(?ms)^frontend xui_frontend[ \t]*\n.*?(?=^(?:global|defaults|frontend|backend|listen)\b|\Z)', '', txt)
txt = re.sub(r'(?ms)^backend xui_backend[ \t]*\n.*?(?=^(?:global|defaults|frontend|backend|listen)\b|\Z)', '', txt)
directory = os.path.dirname(os.path.abspath(p))
mode = stat.S_IMODE(os.stat(p).st_mode)
fd, temp = tempfile.mkstemp(prefix='.haproxy-panel-frontend-', dir=directory)
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        f.write(txt.rstrip() + '\n')
    os.chmod(temp, mode)
    os.replace(temp, p)
except Exception:
    try:
        os.unlink(temp)
    except FileNotFoundError:
        pass
    raise
PYEOF
    then
        if ! cp -p "$backup" "$CFG"; then
            log "${red}No se pudo restaurar haproxy.cfg; respaldo disponible en ${backup}.${plain}"
            return 1
        fi
        rm -f "$backup"
        return 1
    fi

    cat >> "$CFG" <<EOF

# BEGIN MOVIVIP-PANEL FRONTEND
# Panel MOVIVIP — HTTPS externo por IP con certificado autofirmado
frontend xui_frontend
    mode http
    bind *:${PANEL_PORT_HAPROXY} ssl crt $cert_file
    http-request set-header X-Forwarded-Proto https
    http-request set-header X-Forwarded-For %[src]
    default_backend xui_backend

backend xui_backend
    mode http
    server xui_local 127.0.0.1:${panel_port} check inter 2000 rise 2 fall 3
# END MOVIVIP-PANEL FRONTEND
EOF

    rm -f /etc/haproxy/haproxy-3xui.cfg

    if ! haproxy -c -f "$CFG" >/dev/null 2>&1; then
        if ! cp -p "$backup" "$CFG"; then
            log "${red}haproxy.cfg es inválido; respaldo disponible en ${backup}.${plain}"
            return 1
        fi
        rm -f "$backup"
        log "${red}haproxy.cfg inválido tras añadir el panel; se restauró la configuración anterior.${plain}"
        haproxy -c -f "$CFG" 2>&1 | tail -5
        return 1
    fi

    if ! systemctl reload haproxy 2>/dev/null && ! systemctl restart haproxy 2>/dev/null; then
        if ! cp -p "$backup" "$CFG"; then
            log "${red}Falló la recarga; respaldo disponible en ${backup}.${plain}"
            return 1
        fi
        rm -f "$backup"
        log "${red}HAProxy no pudo recargar la configuración del panel; se restauró el archivo anterior.${plain}"
        return 1
    fi
    rm -f "$backup"
    log "${green}HAProxy frontend del panel configurado → https://${ip}:${PANEL_PORT_HAPROXY}${plain}"
}

# Restringe el puerto interno del panel: solo lo, DROP externo.
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
        if haproxy_mode; then
            setup_haproxy_panel_frontend || return 1
        fi
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

        setup_haproxy_panel_frontend || return 1

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
        rc-service $SERVICE_NAME start || {
            log "${red}No se pudo iniciar el servicio ${SERVICE_NAME}.${plain}"
            return 1
        }
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
        systemctl daemon-reload || return 1
        systemctl enable $SERVICE_NAME >/dev/null 2>&1 || {
            log "${red}No se pudo habilitar el servicio ${SERVICE_NAME}.${plain}"
            return 1
        }
        systemctl restart $SERVICE_NAME || {
            log "${red}No se pudo iniciar el servicio ${SERVICE_NAME}.${plain}"
            return 1
        }
        sleep 2
        if ! systemctl is-active --quiet $SERVICE_NAME; then
            log "${red}Servicio ${SERVICE_NAME} NO arrancó — revisa: journalctl -u ${SERVICE_NAME}${plain}"
            return 1
        fi
        log "${green}Servicio ${SERVICE_NAME} activo.${plain}"
    fi
}

# ------------------------------ Credenciales (para API) ----------------------
save_panel_credentials() {
    local user="$1" pass="$2"
    local dir="/etc/movivip"
    local cred="$dir/xui-credentials"
    mkdir -p "$dir"
    umask 077
    printf 'username=%s\npassword=%s\n' "$user" "$pass" > "$cred"
    chmod 600 "$cred"
    log "${green}Credenciales API guardadas en ${cred}${plain}"
}

# ------------------------------ Sync inbounds HAProxy ------------------------
# Crea inbounds PROPIOS del panel en 11002+ (paths /mx-*) — NO toca puertos
# del Xray manager (10002-10004) ni V2Ray (10022-10024).
PRESETS_URL="${REPO_RAW}/presets/haproxy-inbounds.json"

# Puertos prohibidos para inbounds del panel (otros servicios)
PANEL_FORBIDDEN_PORTS=(80 443 8080 8443 54322 54323 \
    10002 10003 10004 10012 10013 10014 10015 \
    10022 10023 10024 10032 10033 10034)

inject_haproxy_panel_routes() {
    command -v python3 >/dev/null 2>&1 || { log "${yellow}python3 requerido para rutas HAProxy.${plain}"; return 1; }
    local cfg="$HAPROXY_CFG"
    local helper="$PANEL_DIR/lib/haproxy_panel_routes.py"
    local backup result
    [[ -f "$cfg" ]] || { log "${red}No existe $cfg${plain}"; return 1; }
    [[ -s "$helper" ]] || { log "${red}No existe el helper de rutas: $helper${plain}"; return 1; }

    backup=$(mktemp "${cfg}.panel-backup.XXXXXX") || { log "${red}No se pudo crear respaldo de HAProxy.${plain}"; return 1; }
    if ! cp -p "$cfg" "$backup"; then
        rm -f "$backup"
        log "${red}No se pudo respaldar $cfg.${plain}"
        return 1
    fi
    if ! result=$(python3 "$helper" "$cfg"); then
        if ! cp -p "$backup" "$cfg"; then
            log "${red}Falló la inyección; respaldo disponible en ${backup}.${plain}"
            return 1
        fi
        rm -f "$backup"
        log "${red}No se pudieron inyectar las rutas del panel.${plain}"
        return 1
    fi
    if ! haproxy -c -f "$cfg" >/dev/null 2>&1; then
        if ! cp -p "$backup" "$cfg"; then
            log "${red}haproxy -c falló; respaldo disponible en ${backup}.${plain}"
            return 1
        fi
        rm -f "$backup"
        log "${red}haproxy -c falló; se restauró la configuración anterior.${plain}"
        haproxy -c -f "$cfg" 2>&1 | tail -5
        return 1
    fi

    if [[ "$result" == *MOVIVIP_PANEL_ROUTES_UPDATED* ]]; then
        if ! systemctl reload haproxy 2>/dev/null && ! systemctl restart haproxy 2>/dev/null; then
            if ! cp -p "$backup" "$cfg"; then
                log "${red}Falló la recarga; respaldo disponible en ${backup}.${plain}"
                return 1
            fi
            rm -f "$backup"
            log "${red}No se pudo recargar ni reiniciar HAProxy.${plain}"
            return 1
        fi
        log "${green}Rutas del panel instaladas y HAProxy recargado.${plain}"
    else
        log "${green}Rutas del panel ya listas; HAProxy no necesitó cambios.${plain}"
    fi
    rm -f "$backup"
}

sync_haproxy_inbounds() {
    command -v python3 >/dev/null 2>&1 || { log "${red}python3 es obligatorio para crear los seis inbounds del panel.${plain}"; return 1; }

    local cred="/etc/movivip/xui-credentials"
    [[ -f "$cred" ]] || { log "${red}No hay credenciales para sincronizar los seis inbounds del panel.${plain}"; return 1; }

    local panel_settings panel_port panel_base_path
    panel_settings=$("$PANEL_DIR/x-ui" setting -show true 2>/dev/null)
    panel_port=$(echo "$panel_settings" | grep -Eo 'port: .+' | awk '{print $2}')
    [[ -z "$panel_port" ]] && panel_port="$PANEL_PORT_INTERNAL"
    panel_base_path=$(echo "$panel_settings" | grep -Eo 'webBasePath: .+' | awk '{print $2}')

    local presets="/tmp/movivip-haproxy-inbounds.json"
    log "Descargando presets (paths /mx-*, puertos 11002+)..."
    if [[ -s "$PANEL_DIR/presets/haproxy-inbounds.json" ]]; then
        cp "$PANEL_DIR/presets/haproxy-inbounds.json" "$presets"
    elif [[ -n "${MOVIVIP_SOURCE_DIR:-}" ]]; then
        copy_install_source "presets/haproxy-inbounds.json" "$presets" || return 1
    else
        wget --inet4-only -q -O "$presets" "$PRESETS_URL"
    fi
    if [[ ! -s "$presets" ]]; then
        log "${red}No se pudieron descargar los presets de los seis inbounds.${plain}"
        return 1
    fi

    # Lista de prohibidos como args
    local forbidden_csv
    forbidden_csv=$(IFS=,; echo "${PANEL_FORBIDDEN_PORTS[*]}")

    log "Creando/verificando los seis inbounds del panel → 11002-11004 / 11012-11014..."
    local inbounds_helper="$PANEL_DIR/lib/haproxy_panel_inbounds.py"
    [[ -s "$inbounds_helper" ]] || {
        log "${red}No existe el helper de sincronización: $inbounds_helper${plain}"
        rm -f "$presets"
        return 1
    }
    python3 "$inbounds_helper" "$panel_port" "$cred" "$presets" "$forbidden_csv" "$panel_base_path"

    local rc=$?
    if [[ $rc -ne 0 ]]; then
        rm -f "$presets"
        log "${red}Sync de inbounds falló (rc=$rc).${plain}"
        return 1
    fi

    log "${green}Seis inbounds del panel creados/verificados y visibles en 3X-UI.${plain}"

    if haproxy_mode; then
        inject_haproxy_panel_routes || { rm -f "$presets"; return 1; }
    else
        log "${yellow}HAProxy no está instalado: los seis inbounds quedan creados, pero sin rutas públicas.${plain}"
    fi
    rm -f "$presets"

    if [[ $release == "alpine" ]]; then
        rc-service $SERVICE_NAME restart >/dev/null 2>&1
    else
        systemctl restart $SERVICE_NAME >/dev/null 2>&1
    fi
    sleep 2
}

# ------------------------------ Main -----------------------------------------
main() {
    install_base || {
        log "${red}Falló la instalación de dependencias; panel no instalado.${plain}"
        return 1
    }
    install_panel || {
        log "${red}Falló la descarga o instalación del panel.${plain}"
        return 1
    }
    config_after_install || {
        log "${red}Falló la configuración inicial del panel.${plain}"
        return 1
    }
    install_service || {
        log "${red}Falló la instalación o el inicio del servicio.${plain}"
        return 1
    }
    open_firewall_ports || {
        log "${red}Falló la configuración de acceso/firewall del panel.${plain}"
        return 1
    }
    sync_haproxy_inbounds || {
        log "${red}Falló la sincronización de rutas/inbounds HAProxy.${plain}"
        return 1
    }

    log "${green}${PANEL_NAME} PANEL instalado correctamente.${plain}"
    if haproxy_mode; then
        cat <<EOF

${cyan}Modo HAProxy activo:${plain}
  • Panel interno:  127.0.0.1:${PANEL_PORT_INTERNAL}
  • Panel externo:  https://<IP>:${PANEL_PORT_HAPROXY}
  • Inbounds panel: 127.0.0.1:11002-11004 (ws) / 11012-11014 (grpc)
  • WS HTTP:        :80 / :8080
  • WS TLS:         :443 / :8443
  • gRPC TLS/H2:    :443 / :8443
  • Inbounds:       los crea este instalador en loopback y los asocia HAProxy

  Rutas HAProxy → backend:
    /mx-vmess       → 127.0.0.1:11002
    /mx-vless       → 127.0.0.1:11003
    /mx-trojan-ws   → 127.0.0.1:11004
    /mx-vmess-grpc  → 127.0.0.1:11012
    /mx-vless-grpc  → 127.0.0.1:11013
    /mx-trojan-grpc → 127.0.0.1:11014
EOF
    fi
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
${cyan}│  movivip haproxy-sync${plain} - Sincronizar inbounds HAProxy   ${cyan}│${plain}
${cyan}│  movivip log${plain}          - Ver logs                      ${cyan}│${plain}
${cyan}│  movivip update${plain}       - Actualizar panel              ${cyan}│${plain}
${cyan}│  movivip uninstall${plain}    - Desinstalar                   ${cyan}│${plain}
${cyan}└──────────────────────────────────────────────────────────┘${plain}

Log de instalación: ${INSTALL_LOG}
EOF
}

main "$@"
exit $?
