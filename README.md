# MOVIVIP PANEL

Panel de administración basado en [3x-ui](https://github.com/MHSanaei/3x-ui) con branding **MOVIVIP**.

- Servicio: `movivip` (systemd / openrc)
- Ruta: `/usr/local/movivip`
- CLI: `movivip`

## Instalación

```bash
bash <(curl -sL https://raw.githubusercontent.com/studioanime977/movivip-panel/main/install.sh)
```

### Opciones

```bash
bash install.sh --port 54322        # puerto interno (default)
bash install.sh --no-firewall       # sin tocar firewall
bash install.sh --version v2.4.0    # versión específica
bash install.sh --silent            # solo log en /var/log/movivip-install.log
```

### Integración con ssl.sh (HAProxy multipuerto)

Si detecta `/etc/haproxy/haproxy.cfg` (MOVIVIP PRODUCION):

- Puerto interno del panel: **54322** (solo `127.0.0.1`, DROP externo)
- Acceso externo: **https://IP:54323** (frontend HAProxy con cert autofirmado)
- **NO** toca 80/443/8080/8443 ni backends xray (10002-10015, 2001/2002...)
- `--port` rechaza puertos reservados

### Puertos reservados (no usar en el panel)

```
80 443 8080 8443 | 54323 | 2001 2002 2004 8880 | 8765
10002 10003 10004 | 10012 10013 10014 | 10015
```

## CLI

```bash
movivip                  # menú de administración
movivip start            # iniciar
movivip stop             # detener
movivip restart          # reiniciar
movivip status           # estado
movivip settings         # ajustes + URL de acceso
movivip haproxy-sync     # crear inbounds = backends HAProxy (10002-10004, 10012-10014)
movivip log              # logs
movivip update           # actualizar panel
movivip uninstall        # desinstalar
```

## Integración HAProxy (ssl.sh multipuerto)

Cuando `/etc/haproxy/haproxy.cfg` existe, el instala automáticamente los **inbounds** que matchean los backends:

| Ruta cliente (vía HAProxy :443) | Backend interno | Inbound 3x-ui |
|---|---|---|
| `/vmess` | `127.0.0.1:10002` | movivip-vmess-ws |
| `/vless` | `127.0.0.1:10003` | movivip-vless-ws |
| `/trojan-ws` | `127.0.0.1:10004` | movivip-trojan-ws |
| `/vmess-grpc` | `127.0.0.1:10012` | movivip-vmess-grpc |
| `/vless-grpc` | `127.0.0.1:10013` | movivip-vless-grpc |
| `/trojan-grpc` | `127.0.0.1:10014` | movivip-trojan-grpc |

- Todos los inbounds escuchan en **127.0.0.1** (sin TLS — HAProxy termina TLS)
- **Nunca** usan 80/443/8080/8443 (reservados a HAProxy)
- Presets: [`presets/haproxy-inbounds.json`](presets/haproxy-inbounds.json)
- Resync manual: `movivip haproxy-sync`

**Link de cliente ejemplo (después de añadir UUID):**
```
vless://<UUID>@<IP>:443?path=/vless&security=tls&type=ws#MOVIVIP
```

## Seguridad (generada en la instalación)

- Usuario y contraseña aleatorios (10 chars)
- WebBasePath aleatorio (18 chars) — oculta el panel
- Puerto aleatorio (1024–62000) salvo `--port`
- SHA-256 del tarball (soft-check / verificación con `.sha256`)

## Certificados TLS

Ver [CERTIFICADOS.md](CERTIFICADOS.md).

## Arquitectura

Ver [docs/ARQUITECTURA.md](docs/ARQUITECTURA.md).
