# MOVIVIP PANEL

Panel de administración basado en [3x-ui](https://github.com/MHSanaei/3x-ui) con branding **MOVIVIP**.

- Servicio: `movivip` (systemd / openrc)
- Ruta: `/usr/local/movivip`
- CLI: `movivip`

## Instalación

```bash
bash <(curl -sL https://raw.githubusercontent.com/studioanime977/movivip-panel/main/install.sh)
```

En MOVIVIP PRODUCCIÓN, la opción **MOVIVIP-PANEL** de Protocolos ejecuta `protocolos/movivip-panel.sh`, que descarga este `install.sh`. La configuración del servicio, credenciales, firewall, certificado y HAProxy se mantiene aquí; el antiguo `protocolos/xui.sh` ya no se usa.

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
- Acceso externo: **https://IP:54323** (frontend HAProxy con certificado autofirmado)
- HAProxy configura el frontend del panel y prepara también las rutas `/mx-*` hacia los inbounds `11002+`.
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
movivip haproxy-sync     # sincronizar los seis inbounds y sus rutas HAProxy /mx-*
movivip log              # logs
movivip update           # actualizar panel
movivip uninstall        # desinstalar
```

## Integración HAProxy (ssl.sh multipuerto)

El instalador crea y verifica obligatoriamente **seis inbounds** en 3X-UI: VMess, VLESS y Trojan sobre WebSocket, y esos mismos tres protocolos sobre gRPC. Si no puede crearlos o actualizar sus notas, la instalación falla en vez de continuar con un panel incompleto. No se crean inbounds adicionales para separar puertos. HAProxy comparte las rutas existentes por los puertos públicos compatibles:

| Transporte | Puertos públicos | Inbounds internos |
|---|---|---|
| WebSocket HTTP | `80`, `8080` | VMess `11002`, VLESS `11003`, Trojan `11004` |
| WebSocket TLS | `443`, `8443` | VMess `11002`, VLESS `11003`, Trojan `11004` |
| gRPC TLS/H2 | `443`, `8443` | VMess `11012`, VLESS `11013`, Trojan `11014` |

En **Inbounds**, las notas de cada fila muestran los puertos públicos que acepta. Añade clientes desde la fila correspondiente: la misma entrada se usa a través de cada uno de sus puertos indicados. La sincronización conserva clientes y configuración existentes y solo ajusta la etiqueta visible cuando sea necesario.

- Todos los inbounds escuchan en **127.0.0.1**. HAProxy recibe los puertos públicos y termina TLS para `443/8443`.
- **No** abras los puertos internos `11002–11014` al público.
- Presets: [`presets/haproxy-inbounds.json`](presets/haproxy-inbounds.json)
- Sincronización manual de inbounds y rutas: `movivip haproxy-sync`

**Ejemplo de cliente VLESS WS en `443` (después de añadir UUID):**
```
vless://<UUID>@<IP>:443?path=/mx-vless&security=tls&type=ws#MOVIVIP
```

En `80/8080` usa WebSocket sin TLS; en `443/8443`, WebSocket o gRPC con TLS/HTTP2.

## Seguridad (generada en la instalación)

- Usuario y contraseña aleatorios (10 chars)
- WebBasePath aleatorio (18 chars) — oculta el panel
- Puerto aleatorio (1024–62000) salvo `--port`
- SHA-256 del tarball (soft-check / verificación con `.sha256`)

## Certificados TLS

Ver [CERTIFICADOS.md](CERTIFICADOS.md).

## Arquitectura

Ver [docs/ARQUITECTURA.md](docs/ARQUITECTURA.md).
