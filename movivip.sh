#!/bin/bash
#===============================================================================
#  MOVIVIP — CLI de administración del panel
#  Derivado de wilderr19/willzap/x-ui.sh (3x-ui) con branding MOVIVIP.
#  Se instala en /usr/bin/movivip
#===============================================================================

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
cyan='\033[0;36m'
plain='\033[0m'

PANEL_NAME="MOVIVIP"
PANEL_DIR="/usr/local/movivip"
SERVICE_NAME="movivip"
UPSTREAM_REPO="MHSanaei/3x-ui"
REPO_RAW="https://raw.githubusercontent.com/studioanime977/movivip-panel/main"

# ── Esquema puertos MOVIVIP PRODUCION (ssl.sh / HAProxy multipuerto) ─────────
PANEL_PORT_INTERNAL=54322
PANEL_PORT_HAPROXY=54323
HAPROXY_CFG="/etc/haproxy/haproxy.cfg"

RESERVED_PORTS=(
    80 443 8080 8443
    54322 54323
    2001 2002 2004 8880
    8765
    10002 10003 10004
    10012 10013 10014
    10015
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

log_folder="${XUI_LOG_FOLDER:=/var/log}"
iplimit_log_path="${log_folder}/3xipl.log"
iplimit_banned_log_path="${log_folder}/3xipl-banned.log"

LOGD() { echo -e "${yellow}[DEG] $* ${plain}"; }
LOGE() { echo -e "${red}[ERR] $* ${plain}"; }
LOGI() { echo -e "${green}[INF] $* ${plain}"; }

# ------------------------------ Checks ---------------------------------------
[[ $EUID -ne 0 ]] && LOGE "Debes ejecutar como root." && exit 1

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

os_version=$(grep "^VERSION_ID" /etc/os-release | cut -d '=' -f2 | tr -d '"' | tr -d '.')

XUI_BIN="${PANEL_DIR}/x-ui"

confirm() {
    if [[ $# -gt 1 ]]; then
        echo && read -rp "$1 [Default $2]: " temp
        [[ -z "$temp" ]] && temp=$2
    else
        read -rp "$1 [y/n]: " temp
    fi
    [[ "$temp" == "y" || "$temp" == "Y" ]]
}

confirm_restart() {
    if confirm "Reiniciar el panel? (reinicia xray también)" "y"; then
        restart
    else
        show_menu
    fi
}

before_show_menu() {
    echo && echo -n -e "${yellow}Presiona Enter para volver al menú: ${plain}" && read -r temp
    show_menu
}

gen_random_string() {
    LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w "$1" | head -n 1
}

# ------------------------------ Estado ---------------------------------------
# 0: corriendo, 1: detenido, 2: no instalado
check_status() {
    if [[ $release == "alpine" ]]; then
        [[ ! -f /etc/init.d/$SERVICE_NAME ]] && return 2
        if [[ $(rc-service $SERVICE_NAME status 2>/dev/null | grep -F 'status: started' -c) == 1 ]]; then
            return 0
        else
            return 1
        fi
    else
        [[ ! -f /etc/systemd/system/${SERVICE_NAME}.service ]] && return 2
        local temp
        temp=$(systemctl status $SERVICE_NAME 2>/dev/null | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
        [[ "$temp" == "running" ]] && return 0 || return 1
    fi
}

check_enabled() {
    if [[ $release == "alpine" ]]; then
        [[ $(rc-update show 2>/dev/null | grep -F "$SERVICE_NAME" | grep default -c) == 1 ]] && return 0 || return 1
    else
        [[ $(systemctl is-enabled $SERVICE_NAME 2>/dev/null) == "enabled" ]] && return 0 || return 1
    fi
}

check_install() {
    check_status
    if [[ $? == 2 ]]; then
        echo ""
        LOGE "El panel no está instalado. Ejecuta install.sh primero."
        [[ $# -eq 0 ]] && before_show_menu
        return 1
    fi
    return 0
}

check_uninstall() {
    check_status
    if [[ $? != 2 ]]; then
        echo ""
        LOGE "El panel ya está instalado."
        [[ $# -eq 0 ]] && before_show_menu
        return 1
    fi
    return 0
}

show_status() {
    check_status
    case $? in
        0) echo -e "Estado del panel: ${green}Corriendo${plain}"; show_enable_status ;;
        1) echo -e "Estado del panel: ${yellow}Detenido${plain}"; show_enable_status ;;
        2) echo -e "Estado del panel: ${red}No instalado${plain}" ;;
    esac
    show_xray_status
}

show_enable_status() {
    if check_enabled; then
        echo -e "Auto-arranque: ${green}Sí${plain}"
    else
        echo -e "Auto-arranque: ${red}No${plain}"
    fi
}

check_xray_status() {
    [[ $(ps -ef | grep "xray-linux" | grep -v "grep" | wc -l) -ne 0 ]]
}

show_xray_status() {
    if check_xray_status; then
        echo -e "Estado xray: ${green}Corriendo${plain}"
    else
        echo -e "Estado xray: ${red}Detenido${plain}"
    fi
}

# ------------------------------ Acciones servicio ----------------------------
start() {
    check_install && return 1
    check_status
    if [[ $? == 0 ]]; then
        LOGI "El panel ya está corriendo."
    else
        if [[ $release == "alpine" ]]; then rc-service $SERVICE_NAME start
        else systemctl start $SERVICE_NAME; fi
        sleep 2
        check_status && LOGI "${PANEL_NAME} iniciado." || LOGE "Fallo al iniciar — revisa logs."
    fi
    [[ $# -eq 0 ]] && before_show_menu
}

stop() {
    check_install && return 1
    check_status
    if [[ $? == 1 ]]; then
        LOGI "El panel ya está detenido."
    else
        if [[ $release == "alpine" ]]; then rc-service $SERVICE_NAME stop
        else systemctl stop $SERVICE_NAME; fi
        sleep 2
        check_status && LOGE "Fallo al detener." || LOGI "${PANEL_NAME} detenido."
    fi
    [[ $# -eq 0 ]] && before_show_menu
}

restart() {
    check_install && return 1
    if [[ $release == "alpine" ]]; then rc-service $SERVICE_NAME restart
    else systemctl restart $SERVICE_NAME; fi
    sleep 2
    check_status && LOGI "${PANEL_NAME} reiniciado." || LOGE "Fallo al reiniciar."
    [[ $# -eq 0 ]] && before_show_menu
}

status_cmd() {
    if [[ $release == "alpine" ]]; then rc-service $SERVICE_NAME status
    else systemctl status $SERVICE_NAME -l; fi
    [[ $# -eq 0 ]] && before_show_menu
}

enable_cmd() {
    check_install && return 1
    if [[ $release == "alpine" ]]; then rc-update add $SERVICE_NAME
    else systemctl enable $SERVICE_NAME; fi
    [[ $? -eq 0 ]] && LOGI "Auto-arranque activado." || LOGE "Fallo al activar auto-arranque."
    [[ $# -eq 0 ]] && before_show_menu
}

disable_cmd() {
    check_install && return 1
    if [[ $release == "alpine" ]]; then rc-update del $SERVICE_NAME
    else systemctl disable $SERVICE_NAME; fi
    [[ $? -eq 0 ]] && LOGI "Auto-arranque desactivado." || LOGE "Fallo al desactivar."
    [[ $# -eq 0 ]] && before_show_menu
}

# ------------------------------ Ajustes --------------------------------------
check_config() {
    local info
    info=$($XUI_BIN setting -show true)
    [[ $? -ne 0 ]] && LOGE "Error leyendo ajustes." && show_menu && return

    LOGI "$info"

    local existing_webBasePath existing_port existing_cert server_ip
    existing_webBasePath=$(echo "$info" | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    existing_port=$(echo "$info" | grep -Eo 'port: .+' | awk '{print $2}')
    existing_cert=$($XUI_BIN setting -getCert true 2>/dev/null | grep -Eo 'cert: .+' | awk '{print $2}')
    server_ip=$(curl -s --max-time 3 https://api.ipify.org)
    [[ -z "$server_ip" ]] && server_ip=$(curl -s --max-time 3 https://4.ident.me)

    echo -e "${yellow}Puerto interno:${plain} ${existing_port:-$PANEL_PORT_INTERNAL} (127.0.0.1)"
    echo -e "${yellow}Puertos reservados (ssl.sh):${plain} ${RESERVED_PORTS[*]}"

    if haproxy_mode; then
        echo -e "${green}URL externa (HAProxy):${plain} https://${server_ip}:${PANEL_PORT_HAPROXY}/${existing_webBasePath}"
        echo -e "${green}URL interna:${plain} http://127.0.0.1:${existing_port}/${existing_webBasePath}"
    elif [[ -n "$existing_cert" ]]; then
        local domain
        domain=$(basename "$(dirname "$existing_cert")")
        if [[ "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            echo -e "${green}URL de acceso: https://${domain}:${existing_port}/${existing_webBasePath}${plain}"
        else
            echo -e "${green}URL de acceso: https://${server_ip}:${existing_port}/${existing_webBasePath}${plain}"
        fi
    else
        echo -e "${green}URL de acceso: http://${server_ip}:${existing_port}/${existing_webBasePath}${plain}"
    fi
}

# Actualiza el backend xui_backend en haproxy.cfg para apuntar al nuevo puerto interno
sync_haproxy_panel_backend() {
    local port="$1"
    haproxy_mode || return 0
    command -v python3 >/dev/null 2>&1 || return 0

    python3 - "$HAPROXY_CFG" "$port" <<'PYEOF'
import sys, re
p, port = sys.argv[1], sys.argv[2]
with open(p, 'r', encoding='utf-8', errors='replace') as f:
    txt = f.read()
txt = re.sub(
    r'(backend xui_backend\n(?:    [^\n]*\n)*    server xui_local 127\.0\.0\.1:)\d+',
    r'\g<1>' + port,
    txt,
)
with open(p, 'w', encoding='utf-8') as f:
    f.write(txt)
PYEOF

    if haproxy -c -f "$HAPROXY_CFG" >/dev/null 2>&1; then
        systemctl reload haproxy 2>/dev/null || true
        LOGI "HAProxy xui_backend → 127.0.0.1:${port}"
    else
        LOGE "haproxy.cfg inválido tras cambiar backend — revísalo."
    fi
}

# Restringe puerto interno del panel: solo lo.
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
}

set_port() {
    check_install && return 1
    echo -e "${yellow}Puertos RESERVADOS (no usar):${plain} ${RESERVED_PORTS[*]}"
    read -rp "Nuevo puerto interno del panel [1-65535]: " port
    if [[ -z "$port" ]]; then
        LOGD "Cancelado"
        before_show_menu
        return
    fi
    if is_reserved_port "$port"; then
        LOGE "El puerto $port está RESERVADO por ssl.sh/HAProxy/xray. Elige otro."
        before_show_menu
        return
    fi
    if [[ ! "$port" =~ ^[0-9]+$ || "$port" -lt 1 || "$port" -gt 65535 ]]; then
        LOGE "Puerto inválido: $port"
        before_show_menu
        return
    fi

    if $XUI_BIN setting -port "$port"; then
        restrict_panel_port_local "$port"
        sync_haproxy_panel_backend "$port"
        LOGI "Puerto interno cambiado a ${port} (solo 127.0.0.1)."
        if haproxy_mode; then
            LOGI "Acceso externo: https://<IP>:${PANEL_PORT_HAPROXY}/<basePath>"
        fi
        confirm_restart
    else
        LOGE "No se pudo cambiar el puerto."
        before_show_menu
    fi
}

reset_user() {
    check_install && return 1
    confirm "Seguro que quieres resetear usuario y contraseña?" "n" || { show_menu; return; }

    read -rp "Nuevo usuario [default: aleatorio]: " config_account
    [[ -z $config_account ]] && config_account=$(gen_random_string 10)
    read -rp "Nueva contraseña [default: aleatoria]: " config_password
    [[ -z $config_password ]] && config_password=$(gen_random_string 18)

    read -rp "¿Deshabilitar 2FA actual? (y/n): " twoFactorConfirm
    if [[ "$twoFactorConfirm" != "y" && "$twoFactorConfirm" != "Y" ]]; then
        $XUI_BIN setting -username "$config_account" -password "$config_password" -resetTwoFactor false >/dev/null 2>&1
    else
        $XUI_BIN setting -username "$config_account" -password "$config_password" -resetTwoFactor true >/dev/null 2>&1
        LOGI "2FA deshabilitado."
    fi

    # Guardar para API haproxy-sync
    mkdir -p /etc/movivip
    umask 077
    printf 'username=%s\npassword=%s\n' "$config_account" "$config_password" > /etc/movivip/xui-credentials
    chmod 600 /etc/movivip/xui-credentials

    echo -e "Usuario: ${green}${config_account}${plain}"
    echo -e "Contraseña: ${green}${config_password}${plain}"
    confirm_restart
}

reset_webbasepath() {
    check_install && return 1
    confirm "Resetear web base path?" "n" || { show_menu; return; }
    local p
    p=$(gen_random_string 18)
    $XUI_BIN setting -webBasePath "$p" >/dev/null 2>&1
    LOGI "Nuevo webBasePath: ${green}${p}${plain}"
    restart
}

reset_config() {
    check_install && return 1
    confirm "Resetear TODOS los ajustes del panel? (cuentas no se pierden)" "n" || { show_menu; return; }
    $XUI_BIN setting -reset
    LOGI "Ajustes reseteados."
    restart
}

# ------------------------------ Logs -----------------------------------------
show_log() {
    check_install && return 1
    if [[ $release == "alpine" ]]; then
        echo -e "${green}\t1.${plain} Debug Log"
        echo -e "${green}\t0.${plain} Volver"
        read -rp "Opción: " choice
        case "$choice" in
            0) show_menu ;;
            1) grep -F 'x-ui[' /var/log/messages ;;
            *) LOGE "Opción inválida"; show_log ;;
        esac
    else
        echo -e "${green}\t1.${plain} Debug Log"
        echo -e "${green}\t2.${plain} Limpiar logs"
        echo -e "${green}\t0.${plain} Volver"
        read -rp "Opción: " choice
        case "$choice" in
            0) show_menu ;;
            1) journalctl -u $SERVICE_NAME -e --no-pager -f -p debug ;;
            2) journalctl --rotate && journalctl --vacuum-time=1s && LOGI "Logs limpiados." && restart ;;
            *) LOGE "Opción inválida"; show_log ;;
        esac
    fi
}

# ------------------------------ BBR ------------------------------------------
enable_bbr() {
    if grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf && grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        LOGI "BBR ya está habilitado."
        return
    fi
    case "${release}" in
        ubuntu|debian|armbian) apt-get update -qq && apt-get install -yqq --no-install-recommends ca-certificates ;;
        centos|rhel|almalinux|rocky|ol) yum -y install -q ca-certificates ;;
        fedora|amzn|virtuozzo) dnf -y install -q ca-certificates ;;
        arch|manjaro|parch) pacman -Sy --noconfirm --quiet ca-certificates ;;
        opensuse-tumbleweed|opensuse-leap) zypper -q install -y ca-certificates ;;
        alpine) apk add --quiet ca-certificates ;;
        *) LOGE "SO no soportado."; return ;;
    esac
    echo "net.core.default_qdisc=fq" >>/etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >>/etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    [[ $(sysctl -n net.ipv4.tcp_congestion_control) == "bbr" ]] \
        && LOGI "BBR habilitado." || LOGE "Fallo al habilitar BBR."
}

disable_bbr() {
    if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        LOGI "BBR no está habilitado."
        return
    fi
    sed -i 's/net.core.default_qdisc=fq/net.core.default_qdisc=pfifo_fast/' /etc/sysctl.conf
    sed -i 's/net.ipv4.tcp_congestion_control=bbr/net.ipv4.tcp_congestion_control=cubic/' /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    LOGI "BBR reemplazado por CUBIC."
}

bbr_menu() {
    echo -e "${green}\t1.${plain} Habilitar BBR"
    echo -e "${green}\t2.${plain} Deshabilitar BBR"
    echo -e "${green}\t0.${plain} Volver"
    read -rp "Opción: " choice
    case "$choice" in
        0) show_menu ;;
        1) enable_bbr; bbr_menu ;;
        2) disable_bbr; bbr_menu ;;
        *) LOGE "Opción inválida"; bbr_menu ;;
    esac
}

# ------------------------------ Geo files ------------------------------------
update_geo() {
    check_install && return 1
    cd "${PANEL_DIR}/bin" 2>/dev/null || cd "$PANEL_DIR" || return
    wget -q -O geoip.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat
    wget -q -O geosite.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
    LOGI "Geo files actualizados."
    restart
}

# ------------------------------ SSL / acme -----------------------------------
install_acme() {
    command -v ~/.acme.sh/acme.sh &>/dev/null && { LOGI "acme.sh ya instalado."; return 0; }
    LOGI "Instalando acme.sh..."
    cd ~ || return 1
    curl -s https://get.acme.sh | sh
    [[ $? -eq 0 ]] && LOGI "acme.sh instalado." || LOGE "Fallo instalación acme.sh."
}

ssl_cert_issue() {
    check_install && return 1
    local existing_webBasePath existing_port
    existing_webBasePath=$($XUI_BIN setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    existing_port=$($XUI_BIN setting -show true | grep -Eo 'port: .+' | awk '{print $2}')

    install_acme

    # socat
    case "${release}" in
        ubuntu|debian|armbian) apt-get update -qq && apt-get install -yq socat ;;
        centos|rhel|almalinux|rocky|ol) yum -y install -q socat ;;
        fedora|amzn|virtuozzo) dnf -y install -q socat ;;
        arch|manjaro|parch) pacman -Sy --noconfirm --quiet socat ;;
        opensuse-tumbleweed|opensuse-leap) zypper -q install -y socat ;;
        alpine) apk add --quiet socat ;;
    esac

    local domain="" WebPort=80
    read -rp "Dominio: " domain
    [[ -z "$domain" ]] && { LOGE "Dominio vacío."; return; }
    read -rp "Puerto HTTP para validación [80]: " WebPort
    [[ -z "$WebPort" ]] && WebPort=80

    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    ~/.acme.sh/acme.sh --issue -d "$domain" --listen-v6 --standalone --httpport "$WebPort" --force
    if [[ $? -ne 0 ]]; then
        LOGE "Fallo emisión de certificado."
        return
    fi

    local certPath="/root/cert/${domain}"
    mkdir -p "$certPath"
    local reloadCmd="${SERVICE_NAME} restart"

    ~/.acme.sh/acme.sh --installcert -d "$domain" \
        --key-file "${certPath}/privkey.pem" \
        --fullchain-file "${certPath}/fullchain.pem" \
        --reloadcmd "$reloadCmd"

    ~/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1
    chmod 755 "$certPath"/* 2>/dev/null

    confirm "Asignar este certificado al panel?" "y" && {
        if [[ -f "${certPath}/fullchain.pem" && -f "${certPath}/privkey.pem" ]]; then
            $XUI_BIN cert -webCert "${certPath}/fullchain.pem" -webCertKey "${certPath}/privkey.pem"
            LOGI "Certificado asignado al panel."
            LOGI "URL: https://${domain}:${existing_port}/${existing_webBasePath}"
            restart
        else
            LOGE "Archivos de certificado no encontrados."
        fi
    }
}

ssl_menu() {
    echo -e "${green}\t1.${plain} Obtener certificado SSL (Let's Encrypt standalone)"
    echo -e "${green}\t0.${plain} Volver"
    read -rp "Opción: " choice
    case "$choice" in
        0) show_menu ;;
        1) ssl_cert_issue; ssl_menu ;;
        *) LOGE "Opción inválida"; ssl_menu ;;
    esac
}

# ------------------------------ Firewall -------------------------------------
firewall_menu() {
    echo -e "${green}\t1.${plain} Abrir puertos (ufw)"
    echo -e "${green}\t2.${plain} Listar reglas (ufw status numbered)"
    echo -e "${green}\t3.${plain} Eliminar reglas"
    echo -e "${green}\t4.${plain} Habilitar ufw"
    echo -e "${green}\t5.${plain} Deshabilitar ufw"
    echo -e "${green}\t0.${plain} Volver"
    read -rp "Opción: " choice
    case "$choice" in
        0) show_menu ;;
        1)
            read -rp "Puertos (ej. 80,443,2053 o rango 400-500): " ports
            if ! [[ $ports =~ ^([0-9]+|[0-9]+-[0-9]+)(,([0-9]+|[0-9]+-[0-9]+))*$ ]]; then
                LOGE "Formato inválido."
            else
                IFS=',' read -ra PL <<<"$ports"
                for p in "${PL[@]}"; do
                    if [[ $p == *-* ]]; then
                        local s=${p%%-*} e=${p##*-}
                        ufw allow "${s}:${e}/tcp"; ufw allow "${s}:${e}/udp"
                    else
                        ufw allow "$p"
                    fi
                done
                LOGI "Puertos abiertos."
            fi
            firewall_menu ;;
        2) ufw status numbered; firewall_menu ;;
        3)
            ufw status numbered
            read -rp "Número de regla a eliminar: " rn
            ufw delete "$rn" && LOGI "Regla eliminada."
            firewall_menu ;;
        4) ufw --force enable; firewall_menu ;;
        5) ufw disable; firewall_menu ;;
        *) LOGE "Opción inválida"; firewall_menu ;;
    esac
}

# ------------------------------ Actualizar / desinstalar ----------------------
update() {
    confirm "Actualizar todos los componentes a la última versión? (datos no se pierden)" "y" || { show_menu; return; }
    bash <(curl -Ls "https://raw.githubusercontent.com/${UPSTREAM_REPO}/main/update.sh")
    [[ $? -eq 0 ]] && LOGI "Actualización completa." || LOGE "Fallo actualización."
    before_show_menu
}

update_shell() {
    local helper_dir="$PANEL_DIR/lib"
    local helper_tmp="$helper_dir/haproxy_panel_routes.py.tmp"
    local inbounds_helper_tmp="$helper_dir/haproxy_panel_inbounds.py.tmp"
    mkdir -p "$helper_dir" || { LOGE "No se pudo preparar $helper_dir."; before_show_menu; return; }
    if ! wget -q -O "$helper_tmp" "${REPO_RAW}/lib/haproxy_panel_routes.py" \
       || [[ ! -s "$helper_tmp" ]]; then
        rm -f "$helper_tmp"
        LOGE "Fallo descarga del helper HAProxy."
    elif ! wget -q -O "$inbounds_helper_tmp" "${REPO_RAW}/lib/haproxy_panel_inbounds.py" \
       || [[ ! -s "$inbounds_helper_tmp" ]]; then
        rm -f "$helper_tmp" "$inbounds_helper_tmp"
        LOGE "Fallo descarga del helper de sincronización de inbounds."
    elif ! mv -f "$helper_tmp" "$helper_dir/haproxy_panel_routes.py"; then
        rm -f "$helper_tmp" "$inbounds_helper_tmp"
        LOGE "No se pudo instalar el helper HAProxy."
    elif ! mv -f "$inbounds_helper_tmp" "$helper_dir/haproxy_panel_inbounds.py"; then
        rm -f "$inbounds_helper_tmp"
        LOGE "No se pudo instalar el helper de sincronización de inbounds."
    elif ! wget -q -O /usr/bin/movivip "${REPO_RAW}/movivip.sh"; then
        LOGE "Fallo descarga del CLI. ¿Conectividad a GitHub?"
    else
        chmod 644 "$helper_dir/haproxy_panel_routes.py" "$helper_dir/haproxy_panel_inbounds.py"
        chmod +x /usr/bin/movivip
        LOGI "CLI y helpers HAProxy/inbounds actualizados. Relanza movivip."
    fi
    before_show_menu
}

uninstall() {
    confirm "Seguro que quieres desinstalar el panel? (xray también se elimina)" "n" || { show_menu; return; }

    if [[ $release == "alpine" ]]; then
        rc-service $SERVICE_NAME stop 2>/dev/null
        rc-update del $SERVICE_NAME 2>/dev/null
        rm -f /etc/init.d/$SERVICE_NAME
    else
        systemctl stop $SERVICE_NAME 2>/dev/null
        systemctl disable $SERVICE_NAME 2>/dev/null
        rm -f /etc/systemd/system/${SERVICE_NAME}.service
        systemctl daemon-reload
        systemctl reset-failed 2>/dev/null
    fi

    rm -rf /etc/x-ui/
    rm -rf "$PANEL_DIR"
    rm -f "$CLI_BIN"

    echo ""
    LOGI "Desinstalado. Para reinstalar:"
    echo -e "${green}bash <(curl -sL https://raw.githubusercontent.com/studioanime977/movivip-panel/main/install.sh)${plain}"
    exit 0
}

# ------------------------------ Menú principal -------------------------------
show_menu() {
    echo -e "${cyan}┌─────────────────────────────────────────────────────┐${plain}"
    echo -e "${cyan}│     ${green}${PANEL_NAME} PANEL${plain}${cyan} — Panel de Administración          │${plain}"
    echo -e "${cyan}├─────────────────────────────────────────────────────┤${plain}"
    show_status
    echo -e "${cyan}├─────────────────────────────────────────────────────┤${plain}"
    echo -e "${green}\t1.${plain} Iniciar panel"
    echo -e "${green}\t2.${plain} Detener panel"
    echo -e "${green}\t3.${plain} Reiniciar panel"
    echo -e "${green}\t4.${plain} Estado / logs del servicio"
    echo -e "${green}\t5.${plain} Ver ajustes y URL de acceso"
    echo -e "${green}\t6.${plain} Cambiar puerto del panel"
    echo -e "${green}\t7.${plain} Resetear usuario/contraseña"
    echo -e "${green}\t8.${plain} Resetear web base path"
    echo -e "${green}\t9.${plain} Resetear ajustes (cuentas intactas)"
    echo -e "${green}\t10.${plain} Ver logs"
    echo -e "${green}\t11.${plain} Auto-arranque (enable/disable)"
    echo -e "${green}\t12.${plain} Actualizar panel"
    echo -e "${green}\t13.${plain} Actualizar CLI movivip"
    echo -e "${green}\t14.${plain} Geo files (geoip/geosite)"
    echo -e "${green}\t15.${plain} SSL / Certificados"
    echo -e "${green}\t16.${plain} Firewall"
    echo -e "${green}\t17.${plain} BBR"
    echo -e "${green}\t18.${plain} Sincronizar inbounds HAProxy"
    echo -e "${green}\t19.${plain} ${red}Desinstalar${plain}"
    echo -e "${green}\t0.${plain} ${red}Salir${plain}"
    echo -e "${cyan}└─────────────────────────────────────────────────────┘${plain}"
    read -rp "Elige una opción: " choice
    case "$choice" in
        1) start ;;
        2) stop ;;
        3) restart ;;
        4) status_cmd ;;
        5) check_config; before_show_menu ;;
        6) set_port ;;
        7) reset_user ;;
        8) reset_webbasepath ;;
        9) reset_config ;;
        10) show_log ;;
        11)
            echo -e "${green}\t1.${plain} Activar auto-arranque"
            echo -e "${green}\t2.${plain} Desactivar auto-arranque"
            echo -e "${green}\t0.${plain} Volver"
            read -rp "Opción: " sc
            case "$sc" in
                1) enable_cmd; before_show_menu ;;
                2) disable_cmd; before_show_menu ;;
                *) show_menu ;;
            esac ;;
        12) update ;;
        13) update_shell ;;
        14) update_geo; before_show_menu ;;
        15) ssl_menu ;;
        16) firewall_menu ;;
        17) bbr_menu ;;
        18) haproxy_sync_inbounds; before_show_menu ;;
        19) uninstall ;;
        0) exit 0 ;;
        *) LOGE "Opción inválida."; show_menu ;;
    esac
}

# ------------------------------ HAProxy sync inbounds ------------------------
# Puertos y paths PROPIOS del panel — NO chocan con Xray manager (10002-10004)
# ni V2Ray (10022-10024). Ver presets/haproxy-inbounds.json
PANEL_BACKEND_PORTS=(11002 11003 11004 11012 11013 11014)
XRAY_MANAGER_PORTS=(10002 10003 10004 10012 10013 10014 10015)
V2RAY_PORTS=(10022 10023 10024 10032 10033 10034)

inject_haproxy_panel_routes() {
    command -v python3 >/dev/null 2>&1 || { LOGE "python3 requerido para inyectar rutas HAProxy."; return 1; }
    local cfg="${HAPROXY_CFG:-/etc/haproxy/haproxy.cfg}"
    local helper="$PANEL_DIR/lib/haproxy_panel_routes.py"
    local backup result
    [[ -f "$cfg" ]] || { LOGE "No existe $cfg"; return 1; }
    [[ -s "$helper" ]] || { LOGE "No existe el helper de rutas: $helper"; return 1; }

    backup=$(mktemp "${cfg}.panel-backup.XXXXXX") || { LOGE "No se pudo crear respaldo de HAProxy."; return 1; }
    if ! cp -p "$cfg" "$backup"; then
        rm -f "$backup"
        LOGE "No se pudo respaldar $cfg."
        return 1
    fi
    if ! result=$(python3 "$helper" "$cfg"); then
        if ! cp -p "$backup" "$cfg"; then
            LOGE "Falló la inyección; respaldo disponible en $backup."
            return 1
        fi
        rm -f "$backup"
        LOGE "No se pudieron inyectar las rutas del panel."
        return 1
    fi
    if ! haproxy -c -f "$cfg" >/dev/null 2>&1; then
        if ! cp -p "$backup" "$cfg"; then
            LOGE "haproxy -c falló; respaldo disponible en $backup."
            return 1
        fi
        rm -f "$backup"
        LOGE "haproxy -c falló; se restauró la configuración anterior."
        haproxy -c -f "$cfg" 2>&1 | tail -5
        return 1
    fi

    if [[ "$result" == *MOVIVIP_PANEL_ROUTES_UPDATED* ]]; then
        if ! systemctl reload haproxy 2>/dev/null && ! systemctl restart haproxy 2>/dev/null; then
            if ! cp -p "$backup" "$cfg"; then
                LOGE "Falló la recarga; respaldo disponible en $backup."
                return 1
            fi
            rm -f "$backup"
            LOGE "No se pudo recargar ni reiniciar HAProxy."
            return 1
        fi
        LOGI "Rutas del panel instaladas y HAProxy recargado."
    else
        LOGI "Rutas del panel ya listas; no se modificó ni recargó HAProxy."
    fi
    rm -f "$backup"
}

check_panel_port_conflicts() {
    local conflict=0 p owner
    for p in "${PANEL_BACKEND_PORTS[@]}"; do
        if ss -lnt 2>/dev/null | grep -q ":${p} "; then
            owner=$(ss -lntp 2>/dev/null | grep ":${p} " | head -1 | grep -oP 'users:\(\("\K[^"]+' || echo "?")
            # Si lo escucha el xray del panel (3x-ui), no es conflicto
            if [[ "$owner" != *"x-ui"* && "$owner" != *"xray"* ]] || [[ -n "$owner" && "$owner" != "x-ui" && "$owner" != "xray" ]]; then
                # Verificar si es xray del panel (mismo binario)
                if pgrep -f "x-ui.*bin/xray" >/dev/null 2>&1 || pgrep -af xray 2>/dev/null | grep -q "config.json"; then
                    # Puede ser xray del panel — warning suave
                    LOGW "Puerto $p en uso ($owner) — si es xray del panel OK, si es manager/v2ray CHOCA."
                else
                    LOGE "CONFLICTO puerto $p ocupado por: $owner"
                    conflict=1
                fi
            fi
        fi
    done
    # Avisar si xray manager activo en puertos viejos
    for p in "${XRAY_MANAGER_PORTS[@]}"; do
        if ss -lnt 2>/dev/null | grep -q ":${p} "; then
            LOGI "Info: xray manager usa $p (OK — panel usa 11000+)"
        fi
    done
    return $conflict
}

haproxy_sync_inbounds() {
    check_install && return 1
    haproxy_mode || { LOGE "No hay /etc/haproxy/haproxy.cfg — ssl.sh no instalado."; return 1; }
    command -v python3 >/dev/null 2>&1 || { LOGE "Se requiere python3."; return 1; }

    check_panel_port_conflicts || {
        LOGW "Hay posibles conflictos de puertos. Revisa arriba antes de continuar."
        confirm "¿Continuar igualmente?" "n" || return 1
    }

    local cred="/etc/movivip/xui-credentials"
    [[ -f "$cred" ]] || { LOGE "Faltan credenciales en $cred (reinstala o reset_user)."; return 1; }

    local panel_settings panel_port panel_base_path
    panel_settings=$($XUI_BIN setting -show true 2>/dev/null)
    panel_port=$(echo "$panel_settings" | grep -Eo 'port: .+' | awk '{print $2}')
    [[ -z "$panel_port" ]] && panel_port="$PANEL_PORT_INTERNAL"
    panel_base_path=$(echo "$panel_settings" | grep -Eo 'webBasePath: .+' | awk '{print $2}')

    local presets="/tmp/movivip-haproxy-inbounds.json"
    local presets_url="https://raw.githubusercontent.com/studioanime977/movivip-panel/main/presets/haproxy-inbounds.json"
    LOGI "Cargando preset de los seis inbounds (paths /mx-*, puertos 11002+)..."
    if [[ -s "$PANEL_DIR/presets/haproxy-inbounds.json" ]]; then
        cp "$PANEL_DIR/presets/haproxy-inbounds.json" "$presets"
    else
        wget --inet4-only -q -O "$presets" "$presets_url" || true
    fi
    [[ -s "$presets" ]] || { LOGE "No se pudo descargar presets."; return 1; }

    LOGI "Sincronizando y rotulando inbounds del panel → 11002-11004 / 11012-11014..."
    local inbounds_helper="$PANEL_DIR/lib/haproxy_panel_inbounds.py"
    [[ -s "$inbounds_helper" ]] || { LOGE "No existe el helper de inbounds: $inbounds_helper."; return 1; }
    local forbidden_csv="10002,10003,10004,10012,10013,10014,10015,10022,10023,10024,10032,10033,10034,80,443,8080,8443,54322,54323"
    python3 "$inbounds_helper" "$panel_port" "$cred" "$presets" "$forbidden_csv" "$panel_base_path"

    local rc=$?
    rm -f "$presets"
    if [[ $rc -ne 0 ]]; then
        LOGE "Sync de inbounds falló (rc=$rc)."
        return 1
    fi

    LOGI "Seis inbounds sincronizados. Inyectando rutas HAProxy..."
    inject_haproxy_panel_routes || { rm -f "$presets"; return 1; }
    rm -f "$presets"

    LOGI "Reiniciando panel..."
    restart 0
    echo ""
    echo -e "${green}Mapa PANEL (3x-ui) — separado de xray manager:${plain}"
    echo "  /mx-vmess       → 127.0.0.1:11002  (NO /vmess de xray :10002)"
    echo "  /mx-vless       → 127.0.0.1:11003  (NO /vless de xray :10003)"
    echo "  /mx-trojan-ws   → 127.0.0.1:11004  (NO /trojan-ws :10004)"
    echo "  /mx-vmess-grpc  → 127.0.0.1:11012"
    echo "  /mx-vless-grpc  → 127.0.0.1:11013"
    echo "  /mx-trojan-grpc → 127.0.0.1:11014"
    echo "  WebSocket HTTP  → :80 / :8080; TLS → :443 / :8443"
    echo "  gRPC TLS/H2     → :443 / :8443"
    echo ""
    echo -e "${yellow}Xray manager sigue en:${plain} 10002-10004, 10012-10014 (/vmess, /vless...)"
    echo -e "${yellow}V2Ray sigue en:${plain} 10022-10024 (/vmess-v2ray...)"
    echo -e "${green}Link cliente panel:${plain} https://<IP>:443/mx-vless?..."
}

# ------------------------------ CLI subcomandos ------------------------------
case "$1" in
    start)   start 0 ;;
    stop)    stop 0 ;;
    restart) restart 0 ;;
    status)  status_cmd 0 ;;
    settings|config) check_install && check_config ;;
    log)     show_log 0 ;;
    enable)  enable_cmd 0 ;;
    disable) disable_cmd 0 ;;
    update)  update ;;
    update_shell) update_shell ;;
    uninstall) uninstall ;;
    reset_user) reset_user ;;
    reset_webbasepath) reset_webbasepath ;;
    reset_config) reset_config ;;
    bbr)     enable_bbr ;;
    geo)     update_geo ;;
    ssl)     ssl_cert_issue ;;
    firewall) firewall_menu ;;
    haproxy-sync|haproxy_inbounds) haproxy_sync_inbounds ;;
    *)
        show_menu ;;
esac
