# 🔐 Guía de Certificados TLS — MOVIVIP PANEL

## 📋 Requisitos previos

- Dominio apuntando a tu VPS (registro A en DNS)
- Puerto 80 libre (detener nginx/apache si corren)
- Acceso root a la VPS

---

## 🚀 Instalación paso a paso (standalone HTTP)

### 1. Instalar acme.sh

```bash
curl https://get.acme.sh | sh
source ~/.bashrc
```

### 2. Registrar email

```bash
~/.acme.sh/acme.sh --register-account -m tuemail@ejemplo.com
```

### 3. Detener servicios en puerto 80

```bash
systemctl stop nginx 2>/dev/null
systemctl stop apache2 2>/dev/null
pkill -9 -f "python.*8080" 2>/dev/null
sleep 5
```

### 4. Obtener certificado

```bash
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh --issue -d tudominio.com --standalone --force
```

### 5. Verificar

```bash
ls -la ~/.acme.sh/ | grep tudominio.com
ls -la ~/.acme.sh/tudominio.com_ecc/
```

Deberías ver:
- `fullchain.cer` — certificado público
- `tudominio.com.key` — clave privada
- `ca.cer` — certificado CA

---

## 🌐 Asignar al panel MOVIVIP

### Opción A — Desde el CLI (recomendado)

```bash
movivip
# → 15. SSL / Certificados → 1. Obtener certificado SSL
```

El CLI emite el certificado, lo guarda en `/root/cert/<dominio>/` y lo asigna al panel automáticamente.

### Opción B — Manual

1. Abrir el panel web (URL impresa en la instalación)
2. **Ajustes del panel** → **Certificado digital**
3. Rutas:

```
Clave Pública:  /root/.acme.sh/tudominio.com_ecc/fullchain.cer
Clave Privada:  /root/.acme.sh/tudominio.com_ecc/tudominio.com.key
```

4. Guardar y:

```bash
movivip restart
```

5. Verificar:

```bash
ss -tulpn | grep 443
```

---

## 🔄 Renovación automática

Los certificados se renuevan cada 90 días vía cron de acme.sh.

```bash
# Verificar cron
crontab -l | grep acme

# Renovar manualmente
~/.acme.sh/acme.sh --renew -d tudominio.com --force
movivip restart
```

---

## ☁️ Alternativa: Cloudflare DNS (sin puerto 80)

Útil si el puerto 80 está bloqueado por el proveedor:

```bash
export CF_Key="tu_global_api_key"
export CF_Email="tu_email_cf"

~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh --issue --dns dns_cf -d tudominio.com -d *.tudominio.com --force
```

Instalar:

```bash
mkdir -p /root/cert/tudominio.com
~/.acme.sh/acme.sh --installcert -d tudominio.com \
  --key-file /root/cert/tudominio.com/privkey.pem \
  --fullchain-file /root/cert/tudominio.com/fullchain.pem \
  --reloadcmd "movivip restart"
```

---

## 📝 Notas

### Mismo dominio en múltiples puertos
Usa las mismas rutas para 443, 8443, 2096, etc.

### Múltiples dominios
Un certificado por dominio — cada uno tendrá su propia ruta.

### Troubleshooting

| Error | Solución |
|---|---|
| Puerto 80 ocupado | `ss -tulpn \| grep :80` y detener el servicio |
| Dominio no apunta al VPS | `nslookup tudominio.com` debe devolver tu IP |
| Certificado no carga | `ls -la ~/.acme.sh/tudominio.com_ecc/` + permisos |
| Ver logs del panel | `movivip log` |

---

## 📋 Resumen rápido

```bash
# 1-4: acme.sh + certificado (ver arriba)
# 5. Asignar al panel:
movivip
# → 15 → SSL → asignar

# 6. Reiniciar
movivip restart

# 7. Verificar
ss -tulpn | grep 443
```

**✅ Renovación automática cada 90 días.**
