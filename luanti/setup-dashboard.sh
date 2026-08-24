#!/usr/bin/env bash
set -Eeuo pipefail

readonly CT_ID="${CT_ID:-108}"
readonly DASHBOARD_USER="${DASHBOARD_USER:-ABC}"
readonly RAW_BASE="https://raw.githubusercontent.com/ABCWeb3/proxmox-selfhosted-scripts/main/luanti/dashboard"

die() { printf '[dashboard-setup] ERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run this script as root on the Proxmox host."
command -v pct >/dev/null 2>&1 || die "pct was not found."
pct status "$CT_ID" >/dev/null 2>&1 || die "CT $CT_ID does not exist."

if [[ -z "${DASHBOARD_PASSWORD:-}" ]]; then
  read -r -s -p "Choose a dashboard password: " DASHBOARD_PASSWORD
  printf '\n'
  read -r -s -p "Repeat the dashboard password: " DASHBOARD_PASSWORD_CONFIRM
  printf '\n'
  [[ "$DASHBOARD_PASSWORD" == "$DASHBOARD_PASSWORD_CONFIRM" ]] || die "Passwords do not match."
fi
[[ ${#DASHBOARD_PASSWORD} -ge 10 ]] || die "Use a password with at least 10 characters."

password_hash="$(printf '%s' "$DASHBOARD_PASSWORD" | sha256sum | awk '{print $1}')"
unset DASHBOARD_PASSWORD DASHBOARD_PASSWORD_CONFIRM

pct exec "$CT_ID" -- bash -s -- "$DASHBOARD_USER" "$password_hash" "$RAW_BASE" <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
DASHBOARD_USER="$1"
PASSWORD_HASH="$2"
RAW_BASE="$3"
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends ca-certificates curl python3

id luanti-dashboard >/dev/null 2>&1 ||
  useradd --system --home-dir /opt/luanti-dashboard --shell /usr/sbin/nologin luanti-dashboard

install -d -o luanti-dashboard -g luanti-dashboard /opt/luanti-dashboard/static
install -d -o luanti -g luanti /var/lib/luanti/worlds/family/worldmods/family_dashboard

curl -fsSL "$RAW_BASE/index.html" -o /opt/luanti-dashboard/static/index.html
curl -fsSL "$RAW_BASE/server.py" -o /opt/luanti-dashboard/server.py
curl -fsSL "$RAW_BASE/mod/init.lua" -o /var/lib/luanti/worlds/family/worldmods/family_dashboard/init.lua
curl -fsSL "$RAW_BASE/mod/mod.conf" -o /var/lib/luanti/worlds/family/worldmods/family_dashboard/mod.conf

chown -R luanti-dashboard:luanti-dashboard /opt/luanti-dashboard
chown -R luanti:luanti /var/lib/luanti/worlds/family/worldmods/family_dashboard
chmod 0750 /opt/luanti-dashboard/server.py

python3 - "$DASHBOARD_USER" "$PASSWORD_HASH" <<'PY'
import json, sys
with open('/etc/luanti-dashboard.json', 'w', encoding='utf-8') as handle:
    json.dump({'username': sys.argv[1], 'password_sha256': sys.argv[2]}, handle)
PY
chown root:luanti-dashboard /etc/luanti-dashboard.json
chmod 0640 /etc/luanti-dashboard.json

world_config="/var/lib/luanti/worlds/family/world.mt"
sed -i '/^load_mod_family_dashboard[[:space:]]*=/d' "$world_config"
printf '\nload_mod_family_dashboard = true\n' >> "$world_config"

cat >/etc/systemd/system/luanti-dashboard.service <<'SERVICE'
[Unit]
Description=Luanti Family Dashboard
Wants=network-online.target
After=network-online.target luanti.service

[Service]
Type=simple
User=luanti-dashboard
Group=luanti-dashboard
WorkingDirectory=/opt/luanti-dashboard
ExecStart=/usr/bin/python3 /opt/luanti-dashboard/server.py
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadOnlyPaths=/var/lib/luanti/worlds/family -/var/backups/luanti

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now luanti-dashboard.service
systemctl restart luanti.service
sleep 5
systemctl --no-pager --full status luanti-dashboard.service
systemctl --no-pager --full status luanti.service
ss -lntp | grep ':8080'
CONTAINER_SCRIPT

ct_ip="$(pct exec "$CT_ID" -- hostname -I | awk '{print $1}')"
printf '\nDashboard installed successfully.\n'
printf 'URL      : http://%s:8080\n' "$ct_ip"
printf 'Username : %s\n' "$DASHBOARD_USER"
