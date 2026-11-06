#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PANEL_DIR="$TMP/panel"
HAPROXY_CFG="$TMP/haproxy.cfg"
PANEL_PORT_HAPROXY=54323
PANEL_PORT_INTERNAL=54322
SERVICE_NAME=movivip
red=""
green=""
yellow=""
plain=""
mkdir -p "$PANEL_DIR/lib"
cp "$ROOT/lib/haproxy_panel_routes.py" "$PANEL_DIR/lib/haproxy_panel_routes.py"
cat > "$HAPROXY_CFG" <<'EOF'
frontend ssl_frontend
    mode tcp
    use_backend websocket_backend if acl_upgrade acl_websocket
    default_backend ssh_ws_default_backend

frontend h2_frontend
    mode http
    default_backend h2_not_found_backend

include /etc/haproxy/haproxy-3xui.cfg
frontend xui_frontend
    mode http
    bind *:54323 ssl crt /old/cert.pem
    default_backend xui_backend

backend xui_backend
    mode http
    server xui_local 127.0.0.1:54322 check
EOF
cp "$HAPROXY_CFG" "$TMP/haproxy-original.cfg"

sed -n '/^inject_haproxy_panel_routes() {/,/^sync_haproxy_inbounds() {/p' \
    "$ROOT/install.sh" | sed '$d' > "$TMP/inject-function.sh"
# shellcheck source=/dev/null
source "$TMP/inject-function.sh"

reloads=0
reload_ok=1
validation_ok=0
log() { :; }
haproxy() {
    [[ "$validation_ok" -eq 1 ]]
}
systemctl() {
    [[ "$2" == "haproxy" ]] || return 1
    if [[ "$1" == "reload" ]]; then
        reloads=$((reloads + 1))
        [[ "$reload_ok" -eq 1 ]]
    else
        return 1
    fi
}

original_hash="$(sha256sum "$HAPROXY_CFG" | cut -d' ' -f1)"
if inject_haproxy_panel_routes; then
    echo "FAIL: invalid HAProxy config was accepted" >&2
    exit 1
fi
[[ "$(sha256sum "$HAPROXY_CFG" | cut -d' ' -f1)" == "$original_hash" ]] || {
    echo "FAIL: invalid route injection did not roll back" >&2
    exit 1
}

validation_ok=1
inject_haproxy_panel_routes
[[ "$reloads" -eq 1 ]] || {
    echo "FAIL: changed configuration was not reloaded exactly once" >&2
    exit 1
}
inject_haproxy_panel_routes
[[ "$reloads" -eq 1 ]] || {
    echo "FAIL: idempotent injection reloaded HAProxy again" >&2
    exit 1
}

cp "$TMP/haproxy-original.cfg" "$HAPROXY_CFG"
reload_ok=0
if inject_haproxy_panel_routes; then
    echo "FAIL: failed HAProxy reload was accepted" >&2
    exit 1
fi
[[ "$(sha256sum "$HAPROXY_CFG" | cut -d' ' -f1)" == "$original_hash" ]] || {
    echo "FAIL: failed HAProxy reload did not roll back" >&2
    exit 1
}

echo "OK: panel injection validates, rolls back invalid config/reload failures, and skips unchanged reloads"

mkdir -p "$PANEL_DIR" "$TMP/bin" "$TMP/certs"
cat > "$PANEL_DIR/x-ui" <<'EOF'
#!/usr/bin/env bash
echo 'port: 54322'
EOF
chmod +x "$PANEL_DIR/x-ui"
cat > "$TMP/bin/openssl" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
    case "$1" in
        -keyout) key="$2"; shift 2 ;;
        -out) cert="$2"; shift 2 ;;
        *) shift ;;
    esac
done
printf 'test private key\n' > "$key"
printf 'test certificate\n' > "$cert"
EOF
chmod +x "$TMP/bin/openssl"
PATH="$TMP/bin:$PATH"
export PATH
HAPROXY_CERT_DIR="$TMP/certs"
export HAPROXY_CERT_DIR
validation_ok=1
reload_ok=1

sed -n '/^setup_haproxy_panel_frontend() {/,/^restrict_panel_port_local() {/p' \
    "$ROOT/install.sh" | sed '$d' > "$TMP/frontend-function.sh"
# shellcheck source=/dev/null
source "$TMP/frontend-function.sh"
haproxy_mode() { [[ -f "$HAPROXY_CFG" ]]; }
detect_public_ip() { echo '198.51.100.10'; }

setup_haproxy_panel_frontend
setup_haproxy_panel_frontend
[[ "$(grep -c '^frontend xui_frontend$' "$HAPROXY_CFG")" -eq 1 ]] || {
    echo "FAIL: panel HAProxy frontend was duplicated" >&2
    exit 1
}
! grep -q 'haproxy-3xui.cfg' "$HAPROXY_CFG" || {
    echo "FAIL: obsolete HAProxy include was not removed" >&2
    exit 1
}

frontend_hash="$(sha256sum "$HAPROXY_CFG" | cut -d' ' -f1)"
validation_ok=0
if setup_haproxy_panel_frontend; then
    echo "FAIL: invalid panel frontend configuration was accepted" >&2
    exit 1
fi
[[ "$(sha256sum "$HAPROXY_CFG" | cut -d' ' -f1)" == "$frontend_hash" ]] || {
    echo "FAIL: invalid panel frontend did not roll back" >&2
    exit 1
}

validation_ok=1
reload_ok=0
if setup_haproxy_panel_frontend; then
    echo "FAIL: failed frontend reload was accepted" >&2
    exit 1
fi
[[ "$(sha256sum "$HAPROXY_CFG" | cut -d' ' -f1)" == "$frontend_hash" ]] || {
    echo "FAIL: failed frontend reload did not roll back" >&2
    exit 1
}

echo "OK: panel HTTPS frontend is idempotent and rolls back invalid/reload failures"
