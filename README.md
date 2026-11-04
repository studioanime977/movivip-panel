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
bash install.sh --port 8443        # puerto fijo
bash install.sh --no-firewall      # sin tocar firewall
bash install.sh --version v2.4.0   # versión específica
bash install.sh --silent           # solo log en /var/log/movivip-install.log
```

## CLI

```bash
movivip              # menú de administración
movivip start        # iniciar
movivip stop         # detener
movivip restart      # reiniciar
movivip status       # estado
movivip settings     # ajustes + URL de acceso
movivip log          # logs
movivip update       # actualizar panel
movivip uninstall    # desinstalar
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
