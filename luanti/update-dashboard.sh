#!/usr/bin/env bash
set -Eeuo pipefail
readonly CT_ID="${CT_ID:-108}"
readonly REF="${REF:-main}"
readonly RAW_BASE="https://raw.githubusercontent.com/ABCWeb3/proxmox-selfhosted-scripts/${REF}/luanti/dashboard"
[[ $EUID -eq 0 ]] || { echo "Run as root on the Proxmox host." >&2; exit 1; }
pct exec "$CT_ID" -- bash -s -- "$RAW_BASE" <<'CONTAINER'
set -Eeuo pipefail
RAW_BASE="$1"
curl -fsSL "$RAW_BASE/index.html" -o /opt/luanti-dashboard/static/index.html
curl -fsSL "$RAW_BASE/server.py" -o /opt/luanti-dashboard/server.py
curl -fsSL "$RAW_BASE/admin-helper.sh" -o /usr/local/sbin/luanti-dashboard-admin
curl -fsSL "$RAW_BASE/mod/init.lua" -o /var/lib/luanti/worlds/family/worldmods/family_dashboard/init.lua
python3 -m py_compile /opt/luanti-dashboard/server.py
chown -R luanti-dashboard:luanti-dashboard /opt/luanti-dashboard
chmod 0750 /opt/luanti-dashboard/server.py
chown luanti:luanti /var/lib/luanti/worlds/family/worldmods/family_dashboard/init.lua
chown root:root /usr/local/sbin/luanti-dashboard-admin
chmod 0755 /usr/local/sbin/luanti-dashboard-admin
install -d /etc/systemd/system/luanti-dashboard.service.d
cat >/etc/systemd/system/luanti-dashboard.service.d/administration.conf <<'DROPIN'
[Service]
SupplementaryGroups=systemd-journal luanti
ReadWritePaths=/var/lib/luanti/worlds/family/dashboard
RuntimeDirectory=luanti-dashboard-actions
RuntimeDirectoryMode=0750
DROPIN
cat >/etc/systemd/system/luanti-dashboard-action.path <<'PATHUNIT'
[Unit]
Description=Watch for Luanti dashboard administrative actions
After=luanti-dashboard.service
[Path]
PathExists=/run/luanti-dashboard-actions/request
Unit=luanti-dashboard-action.service
[Install]
WantedBy=multi-user.target
PATHUNIT
cat >/etc/systemd/system/luanti-dashboard-action.service <<'SERVICE'
[Unit]
Description=Execute one restricted Luanti dashboard action
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/luanti-dashboard-admin
SERVICE
if [[ -d /var/backups/luanti ]]; then
  chgrp -R luanti-dashboard /var/backups/luanti
  chmod 2750 /var/backups/luanti
  find /var/backups/luanti -type f -name 'luanti-family-*.tar.gz' -exec chmod 0640 {} +
fi
systemctl daemon-reload
install -d -o luanti -g luanti -m 2770 /var/lib/luanti/worlds/family/dashboard
systemctl restart luanti-dashboard.service
systemctl restart luanti.service
systemctl enable --now luanti-dashboard-action.path
sleep 2
systemctl --no-pager --full status luanti-dashboard.service
systemctl --no-pager --full status luanti-dashboard-action.path
CONTAINER
echo "Dashboard administration upgrade completed."
