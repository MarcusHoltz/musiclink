#!/usr/bin/env bash
set -euo pipefail

WEB_PORT="${WEB_PORT:-7681}"
INTERNAL_PORT=7682
CERT_DIR="/etc/ttyd"
CERT="${CERT_DIR}/cert.pem"
KEY="${CERT_DIR}/key.pem"

# 1. Ensure volume mount points exist
mkdir -p /config /music /output

# 2. Generate self-signed TLS cert (idempotent)
if [[ ! -f "$CERT" ]]; then
    mkdir -p "$CERT_DIR"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$KEY" -out "$CERT" \
        -subj "/CN=musiclink" 2>/dev/null
fi

# 3. Write nginx config — nginx vars escaped with \$ to survive bash heredoc
cat > /etc/nginx/conf.d/musiclink.conf <<NGINXCONF
server {
    listen      ${WEB_PORT} ssl;
    listen      [::]:${WEB_PORT} ssl;

    ssl_certificate     ${CERT};
    ssl_certificate_key ${KEY};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location / {
        proxy_pass         http://127.0.0.1:${INTERNAL_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host       \$host;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
NGINXCONF

# 4. Start nginx in background
nginx -t -q && nginx

# 5. Startup banner
echo ""
echo "[musiclink] ─────────────────────────────────────────────────"
echo "[musiclink]  Web UI → https://<host>:${WEB_PORT}"
echo "[musiclink]  Accept the self-signed certificate warning once."
echo "[musiclink]  Source : ${SOURCE_DIR:-/music}"
echo "[musiclink]  Output : ${TARGET_DIR:-/output}"
echo "[musiclink]  Config : ${MUSICLINK_DATA:-/config}"
echo "[musiclink] ─────────────────────────────────────────────────"
echo ""

if [[ -z "${TTYD_CREDENTIAL:-}" ]]; then
    echo "[musiclink] WARNING: TTYD_CREDENTIAL not set — web terminal has no password!"
fi

# 6. Build ttyd argument list
ttyd_args=(
    --writable
    --interface 127.0.0.1
    --port "$INTERNAL_PORT"
    --client-option titleFixed=MusicLink
    --client-option disableLeaveAlert=true
)
[[ -n "${TTYD_CREDENTIAL:-}" ]] && ttyd_args+=(--credential "${TTYD_CREDENTIAL}")

# 7. Exec ttyd as PID 1 — runs musiclink.sh as the terminal session
exec ttyd "${ttyd_args[@]}" bash /opt/musiclink/musiclink.sh
