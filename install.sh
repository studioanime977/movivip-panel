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
SUB_PORT="2096"
UPSTREAM_REPO="MHSanaei/3x-ui"
REPO_RAW="https://raw.githubusercontent.com/wilderr19/willzap/main"
MIN_VERSION="2.3.5"

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
  --port <N>       Puerto del panel (default: aleatorio 1024-62000)
  --no-firewall    No configurar firewall
  --silent         No imprimir en pantalla (solo log)
  --version <v>    Instalar versión específica (ej. v2.4.0)
  -h, --help       Esta ayuda

Ejemplos:
  bash install.sh
  bash install.sh --port 8443
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
        wget --inet4-only -q -O /usr/bin/movivip-temp "${REPO_RAW}/x-ui.sh"
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

    if [[ ${#existing_webBasePath} -lt 4 ]]; then
        if [[ "$hasDefaultCredential" == "true" ]]; then
            local config_webBasePath config_username config_password config_port
            config_webBasePath=$(gen_random_string 18)
            config_username=$(gen_random_string 10)
            config_password=$(gen_random_string 10)

            if [[ -n "$CUSTOM_PORT" ]]; then
                config_port="$CUSTOM_PORT"
                log "Puerto personalizado: ${config_port}"
            else
                config_port=$(shuf -i 1024-62000 -n 1)
                log "Puerto aleatorio generado: ${config_port}"
            fi

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
            echo -e "  ${yellow}Puerto:${plain}     ${config_port}"
            echo -e "  ${yellow}BasePath:${plain}   ${config_webBasePath}"
            echo -e "  ${yellow}URL:${plain}        http://${server_ip}:${config_port}/${config_webBasePath}"
            echo -e "${green}###############################################${plain}"
            echo ""
            log "Credenciales generadas (también en $INSTALL_LOG)."
        else
            local config_webBasePath
            config_webBasePath=$(gen_random_string 18)
            "$PANEL_DIR/x-ui" setting -webBasePath "$config_webBasePath"
            log "${yellow}webBasePath faltante — regenerado: ${config_webBasePath}${plain}"
            log "URL: http://${server_ip}:${existing_port}/${config_webBasePath}"
        fi
    else
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

# ------------------------------ Firewall -------------------------------------
open_firewall_ports() {
    if [[ $NO_FIREWALL -eq 1 ]]; then
        log "${yellow}Firewall omitido (--no-firewall).${plain}"
        return
    fi

    local panel_port
    panel_port=$("$PANEL_DIR/x-ui" setting -show true 2>/dev/null | grep -Eo 'port: .+' | awk '{print $2}')
    [[ -z "$panel_port" ]] && panel_port="2053"

    log "${yellow}Configurando firewall (puertos 22, 80, 443, ${panel_port}, ${SUB_PORT})...${plain}"

    # firewalld
    if command -v firewall-cmd >/dev/null 2>&1; then
        for p in 22 80 443 "$panel_port" "$SUB_PORT"; do
            firewall-cmd --zone=public --add-port=${p}/tcp --permanent >/dev/null 2>&1
        done
        firewall-cmd --reload >/dev/null 2>&1
        log "${green}✓ firewalld configurado.${plain}"
    fi

    # ufw
    if command -v ufw >/dev/null 2>&1; then
        ufw allow 22/tcp >/dev/null 2>&1
        ufw allow 80/tcp >/dev/null 2>&1
        ufw allow 443/tcp >/dev/null 2>&1
        ufw allow "${panel_port}/tcp" >/dev/null 2>&1
        ufw allow "${SUB_PORT}/tcp" >/dev/null 2>&1
        log "${green}✓ ufw configurado.${plain}"
    fi

    # iptables
    if command -v iptables >/dev/null 2>&1; then
        for p in 22 80 443 "$panel_port" "$SUB_PORT"; do
            iptables -C INPUT -p tcp --dport "$p" -j ACCEPT >/dev/null 2>&1 \
                || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT >/dev/null 2>&1
        done
        command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1
        log "${green}✓ iptables configurado.${plain}"
    fi

    # ip6tables
    if command -v ip6tables >/dev/null 2>&1; then
        for p in 22 80 443 "$panel_port" "$SUB_PORT"; do
            ip6tables -C INPUT -p tcp --dport "$p" -j ACCEPT >/dev/null 2>&1 \
                || ip6tables -I INPUT -p tcp --dport "$p" -j ACCEPT >/dev/null 2>&1
        done
    fi

    log "${yellow}Nota:${plain} en Oracle Cloud / AWS / GCP / Azure recuerda abrir ${panel_port}/tcp en las Ingress Rules."
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
