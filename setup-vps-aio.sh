#!/usr/bin/env bash
#
# setup-vps-aio.sh  (All-In-One)
# Unified personal VPS stack on Ubuntu/Debian, all sharing port 443 via Nginx:
#   - ttyd web terminal          -> https://SERVER_IP/terminal/  (WS)
#   - Xray VLESS+WS+TLS          -> https://SERVER_IP/<random>/  (WS)
#   - Xray Trojan+WS+TLS         -> https://SERVER_IP/<random>/  (WS)
#   - SSH                        -> password auth, reachable on ports 22, 80, AND 443
#                                    (443 is shared with HTTPS via sslh port multiplexing,
#                                    for use when your own network blocks port 22 outbound)
#   - BBR congestion control
#   - systemd timer health check for xray/nginx/ttyd/sslh
#   - vps-menu: interactive menu to add/delete Xray and SSH accounts
#
# No domain needed. TLS is a self-signed certificate issued for this
# VPS's public IP address (clients will need to accept/trust it manually,
# since it isn't from a public CA).
#
# Usage:
#   sudo bash setup-vps-aio.sh [num_initial_xray_clients]
#
# After setup, manage accounts anytime with:
#   sudo vps-menu
#

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo bash $0 [num_initial_xray_clients])"
  exit 1
fi

NUM_CLIENTS="${1:-1}"

echo "=== 0. Detecting this VPS's public IP ==="
SERVER_IP="${SERVER_IP:-}"
if [[ -z "$SERVER_IP" ]]; then
  SERVER_IP=$(curl -fsSL4 https://ifconfig.me || curl -fsSL4 https://api.ipify.org)
fi
if [[ -z "$SERVER_IP" ]]; then
  echo "ERROR: Could not auto-detect public IP. Set it manually, e.g.:"
  echo "  SERVER_IP=1.2.3.4 sudo -E bash $0 [num_initial_xray_clients]"
  exit 1
fi
echo "Detected public IP: ${SERVER_IP}"

VLESS_WS_PATH="/$(tr -dc 'a-z0-9' </dev/urandom | head -c 10)"
TROJAN_WS_PATH="/$(tr -dc 'a-z0-9' </dev/urandom | head -c 10)"
TTYD_PORT=7681
NGINX_TLS_PORT=8443   # internal only — sslh sits in front of public 443

echo "=== 1. Updating system ==="
apt-get update -y
apt-get upgrade -y
apt-get install -y curl wget unzip nginx openssl ufw jq sslh build-essential

echo "=== 2. Installing ttyd ==="
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

echo "=== 3. BBR congestion control ==="
cat >> /etc/sysctl.conf <<'EOF'

# BBR congestion control
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl -p
CURRENT_CC=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')

echo "=== 4. Installing Xray-core ==="
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

echo "=== 5. Generating initial Xray client identities ==="
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

echo "=== 6. Self-signed TLS certificate for ${SERVER_IP} ==="
mkdir -p /etc/ssl/vps-aio
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout /etc/ssl/vps-aio/selfsigned.key \
  -out /etc/ssl/vps-aio/selfsigned.crt \
  -days 3650 \
  -subj "/CN=${SERVER_IP}" \
  -addext "subjectAltName=IP:${SERVER_IP}"
chmod 600 /etc/ssl/vps-aio/selfsigned.key

echo "=== 7. Nginx (internal TLS on 127.0.0.1:${NGINX_TLS_PORT} — sslh fronts public 443) ==="
cat > /etc/nginx/sites-available/vps-aio <<EOF
server {
    listen 127.0.0.1:${NGINX_TLS_PORT} ssl http2;
    server_name ${SERVER_IP};

    ssl_certificate /etc/ssl/vps-aio/selfsigned.crt;
    ssl_certificate_key /etc/ssl/vps-aio/selfsigned.key;

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

echo "=== 8. SSH reachable on 22, 80, and 443 ==="
# 22 and 80: sshd listens on both directly (plain SSH protocol works on any port).
# 443: shared with HTTPS via sslh, which peeks at the first bytes of each connection
#      and routes real TLS/HTTPS traffic to Nginx (127.0.0.1:${NGINX_TLS_PORT}) and
#      SSH-looking traffic to sshd (127.0.0.1:22). This is the standard, above-board
#      way to reach your own server when a network only allows outbound 80/443 —
#      it does not affect or interact with any carrier/ISP data billing.
SSHD_CONFIG="/etc/ssh/sshd_config"
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%s)"
sed -i '/^Port /d' "$SSHD_CONFIG"
sed -i '1i Port 22\nPort 80' "$SSHD_CONFIG"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$SSHD_CONFIG"
systemctl restart ssh || systemctl restart sshd

cat > /etc/default/sslh <<EOF
RUN=yes
DAEMON_OPTS="--user sslh --listen 0.0.0.0:443 --ssh 127.0.0.1:22 --tls 127.0.0.1:${NGINX_TLS_PORT} --pidfile /var/run/sslh/sslh.pid"
EOF
systemctl enable sslh
systemctl restart sslh

echo "=== 9. Firewall ==="
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

echo "=== 10. Account management menu (Xray + SSH) ==="
mkdir -p /etc/vps-aio
cat > /etc/vps-aio/env <<EOF
SERVER_IP="${SERVER_IP}"
VLESS_WS_PATH="${VLESS_WS_PATH}"
TROJAN_WS_PATH="${TROJAN_WS_PATH}"
EOF

cat > /usr/local/bin/vps-menu <<'MENU_EOF'
#!/usr/bin/env bash
# Interactive menu: add/delete Xray accounts and add/delete SSH accounts.
set -euo pipefail
source /etc/vps-aio/env

XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_CLIENTS="/usr/local/etc/xray/clients.json"

print_xray_account() {
  local label="$1" uuid="$2" tpw="$3"
  echo ""
  echo "==================== ${label} ===================="
  echo "VLESS:"
  echo "vless://${uuid}@${SERVER_IP}:443?encryption=none&security=tls&type=ws&host=${SERVER_IP}&path=${VLESS_WS_PATH}#${SERVER_IP}-${label}-vless"
  echo ""
  echo "Trojan:"
  echo "trojan://${tpw}@${SERVER_IP}:443?security=tls&type=ws&host=${SERVER_IP}&path=${TROJAN_WS_PATH}#${SERVER_IP}-${label}-trojan"
  echo ""
  echo "(self-signed cert — enable \"allow insecure / skip cert verify\" in your client app)"
  echo "===================================================="
}

xray_add() {
  read -rp "Name for this Xray account: " LABEL
  if [[ -z "$LABEL" ]]; then echo "Name required."; return; fi
  if jq -e --arg l "$LABEL" '.[] | select(.label==$l)' "$XRAY_CLIENTS" >/dev/null 2>&1; then
    echo "That name already exists. Pick another."
    return
  fi
  UUID=$(cat /proc/sys/kernel/random/uuid)
  TPW=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)

  jq --arg id "$UUID" --arg label "$LABEL" \
    '.inbounds[0].settings.clients += [{"id": $id, "level": 0, "email": $label}]' \
    "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp" && mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"
  jq --arg pw "$TPW" --arg label "$LABEL" \
    '.inbounds[1].settings.clients += [{"password": $pw, "email": $label}]' \
    "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp" && mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"
  jq --arg label "$LABEL" --arg uuid "$UUID" --arg trojanpw "$TPW" \
    '. + [{"label": $label, "vless_uuid": $uuid, "trojan_password": $trojanpw}]' \
    "$XRAY_CLIENTS" > "${XRAY_CLIENTS}.tmp" && mv "${XRAY_CLIENTS}.tmp" "$XRAY_CLIENTS"

  systemctl restart xray
  echo "Xray account created — ready to copy:"
  print_xray_account "$LABEL" "$UUID" "$TPW"
}

xray_delete() {
  mapfile -t LABELS < <(jq -r '.[].label' "$XRAY_CLIENTS")
  if [[ ${#LABELS[@]} -eq 0 ]]; then echo "No Xray accounts yet."; return; fi
  echo "Xray accounts:"
  select LABEL in "${LABELS[@]}" "Cancel"; do
    [[ "$LABEL" == "Cancel" || -z "$LABEL" ]] && return
    jq --arg l "$LABEL" 'del(.inbounds[0].settings.clients[] | select(.email==$l))' \
      "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp" && mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"
    jq --arg l "$LABEL" 'del(.inbounds[1].settings.clients[] | select(.email==$l))' \
      "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp" && mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"
    jq --arg l "$LABEL" 'map(select(.label!=$l))' \
      "$XRAY_CLIENTS" > "${XRAY_CLIENTS}.tmp" && mv "${XRAY_CLIENTS}.tmp" "$XRAY_CLIENTS"
    systemctl restart xray
    echo "Deleted Xray account: $LABEL"
    return
  done
}

xray_list() {
  echo ""
  jq -c '.[]' "$XRAY_CLIENTS" | while read -r c; do
    LABEL=$(echo "$c" | jq -r '.label')
    UUID=$(echo "$c" | jq -r '.vless_uuid')
    TPW=$(echo "$c" | jq -r '.trojan_password')
    print_xray_account "$LABEL" "$UUID" "$TPW"
  done
}

ssh_add() {
  read -rp "SSH username: " SUSER
  if [[ -z "$SUSER" ]]; then echo "Username required."; return; fi
  if id "$SUSER" >/dev/null 2>&1; then
    echo "That user already exists."
    return
  fi
  read -rsp "SSH password (leave blank to auto-generate): " SPASS
  echo ""
  if [[ -z "$SPASS" ]]; then
    SPASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
  fi
  useradd -m -s /bin/false "$SUSER"
  echo "${SUSER}:${SPASS}" | chpasswd
  echo ""
  echo "==================== ${SUSER} (SSH) ===================="
  echo "Host:     ${SERVER_IP}"
  echo "Username: ${SUSER}"
  echo "Password: ${SPASS}"
  echo "Ports:    22, 80, 443 (443 shares HTTPS via sslh)"
  echo "==========================================================="
}

ssh_delete() {
  mapfile -t SUSERS < <(awk -F: '$3>=1000 && $3<60000 {print $1}' /etc/passwd)
  if [[ ${#SUSERS[@]} -eq 0 ]]; then echo "No SSH accounts yet."; return; fi
  echo "SSH accounts:"
  select SUSER in "${SUSERS[@]}" "Cancel"; do
    [[ "$SUSER" == "Cancel" || -z "$SUSER" ]] && return
    userdel -r "$SUSER" 2>/dev/null || userdel "$SUSER"
    echo "Deleted SSH account: $SUSER"
    return
  done
}

ssh_list() {
  echo ""
  echo "SSH accounts (host: ${SERVER_IP}, ports 22/80/443):"
  awk -F: '$3>=1000 && $3<60000 {print " - "$1}' /etc/passwd
}

while true; do
  echo ""
  echo "============ VPS Account Menu ============"
  echo "1) Add Xray account"
  echo "2) Delete Xray account"
  echo "3) List Xray accounts"
  echo "4) Add SSH account"
  echo "5) Delete SSH account"
  echo "6) List SSH accounts"
  echo "7) Exit"
  echo "============================================"
  read -rp "Choose: " CHOICE
  case "$CHOICE" in
    1) xray_add ;;
    2) xray_delete ;;
    3) xray_list ;;
    4) ssh_add ;;
    5) ssh_delete ;;
    6) ssh_list ;;
    7) exit 0 ;;
    *) echo "Invalid choice." ;;
  esac
done
MENU_EOF
chmod +x /usr/local/bin/vps-menu

echo "=== 11. Health check (ttyd + xray + nginx + sslh) ==="
cat > /usr/local/bin/vps-health-check.sh <<'EOF'
#!/usr/bin/env bash
LOG="/var/log/vps-health.log"
ts() { date '+%Y-%m-%d %H:%M:%S'; }

for svc in xray nginx ttyd sslh; do
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
Description=VPS health check (xray/nginx/ttyd/sslh)

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
echo " DONE"
echo "======================================================"
echo ""
echo "SSH — reachable on port 22, 80, AND 443 (443 shares HTTPS via sslh):"
echo "  ssh root@${SERVER_IP}                 (port 22, default)"
echo "  ssh -p 80 root@${SERVER_IP}           (port 80)"
echo "  ssh -p 443 root@${SERVER_IP}          (port 443, multiplexed with HTTPS)"
echo ""
echo "Manage Xray and SSH accounts (add/delete, ready-to-copy output):"
echo "  sudo vps-menu"
echo ""
echo "BBR congestion control: ${CURRENT_CC}"
echo "Health check: every 2 min -> /var/log/vps-health.log"
echo ""
echo "ttyd web terminal (paste into the AmberVPN page's 'host' field):"
echo "  Terminal endpoint: ${SERVER_IP}/terminal"
echo "  Scheme: https"
echo "  (i.e. full URL https://${SERVER_IP}/terminal/ — browser will warn"
echo "   about the self-signed cert; accept/proceed anyway)"
echo ""
echo "--- Initial Xray client configs (also saved to /usr/local/etc/xray/clients.json) ---"
jq -c '.[]' /usr/local/etc/xray/clients.json | while read -r c; do
  LABEL=$(echo "$c" | jq -r '.label')
  UUID=$(echo "$c" | jq -r '.vless_uuid')
  TPW=$(echo "$c" | jq -r '.trojan_password')
  echo ""
  echo "[$LABEL]"
  echo "  VLESS link:"
  echo "    vless://${UUID}@${SERVER_IP}:443?encryption=none&security=tls&type=ws&host=${SERVER_IP}&path=${VLESS_WS_PATH}#${SERVER_IP}-${LABEL}-vless"
  echo "  Trojan link:"
  echo "    trojan://${TPW}@${SERVER_IP}:443?security=tls&type=ws&host=${SERVER_IP}&path=${TROJAN_WS_PATH}#${SERVER_IP}-${LABEL}-trojan"
  echo "  (self-signed cert — client apps must allow \"insecure/skip cert verify\")"
done
echo ""
echo "Full client data saved at: /usr/local/etc/xray/clients.json (keep private)"
echo ""
echo "From now on, add/delete Xray and SSH accounts anytime with: sudo vps-menu"
