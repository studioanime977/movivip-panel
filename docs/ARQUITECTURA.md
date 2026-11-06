# MOVIVIP PANEL — Documento de Arquitectura

Versión: 1.0.0
Origen: Ingeniería inversa de `wilderr19/willzap` (fork de `MHSanaei/3x-ui`)

---

## 1. Qué es

MOVIVIP-PANEL es un **empaquetado propio de 3x-ui** con:

- Instalador un (`install.sh`) con branding MOVIVIP
- CLI de administración (`movivip`) instalado en `/usr/bin/movivip`
- Servicio systemd renombrado a `movivip` (evita colisión con 3x-ui existente)
- Hardening automático (credenciales aleatorias, webBasePath oculto, puerto aleatorio)
- Firewall multi-gerenciador (firewalld + ufw + iptables + ip6tables)
- Verificación SHA-256 del tarball descargado

El **panel web** (Go) y **xray** provienen del upstream `MHSanaei/3x-ui` releases. No se modifica su binario.

---

## 2. Estructura del repositorio

```
MOVIVIP-PANEL/
├── install.sh            # Instalador principal (entrypoint curl)
├── movivip.sh            # CLI admin → se instala como /usr/bin/movivip
├── lib/
│   ├── haproxy_panel_inbounds.py
│   └── haproxy_panel_routes.py
├── presets/
│   └── haproxy-inbounds.json
├── README.md             # Instrucciones de instalación
├── CERTIFICADOS.md       # Guía TLS (acme.sh standalone + Cloudflare DNS)
├── tests/
└── docs/
    └── ARQUITECTURA.md   # Este documento
```

---

## 3. Flujo de instalación (`install.sh`)

En MOVIVIP PRODUCCIÓN, `protocolos/movivip-panel.sh` conserva el control de licencia y descarga este instalador desde el repositorio MOVIVIP-PANEL. La opción de Protocolos llama directamente a ese lanzador; el antiguo `protocolos/xui.sh` ya no forma parte del flujo. El servicio, el firewall, el certificado y HAProxy se configuran aquí.

```
bash <(curl -sL https://raw.githubusercontent.com/studioanime977/movivip-panel/main/install.sh)
            │
            ▼
   ┌─────────────────┐   no
   │ ¿EUID == 0 ?    │──────────► EXIT 1 (se requiere root)
   └────────┬────────┘
            │ sí
            ▼
   ┌─────────────────┐
   │ OS detection     │  release=$ID desde /etc/os-release
   │ arch()           │  uname -m → amd64|386|arm64|armv7|...
   └────────┬────────┘
            ▼
   ┌─────────────────┐
   │ install_base()   │  wget curl tar tzdata python3 openssl vía gestor del SO
   └────────┬────────┘
            ▼
   ┌─────────────────────────────────────────┐
   │ Descarga release 3x-ui desde GitHub API │
   │ + verificación SHA-256 (opcional si se   │
   │   publica checksum en el repo)           │
   └────────┬────────────────────────────────┘
            ▼
   ┌─────────────────┐
   │ Extraer a        │  /usr/local/movivip/
   │ instalar CLI     │  movivip.sh → /usr/bin/movivip
   └────────┬────────┘
            ▼
   ┌─────────────────────────────────────────┐
   │ config_after_install()                  │
   │  • IP pública (fallback 6 APIs)         │
   │  • ¿credenciales default? → generar:    │
   │      username  = random 10              │
   │      password  = random 10              │
   │      webBasePath = random 18            │
   │      puerto interno = 54322            │
   │  • x-ui setting ... / x-ui migrate      │
   └────────┬────────────────────────────────┘
            ▼
   ┌─────────────────┐
   │ systemd          │  /etc/systemd/system/movivip.service
   │ enable + start   │  (o rc-update en Alpine)
   └────────┬────────┘
            ▼
   ┌─────────────────────────────────────────┐
   │ open_firewall_ports()                   │
   │  HAProxy: 54323 público, 54322 local   │
   │  sin HAProxy: panel solo en localhost  │
   └────────┬────────────────────────────────┘
            ▼
   ┌─────────────────────────────────────────┐
   │ Configuración HAProxy (si existe)       │
   │  • frontend HTTPS :54323 + certificado  │
   │  • rutas /mx-* y backends en 11002+     │
   │  • valida, respalda y revierte fallos   │
   └────────┬────────────────────────────────┘
   ▼
   Imprime URL de acceso + credenciales
```

---

## 4. Tabla de transformación willzap → MOVIVIP

| Componente | willzap | MOVIVIP |
|---|---|---|
| Ruta instalación | `/usr/local/x-ui/` | `/usr/local/movivip/` |
| Servicio systemd | `x-ui.service` | `movivip.service` |
| CLI | `/usr/bin/x-ui` | `/usr/bin/movivip` |
| Sub puerto | 2096 | 2096 |
| Checksum tarball | ❌ sin verificar | ✅ SHA-256 (publicado si el release lo incluye) |
| Flags CLI install | ❌ | `--port N --no-firewall --silent` |
| Log instalación | ❌ | `/var/log/movivip-install.log` |
| Desinstalador | `x-ui uninstall` | `movivip uninstall` |
| Firewall | multisistema | multisistema + nota cloud ingress |
| Branding | 3x-ui | MOVIVIP |

---

## 5. Decisiones de diseño (RE)

### 5.1 Por qué no se modifica el binario web
3x-ui es Go + Vue empaquetado en un solo binario. Forkear su UI obligaría a mantener un fork de ~50k líneas Go. El branding real se hace en:
- nombre del servicio / CLI
- banner ASCII del CLI
- docs y comando de instalación

### 5.2 Credenciales aleatorias en primer arranque
Heredado de 3x-ui upstream y reforzado por willzap:
- `hasDefaultCredential=true` → se regenera todo
- Evita el escaneo masivo de paneles en `:2053` con admin/admin

### 5.3 webBasePath aleatorio (18 chars)
Oculta el panel detrás de una ruta no adivinable:
`http://IP:PUERTO/<webBasePath>/`

### 5.4 Puerto del panel: fijo 54322 (NO aleatorio)

**Problema detectado con `ssl.sh` (HAProxy multipuerto):** un puerto aleatorio podía colisionar con backends reservados (10002-10015, 2001/2002, 443...).

**Solución:** en MOVIVIP PRODUCCIÓN el panel usa:

| Rol | Puerto | Acceso |
|---|---|---|
| Panel interno (HTTP) | **54322** | solo `127.0.0.1` (filtrado por firewall) |
| Panel externo (HTTPS) | **54323** | frontend HAProxy `xui_frontend` con certificado autofirmado |

`--port N` sigue permitido, pero **rechaza puertos reservados**.

### 5.5 Firewall: modo HAProxy vs aislado

**Con HAProxy detectado** (`/etc/haproxy/haproxy.cfg` existe):
- **NO** abre 80/443/8080/8443 (ya los maneja `ssl.sh`)
- Restringe 54322 a lo + DROP externo
- Abre solo 54323 (HTTPS del panel)
- Configura y valida el frontend `xui_frontend`/`xui_backend` en `haproxy.cfg`.
- Prepara rutas WebSocket `/mx-*` en `ssl_frontend` y gRPC en `h2_frontend`.
- Revierte la configuración HAProxy si falla la validación o recarga.

**Sin HAProxy:**
- Solo abre 22
- Panel queda en 127.0.0.1:54322 con aviso

### 5.6 Puertos RESERVADOS (nunca los toca el panel)

Heredados de `ssl.sh` + backends internos:

```
HAProxy públicos:   80  443  8080  8443
Panel:              54322 (interno)  54323 (HAProxy)
XHTTP/BHTTP:        2001  2002  2004  8880
ACME:               8765
Xray manager:       10002-10004 (WS)  10012-10014 (gRPC)  10015 (SSH-WS)
V2Ray manager:      10022-10024 (WS)  10032-10034 (gRPC)
MOVIVIP-PANEL:      11002-11004 (WS)  11012-11014 (gRPC)
```

`install.sh` y `movivip.sh` validan contra esta lista antes de asignar cualquier puerto.

### 5.7 Inbounds del panel = backends HAProxy

El instalador y `movivip haproxy-sync` crean/verifican los seis inbounds por REST; un fallo de creación o etiquetado aborta la instalación/sincronización. Cada inbound se comparte en los puertos públicos admitidos por su transporte:

| Transporte | Puerto público | Inbounds internos |
|---|---:|---|
| WS HTTP | 80, 8080 | VMess `11002`; VLESS `11003`; Trojan `11004` |
| WS TLS | 443, 8443 | VMess `11002`; VLESS `11003`; Trojan `11004` |
| gRPC TLS/H2 | 443, 8443 | VMess `11012`; VLESS `11013`; Trojan `11014` |

Cada fila tiene una ruta WS o un `serviceName` gRPC único y un backend HAProxy al puerto loopback asignado. TLS termina en HAProxy; Xray escucha en `127.0.0.1` sin TLS. La cuenta creada desde la fila del inbound se usa en todos los puertos públicos indicados para ese transporte.

La sincronización conserva los clientes y la configuración de los seis inbounds mientras actualiza solo la etiqueta visible.

- Credenciales API en `/etc/movivip/xui-credentials` (0600)
- Preset JSON: `presets/haproxy-inbounds.json`
- **No** abrir los puertos internos `11002–11014` al público.

---

## 6. Modelo de servicio

```
systemd: movivip.service
  ExecStart=/usr/local/movivip/x-ui
  WorkingDirectory=/usr/local/movivip
  Restart=always

Alpine: /etc/init.d/movivip (rc-service movivip)
```

El binario `x-ui` gestiona internamente el proceso `xray-linux-*`.

---

## 7. Hardening checklist

- [x] Credenciales default regeneradas
- [x] webBasePath aleatorio
- [x] Puerto interno fijo 54322 (sin colisión con ssl.sh)
- [x] Puertos reservados validados (install + CLI)
- [x] Puerto interno restringido a 127.0.0.1
- [x] Integración HAProxy 54323 y rutas `/mx-*` (frontends y backends)
- [x] SHA-256 del tarball (verifica el checksum publicado cuando está disponible)
- [x] Log de instalación
- [x] Firewall no toca 80/443/8080/8443 en modo HAProxy
- [ ] fail2ban (disponible vía CLI `movivip iplimit`)
- [ ] BBR (disponible vía CLI `movivip bbr`)
- [ ] TLS/HTTPS (ver CERTIFICADOS.md)

---

## 8. Plan de evolución (fase 2)

1. **Fork real de 3x-ui** → cambiar strings `x-ui` → `MOVIVIP` en web UI (requiere Go toolchain)
2. **Repositorio releases propios** → publicar tarballs con checksum en tu propio GitHub
3. **Auto-update** → `movivip update` apunta a tu repo, no al upstream
4. **Branding visual** → logo/favicon/color en la UI web (archivos `web/` de 3x-ui)
5. **Integración MOVIVIP PRODUCION** → enlazar con tu panel bash existente
