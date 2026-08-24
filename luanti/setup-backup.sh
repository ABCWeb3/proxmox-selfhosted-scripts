#!/usr/bin/env bash
set -Eeuo pipefail

# Installs a daily Luanti backup timer inside an existing Proxmox LXC.
# Run as root on the Proxmox host.

readonly CT_ID="${CT_ID:-108}"

die() {
  printf '[luanti-backup-setup] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $EUID -eq 0 ]] || die "Run this script as root on the Proxmox host."
command -v pct >/dev/null 2>&1 || die "pct was not found."
pct status "$CT_ID" >/dev/null 2>&1 || die "CT $CT_ID does not exist."

pct exec "$CT_ID" -- bash -s <<'CONTAINER_SCRIPT'
set -Eeuo pipefail

install -d -m 0750 /var/backups/luanti

cat >/usr/local/sbin/luanti-backup <<'BACKUP_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

readonly BACKUP_DIR="/var/backups/luanti"
readonly WORLD_DIR="/var/lib/luanti/worlds/family"
readonly CONFIG_FILE="/etc/luanti/luanti.conf"
readonly RETENTION_DAYS="7"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
temporary="$BACKUP_DIR/.luanti-family-$timestamp.tar.gz.tmp"
archive="$BACKUP_DIR/luanti-family-$timestamp.tar.gz"
was_running=0

restart_server() {
  rm -f "$temporary"
  if [[ "$was_running" -eq 1 ]]; then
    systemctl start luanti
  fi
}
trap restart_server EXIT

[[ -d "$WORLD_DIR" ]] || {
  printf 'World directory not found: %s\n' "$WORLD_DIR" >&2
  exit 1
}

install -d -m 0750 "$BACKUP_DIR"

if systemctl is-active --quiet luanti; then
  was_running=1
  systemctl stop luanti
fi

tar --numeric-owner -C / -czf "$temporary"   "${WORLD_DIR#/}"   "${CONFIG_FILE#/}"

mv "$temporary" "$archive"
chmod 0640 "$archive"

find "$BACKUP_DIR" -maxdepth 1 -type f   -name 'luanti-family-*.tar.gz'   -mtime "+$RETENTION_DAYS" -delete

printf 'Created backup: %s\n' "$archive"
BACKUP_SCRIPT

chmod 0750 /usr/local/sbin/luanti-backup

cat >/etc/systemd/system/luanti-backup.service <<'SERVICE'
[Unit]
Description=Back up Luanti family world
After=luanti.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/luanti-backup
SERVICE

cat >/etc/systemd/system/luanti-backup.timer <<'TIMER'
[Unit]
Description=Daily Luanti family-world backup

[Timer]
OnCalendar=*-*-* 04:00:00 Africa/Algiers
Persistent=true
RandomizedDelaySec=5m
Unit=luanti-backup.service

[Install]
WantedBy=timers.target
TIMER

systemctl daemon-reload
systemctl enable --now luanti-backup.timer
systemctl start luanti-backup.service
systemctl --no-pager --full status luanti-backup.timer
ls -lh /var/backups/luanti/
CONTAINER_SCRIPT
