#!/usr/bin/env python3
import os
import re
import stat
import sys
import tempfile


WS_ROUTES = r"""# BEGIN MOVIVIP-PANEL WS ROUTES
    acl acl_mx_vmess req.payload(0,256) -m reg -i "^GET /mx-vmess([?][^ ]*)? HTTP/1\.[01]"
    acl acl_mx_vless req.payload(0,256) -m reg -i "^GET /mx-vless([?][^ ]*)? HTTP/1\.[01]"
    acl acl_mx_trojan req.payload(0,256) -m reg -i "^GET /mx-trojan-ws([?][^ ]*)? HTTP/1\.[01]"
    tcp-request content accept if acl_mx_vmess
    tcp-request content accept if acl_mx_vless
    tcp-request content accept if acl_mx_trojan
    use_backend mx_vmess_backend if acl_mx_vmess
    use_backend mx_vless_backend if acl_mx_vless
    use_backend mx_trojan_backend if acl_mx_trojan
# END MOVIVIP-PANEL WS ROUTES
"""

GRPC_ROUTES = """# BEGIN MOVIVIP-PANEL GRPC ROUTES
    acl p_mx_vmess_grpc path_beg -i /mx-vmess-grpc
    acl p_mx_vless_grpc path_beg -i /mx-vless-grpc
    acl p_mx_trojan_grpc path_beg -i /mx-trojan-grpc
    use_backend mx_grpc_vmess_backend if p_mx_vmess_grpc
    use_backend mx_grpc_vless_backend if p_mx_vless_grpc
    use_backend mx_grpc_trojan_backend if p_mx_trojan_grpc
# END MOVIVIP-PANEL GRPC ROUTES
"""

BACKENDS = """# BEGIN MOVIVIP-PANEL BACKENDS
# DOWN hasta que el Xray del panel abra sus inbounds 11002+.
backend mx_vmess_backend
    mode tcp
    server mx_vmess 127.0.0.1:11002 check

backend mx_vless_backend
    mode tcp
    server mx_vless 127.0.0.1:11003 check

backend mx_trojan_backend
    mode tcp
    server mx_trojan 127.0.0.1:11004 check

backend mx_grpc_vmess_backend
    mode http
    server mx_grpc_vmess 127.0.0.1:11012 proto h2 check

backend mx_grpc_vless_backend
    mode http
    server mx_grpc_vless 127.0.0.1:11013 proto h2 check

backend mx_grpc_trojan_backend
    mode http
    server mx_grpc_trojan 127.0.0.1:11014 proto h2 check
# END MOVIVIP-PANEL BACKENDS
"""

MANAGED_BLOCKS = (
    ("# BEGIN MOVIVIP-PANEL ROUTES", "# END MOVIVIP-PANEL ROUTES"),
    ("# BEGIN MOVIVIP-PANEL WS ROUTES", "# END MOVIVIP-PANEL WS ROUTES"),
    ("# BEGIN MOVIVIP-PANEL GRPC ROUTES", "# END MOVIVIP-PANEL GRPC ROUTES"),
    ("# BEGIN MOVIVIP-PANEL BACKENDS", "# END MOVIVIP-PANEL BACKENDS"),
)


def remove_old_routes(content):
    for begin, end in MANAGED_BLOCKS:
        content = re.sub(
            re.escape(begin) + r".*?" + re.escape(end) + r"\n?",
            "",
            content,
            flags=re.S,
        )
    content = re.sub(
        r"(?m)^[ \t]*(?:acl (?:acl_path_mx\w*|p_mx_\w*|acl_mx_\w*)|"
        r"tcp-request content accept if acl_mx_\w+|use_backend mx_\w+).*\n",
        "",
        content,
    )
    return re.sub(
        r"(?ms)^backend mx_[a-z0-9_]+_backend[ \t]*\n"
        r".*?(?=^(?:global|defaults|frontend|backend|listen)\b|\Z)",
        "",
        content,
    )


def find_frontend(content, name):
    match = re.search(
        r"(?ms)^frontend " + re.escape(name) + r"[ \t]*\n.*?"
        r"(?=^(?:global|defaults|frontend|backend|listen)\b|\Z)",
        content,
    )
    if not match:
        raise ValueError(f"frontend {name} not found")
    return match


def add_routes(content):
    content = remove_old_routes(content)

    ssl_frontend = find_frontend(content, "ssl_frontend")
    ssl_body = ssl_frontend.group(0)
    ssl_anchor = re.search(
        r"(?m)^[ \t]*use_backend websocket_backend if acl_upgrade acl_websocket[ \t]*$",
        ssl_body,
    )
    if not ssl_anchor:
        ssl_anchor = re.search(
            r"(?m)^[ \t]*use_backend websocket_backend if acl_path_regex[ \t]*$",
            ssl_body,
        )
    if not ssl_anchor:
        raise ValueError("websocket fallback not found in frontend ssl_frontend")
    ssl_body = ssl_body[: ssl_anchor.start()] + WS_ROUTES + ssl_body[ssl_anchor.start() :]
    content = content[: ssl_frontend.start()] + ssl_body + content[ssl_frontend.end() :]

    h2_frontend = find_frontend(content, "h2_frontend")
    h2_body = h2_frontend.group(0)
    h2_anchor = re.search(
        r"(?m)^[ \t]*default_backend h2_not_found_backend[ \t]*$",
        h2_body,
    )
    if not h2_anchor:
        raise ValueError("fallback not found in frontend h2_frontend")
    h2_body = h2_body[: h2_anchor.start()] + GRPC_ROUTES + h2_body[h2_anchor.start() :]
    content = content[: h2_frontend.start()] + h2_body + content[h2_frontend.end() :]
    return content.rstrip() + "\n\n" + BACKENDS


def write_atomic(path, content):
    directory = os.path.dirname(os.path.abspath(path))
    mode = stat.S_IMODE(os.stat(path).st_mode)
    fd, temporary = tempfile.mkstemp(prefix=".haproxy-panel-", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as target:
            target.write(content)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    except Exception:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def main():
    if len(sys.argv) != 2:
        raise ValueError("usage: haproxy_panel_routes.py <haproxy.cfg>")
    config_path = sys.argv[1]
    with open(config_path, encoding="utf-8") as source:
        original = source.read()
    updated = add_routes(original)
    if updated == original:
        print("MOVIVIP_PANEL_ROUTES_UNCHANGED")
        return
    write_atomic(config_path, updated)
    print("MOVIVIP_PANEL_ROUTES_UPDATED")


if __name__ == "__main__":
    main()
