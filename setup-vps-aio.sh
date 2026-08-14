#!/usr/bin/env bash
#
# setup-vps-aio.sh  (All-In-One)
# Unified personal VPS stack on Ubuntu/Debian, all sharing port 443 via Nginx:
#   - ttyd web terminal          -> https://DOMAIN/terminal/  (WS)
#   - Xray VLESS+WS+TLS          -> https://DOMAIN/<random>/  (WS)
#   - Xray Trojan+WS+TLS         -> https://DOMAIN/<random>/  (WS)
#   - SSH                        -> key-based auth only, separate port 22
#   - Fail2ban protecting SSH
#   - BBR congestion control
#   - systemd timer health check for xray/nginx/ttyd
#
# This matches the AmberVPN "VPS Terminal" front-end HTML you uploaded:
# the ttyd path below can be used directly as the "Terminal endpoint".
#
# For your own personal use across your own devices. No SlowDNS, no
# "payload" tooling, no multi-tenant reseller account system.
#
# Usage:
#   sudo bash setup-vps-aio.sh yourdomain.example.com "ssh-ed25519 AAAA... you@laptop" [num_xray_clients]
#
# Example:
#   sudo bash setup-vps-aio.sh vps.example.com "ssh-ed25519 AAAA..." 2
#

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo bash $0 <domain> <ssh_public_key> [num_clients])"
  exit 1
fi

DOMAIN="${1:-}"
SSH_PUBKEY="${2:-}"
NUM_CLIENTS="${3:-1}"

if [[ -z "$DOMAIN" ]]; then
  echo "Usage: sudo bash $0 <domain> [ssh_public_key] [num_clients]"
  echo "  domain must already have a DNS A record pointing to this VPS's IP."
  exit 1
fi

VLESS_WS_PATH="/$(tr -dc 'a-z0-9' </dev/urandom | head -c 10)"
TROJAN_WS_PATH="/$(tr -dc 'a-z0-9' </dev/urandom | head -c 10)"
TTYD_PORT=7681

echo "=== 1. Updating system ==="
apt-get update -y
apt-get upgrade -y
apt-get install -y curl wget unzip nginx certbot python3-certbot-nginx ufw fail2ban jq build-essential

echo "=== 2. SSH key-based auth ==="
REAL_USER="${SUDO_USER:-root}"
USER_HOME=$(eval echo "~$REAL_USER")
mkdir -p "$USER_HOME/.ssh"
chmod 700 "$USER_HOME/.ssh"

if [[ -n "$SSH_PUBKEY" ]]; then
  echo "$SSH_PUBKEY" >> "$USER_HOME/.ssh/authorized_keys"
  chmod 600 "$USER_HOME/.ssh/authorized_keys"
  chown -R "$REAL_USER":"$REAL_USER" "$USER_HOME/.ssh"
  echo "Added provided public key."
else
  echo "WARNING: No SSH public key provided."
  echo "Add your key to $USER_HOME/.ssh/authorized_keys now, in another session."
  read -rp "Press Enter once done (or Ctrl+C to abort): "
fi

if [[ ! -s "$USER_HOME/.ssh/authorized_keys" ]]; then
  echo "ERROR: No authorized_keys found. Aborting before disabling password auth."
  exit 1
fi

SSHD_CONFIG="/etc/ssh/sshd_config"
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%s)"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONFIG"
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSHD_CONFIG"
systemctl restart ssh || systemctl restart sshd

echo "=== 3. Fail2ban for SSH ==="
cat > /etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600
findtime = 600
EOF
systemctl enable fail2ban
systemctl restart fail2ban

echo "=== 4. BBR congestion control ==="
cat >> /etc/sysctl.conf <<'EOF'

# BBR congestion control
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl -p
CURRENT_CC=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')

echo "=== 5. Installing ttyd ==="
if ! command -v ttyd >/dev/null 2>&1; then
  TTYD_VERSION="1.7.7"
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) TTYD_BIN="ttyd.x86_64" ;;
    aarch64) TTYD_BIN="ttyd.aarch64" ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
  esac
  curl -fsSL -o /usr/local/bin/ttyd \
    "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/${TTYD_BIN}"
  chmod +x /usr/local/bin/ttyd
fi

cat > /etc/systemd/system/ttyd.service <<EOF
[Unit]
Description=ttyd web terminal
After=network.target

[Service]
# Bound to localhost only — Nginx proxies it externally over TLS.
# "login" gives a real PAM username/password prompt inside the browser.
ExecStart=/usr/local/bin/ttyd -p ${TTYD_PORT} -i 127.0.0.1 -W login
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ttyd
systemctl restart ttyd

echo "=== 6. Installing Xray-core ==="
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

echo "=== 7. Generating Xray client identities ==="
mkdir -p /usr/local/etc/xray
CLIENTS_FILE="/usr/local/etc/xray/clients.json"
echo "[]" > "$CLIENTS_FILE"

VLESS_CLIENTS_JSON="[]"
TROJAN_CLIENTS_JSON="[]"

for i in $(seq 1 "$NUM_CLIENTS"); do
  UUID=$(cat /proc/sys/kernel/random/uuid)
  TROJAN_PW=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
  LABEL="device${i}"

  VLESS_CLIENTS_JSON=$(echo "$VLESS_CLIENTS_JSON" | jq --arg id "$UUID" --arg label "$LABEL" \
    '. + [{"id": $id, "level": 0, "email": $label}]')
  TROJAN_CLIENTS_JSON=$(echo "$TROJAN_CLIENTS_JSON" | jq --arg pw "$TROJAN_PW" --arg label "$LABEL" \
    '. + [{"password": $pw, "email": $label}]')

  jq --arg label "$LABEL" --arg uuid "$UUID" --arg trojanpw "$TROJAN_PW" \
    '. + [{"label": $label, "vless_uuid": $uuid, "trojan_password": $trojanpw}]' \
    "$CLIENTS_FILE" > "${CLIENTS_FILE}.tmp" && mv "${CLIENTS_FILE}.tmp" "$CLIENTS_FILE"
done

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 10000,
      "protocol": "vless",
      "settings": {
        "clients": ${VLESS_CLIENTS_JSON},
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "${VLESS_WS_PATH}" }
      }
    },
    {
      "listen": "127.0.0.1",
      "port": 10001,
      "protocol": "trojan",
      "settings": {
        "clients": ${TROJAN_CLIENTS_JSON}
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "${TROJAN_WS_PATH}" }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "settings": {} }
  ]
}
EOF

systemctl enable xray
systemctl restart xray

echo "=== 8. Unified Nginx config: ttyd + VLESS + Trojan, all on 443 ==="
cat > /etc/nginx/sites-available/vps-aio <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate /etc/ssl/certs/ssl-cert-snakeoil.pem;
    ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;

    root /var/www/html;
    index index.html;

    # ttyd web terminal
    location /terminal/ {
        proxy_pass http://127.0.0.1:${TTYD_PORT}/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    # Xray VLESS
    location ${VLESS_WS_PATH} {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    # Xray Trojan
    location ${TROJAN_WS_PATH} {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

ln -sf /etc/nginx/sites-available/vps-aio /etc/nginx/sites-enabled/vps-aio
rm -f /etc/nginx/sites-enabled/default
echo "<h1>It works.</h1>" > /var/www/html/index.html
nginx -t && systemctl restart nginx

echo "=== 9. Let's Encrypt certificate ==="
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m admin@"$DOMAIN" --redirect || \
  echo "Certbot failed — confirm DNS A record for $DOMAIN points here, then re-run: certbot --nginx -d $DOMAIN"

echo "=== 10. Firewall ==="
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

echo "=== 11. Health check (ttyd + xray + nginx) ==="
cat > /usr/local/bin/vps-health-check.sh <<'EOF'
#!/usr/bin/env bash
LOG="/var/log/vps-health.log"
ts() { date '+%Y-%m-%d %H:%M:%S'; }

for svc in xray nginx ttyd; do
  if ! systemctl is-active --quiet "$svc"; then
    echo "$(ts) WARNING: $svc is down, restarting..." >> "$LOG"
    systemctl restart "$svc"
    sleep 2
    if systemctl is-active --quiet "$svc"; then
      echo "$(ts) $svc restarted successfully." >> "$LOG"
    else
      echo "$(ts) ERROR: $svc failed to restart." >> "$LOG"
    fi
  fi
done
EOF
chmod +x /usr/local/bin/vps-health-check.sh

cat > /etc/systemd/system/vps-health-check.service <<'EOF'
[Unit]
Description=VPS health check (xray/nginx/ttyd)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vps-health-check.sh
EOF

cat > /etc/systemd/system/vps-health-check.timer <<'EOF'
[Unit]
Description=Run VPS health check every 2 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now vps-health-check.timer

echo ""
echo "======================================================"
echo " DONE — everything is behind https://${DOMAIN}/ on 443"
echo "======================================================"
echo ""
echo "SSH:"
echo "  ssh -i /path/to/your/private_key ${REAL_USER}@${DOMAIN}"
echo "  (password login disabled, fail2ban active, 5 tries/1hr ban)"
echo ""
echo "BBR congestion control: ${CURRENT_CC}"
echo "Health check: every 2 min -> /var/log/vps-health.log"
echo ""
echo "ttyd web terminal (paste into the AmberVPN page's 'host' field):"
echo "  Terminal endpoint: ${DOMAIN}/terminal"
echo "  Scheme: https"
echo "  (i.e. full URL https://${DOMAIN}/terminal/)"
echo ""
echo "--- Xray client configs (also saved to /usr/local/etc/xray/clients.json) ---"
jq -c '.[]' /usr/local/etc/xray/clients.json | while read -r c; do
  LABEL=$(echo "$c" | jq -r '.label')
  UUID=$(echo "$c" | jq -r '.vless_uuid')
  TPW=$(echo "$c" | jq -r '.trojan_password')
  echo ""
  echo "[$LABEL]"
  echo "  VLESS link:"
  echo "    vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&type=ws&host=${DOMAIN}&path=${VLESS_WS_PATH}#${DOMAIN}-${LABEL}-vless"
  echo "  Trojan link:"
  echo "    trojan://${TPW}@${DOMAIN}:443?security=tls&type=ws&host=${DOMAIN}&path=${TROJAN_WS_PATH}#${DOMAIN}-${LABEL}-trojan"
done
echo ""
echo "Full client data saved at: /usr/local/etc/xray/clients.json (keep private)"
