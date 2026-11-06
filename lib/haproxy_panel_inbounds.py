#!/usr/bin/env python3
import copy
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
import http.cookiejar


FORBIDDEN_PATHS = {
    "/vmess", "/vless", "/trojan-ws",
    "/vmess-v2ray", "/vless-v2ray", "/trojan-v2ray",
}
PRESERVED_FIELDS = (
    "up", "down", "total", "remark", "enable", "expiryTime", "listen",
    "port", "protocol", "settings", "streamSettings", "tag", "sniffing",
    "allocate",
)


def _mapping(value):
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except json.JSONDecodeError:
            return {}
    return value if isinstance(value, dict) else {}


def api_base(panel_port, web_base_path=""):
    path = "/" + web_base_path.strip("/")
    if path == "/":
        path = ""
    return f"http://127.0.0.1:{panel_port}{path}"


def route_matches(current, desired):
    if (
        str(current.get("port")) != str(desired.get("port"))
        or current.get("protocol") != desired.get("protocol")
    ):
        return False

    current_stream = _mapping(current.get("streamSettings"))
    desired_stream = _mapping(desired.get("streamSettings"))
    if current_stream.get("network") != desired_stream.get("network"):
        return False

    network = desired_stream.get("network")
    if network == "ws":
        current_endpoint = _mapping(current_stream.get("wsSettings")).get("path")
        desired_endpoint = _mapping(desired_stream.get("wsSettings")).get("path")
    elif network == "grpc":
        current_endpoint = _mapping(current_stream.get("grpcSettings")).get("serviceName")
        desired_endpoint = _mapping(desired_stream.get("grpcSettings")).get("serviceName")
    else:
        return False

    return bool(desired_endpoint) and current_endpoint == desired_endpoint


def _update_payload(current, remark):
    if not all(key in current for key in ("settings", "streamSettings", "port", "protocol")):
        raise ValueError("Inbound existente incompleto; no se puede actualizar sin riesgo")
    payload = {
        key: copy.deepcopy(current[key])
        for key in PRESERVED_FIELDS
        if key in current
    }
    payload["remark"] = remark
    return payload


def sync_inbounds(presets, existing, request, forbidden):
    failures = []
    existing = existing or []

    for desired in presets.get("inbounds", []):
        tag = desired.get("tag", "")
        port = int(desired.get("port", 0))
        remark = desired.get("remark") or tag

        if port in forbidden:
            print(f"BLOCKED {tag} :{port} — puerto reservado a otro servicio")
            failures.append(tag)
            continue

        stream = _mapping(desired.get("streamSettings"))
        if stream.get("network") == "ws":
            path = _mapping(stream.get("wsSettings")).get("path", "")
            if path in FORBIDDEN_PATHS:
                print(f"BLOCKED {tag} path {path} — ya usado por xray/v2ray manager")
                failures.append(tag)
                continue

        matches = [item for item in existing if route_matches(item, desired)]
        if len(matches) > 1:
            print(f"FAIL {tag} :{port}: hay varios inbounds con la misma ruta")
            failures.append(tag)
            continue

        if matches:
            current = matches[0]
            if current.get("remark") == remark:
                print(f"OK exists {tag} :{port}")
                continue
            try:
                payload = _update_payload(current, remark)
                response = request(
                    "POST", f"/panel/api/inbounds/update/{current['id']}", payload
                )
                if response.get("success"):
                    print(f"OK relabeled {tag} :{port}")
                else:
                    print(f"FAIL relabel {tag} :{port}: {response}")
                    failures.append(tag)
            except Exception as error:
                print(f"FAIL relabel {tag} :{port}: {error}")
                failures.append(tag)
            continue

        if any(str(item.get("port")) == str(port) for item in existing):
            print(f"FAIL port {port} in use by another inbound — cannot create {tag}")
            failures.append(tag)
            continue

        payload = {
            "up": 0,
            "down": 0,
            "remark": remark,
            "enable": True,
            "expiryTime": 0,
            "listen": desired.get("listen", "127.0.0.1"),
            "port": port,
            "protocol": desired.get("protocol"),
            "settings": desired.get("settings", {}),
            "streamSettings": desired.get("streamSettings", {}),
            "sniffing": desired.get(
                "sniffing", {"enabled": True, "destOverride": ["http", "tls"]}
            ),
            "tag": tag,
        }
        try:
            response = request("POST", "/panel/api/inbounds/add", payload)
            if response.get("success"):
                print(f"OK created {tag} :{port}")
            else:
                print(f"FAIL {tag} :{port}: {response}")
                failures.append(tag)
        except Exception as error:
            print(f"FAIL {tag} :{port}: {error}")
            failures.append(tag)

    print("SYNC_DONE")
    if failures:
        print("SYNC_FAILED " + ", ".join(failures))
    return failures


def verify_inbounds(presets, existing):
    failures = []
    for desired in presets.get("inbounds", []):
        matches = [item for item in existing if route_matches(item, desired)]
        if len(matches) != 1:
            print(f"VERIFY_FAIL {desired.get('tag')}: expected one inbound, found {len(matches)}")
            failures.append(desired.get("tag", "unknown"))
        elif matches[0].get("remark") != (desired.get("remark") or desired.get("tag")):
            print(f"VERIFY_FAIL {desired.get('tag')}: remark did not persist")
            failures.append(desired.get("tag", "unknown"))
        else:
            print(f"VERIFY_OK {desired.get('tag')}")
    return failures


def main():
    if len(sys.argv) not in (5, 6):
        print("Uso: haproxy_panel_inbounds.py PANEL_PORT CREDENTIALS PRESETS FORBIDDEN_PORTS [WEB_BASE_PATH]")
        return 2

    panel_port, cred_path, presets_path, forbidden_csv = sys.argv[1:5]
    web_base_path = sys.argv[5] if len(sys.argv) == 6 else ""
    forbidden = {int(value) for value in forbidden_csv.split(",") if value.strip()}
    with open(cred_path, encoding="utf-8") as credentials_file:
        credentials = {}
        for line in credentials_file:
            if "=" in line:
                key, value = line.strip().split("=", 1)
                credentials[key] = value

    base = api_base(panel_port, web_base_path)
    cookie_jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(cookie_jar)
    )
    csrf_token = ""

    def request(method, path, data=None, form=False):
        body = None
        headers = {}
        if data is not None:
            if form:
                body = urllib.parse.urlencode(data).encode()
                headers["Content-Type"] = "application/x-www-form-urlencoded"
            else:
                body = json.dumps(data).encode()
                headers["Content-Type"] = "application/json"
        if method.upper() not in ("GET", "HEAD", "OPTIONS") and csrf_token:
            headers["X-CSRF-Token"] = csrf_token
        req = urllib.request.Request(
            base + path, data=body, headers=headers, method=method
        )
        with opener.open(req, timeout=15) as response:
            return json.loads(response.read().decode() or "{}")

    try:
        csrf = request("GET", "/csrf-token")
        csrf_token = csrf.get("obj") or ""
        if not csrf.get("success") or not csrf_token:
            print(f"SYNC_FAIL: no se pudo obtener el token CSRF: {csrf}")
            return 1
        login = request(
            "POST",
            "/login",
            {
                "username": credentials.get("username", "admin"),
                "password": credentials.get("password", ""),
            },
            form=True,
        )
        if login.get("success") is False:
            print(f"LOGIN_FAIL {login}")
            return 1
        listing = request("GET", "/panel/api/inbounds/list")
        with open(presets_path, encoding="utf-8") as presets_file:
            presets = json.load(presets_file)
        if len(presets.get("inbounds", [])) != 6:
            print("SYNC_FAIL: preset debe definir exactamente seis inbounds")
            return 1
        if sync_inbounds(presets, listing.get("obj") or [], request, forbidden):
            return 1
        verified = request("GET", "/panel/api/inbounds/list")
        return 1 if verify_inbounds(
            presets, verified.get("obj") or []
        ) else 0
    except urllib.error.HTTPError as error:
        print(f"SYNC_FAIL HTTP {error.code} at {error.url}")
        return 1
    except Exception as error:
        print(f"SYNC_FAIL {error}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
