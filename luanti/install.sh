#!/usr/bin/env bash
set -Eeuo pipefail

# Luanti + VoxeLibre installer for Proxmox VE.
# Run this script as root on the Proxmox host.

readonly CT_ID="${CT_ID:-108}"
readonly CT_NAME="${CT_NAME:-luanti}"
readonly STORAGE="${STORAGE:-local-lvm}"
readonly TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
readonly BRIDGE="${BRIDGE:-vmbr1}"
readonly MEMORY_MB="${MEMORY_MB:-2048}"
readonly SWAP_MB="${SWAP_MB:-1024}"
readonly DISK_GB="${DISK_GB:-16}"
readonly CORES="${CORES:-2}"
readonly CT_MAC="${CT_MAC:-02:00:00:00:01:08}"
readonly LUANTI_VERSION="${LUANTI_VERSION:-5.17.0}"
readonly GAME_BRANCH="${GAME_BRANCH:-master}"

log() {
  printf '[luanti-installer] %s\n' "$*"
}

die() {
  printf '[luanti-installer] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $EUID -eq 0 ]] || die "Run this script as root on the Proxmox host."
command -v pct >/dev/null 2>&1 || die "pct was not found. Run this on Proxmox VE."
command -v pveam >/dev/null 2>&1 || die "pveam was not found. Run this on Proxmox VE."

if pct status "$CT_ID" >/dev/null 2>&1; then
  die "CT $CT_ID already exists. Nothing was changed."
fi

if ! ip link show "$BRIDGE" >/dev/null 2>&1; then
  die "Bridge $BRIDGE does not exist. Set BRIDGE to the correct Proxmox bridge."
fi

log "Refreshing the Proxmox appliance list..."
pveam update

template_name="$(
  pveam available --section system |
    awk '$2 ~ /^debian-12-standard_/ {print $2}' |
    sort -V |
    tail -n 1
)"
[[ -n "$template_name" ]] || die "No Debian 12 LXC template was found."

template_path="/var/lib/vz/template/cache/$template_name"
if [[ ! -f "$template_path" ]]; then
  log "Downloading $template_name..."
  pveam download "$TEMPLATE_STORAGE" "$template_name"
fi

log "Creating CT $CT_ID ($CT_NAME)..."
pct create "$CT_ID" "$TEMPLATE_STORAGE:vztmpl/$template_name" \
  --hostname "$CT_NAME" \
  --ostype debian \
  --unprivileged 1 \
  --features nesting=1 \
  --cores "$CORES" \
  --memory "$MEMORY_MB" \
  --swap "$SWAP_MB" \
  --rootfs "$STORAGE:$DISK_GB" \
  --net0 "name=eth0,bridge=$BRIDGE,firewall=1,hwaddr=$CT_MAC,ip=dhcp,type=veth" \
  --onboot 1 \
  --start 1

log "Waiting for networking..."
for attempt in {1..30}; do
  if pct exec "$CT_ID" -- getent hosts deb.debian.org >/dev/null 2>&1; then
    break
  fi
  if [[ "$attempt" -eq 30 ]]; then
    die "The container did not obtain working DNS/network access."
  fi
  sleep 2
done

log "Installing build dependencies..."
pct exec "$CT_ID" -- bash -s -- "$LUANTI_VERSION" "$GAME_BRANCH" <<'CONTAINER_SCRIPT'
set -Eeuo pipefail

LUANTI_VERSION="$1"
GAME_BRANCH="$2"
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  build-essential ca-certificates cmake gettext git pkg-config \
  libcurl4-gnutls-dev libgmp-dev libhiredis-dev libjsoncpp-dev \
  libleveldb-dev libluajit-5.1-dev libpng-dev libsqlite3-dev \
  libssl-dev libzstd-dev zlib1g-dev

rm -rf /usr/local/src/luanti
git clone --depth 1 --branch "$LUANTI_VERSION" \
  https://github.com/luanti-org/luanti.git /usr/local/src/luanti

cmake -S /usr/local/src/luanti -B /usr/local/src/luanti/build \
  -DCMAKE_BUILD_TYPE=Release \
  -DRUN_IN_PLACE=FALSE \
  -DBUILD_CLIENT=FALSE \
  -DBUILD_SERVER=TRUE \
  -DENABLE_SYSTEM_GMP=TRUE \
  -DENABLE_SYSTEM_JSONCPP=TRUE

cmake --build /usr/local/src/luanti/build --parallel "$(nproc)"
cmake --install /usr/local/src/luanti/build

id luanti >/dev/null 2>&1 ||
  useradd --system --home-dir /var/lib/luanti --create-home --shell /usr/sbin/nologin luanti

install -d -o luanti -g luanti \
  /var/lib/luanti/games \
  /var/lib/luanti/worlds/family \
  /var/log/luanti

rm -rf /var/lib/luanti/games/voxelibre
git clone --depth 1 --branch "$GAME_BRANCH" \
  https://git.minetest.land/VoxeLibre/VoxeLibre.git \
  /var/lib/luanti/games/voxelibre

chown -R luanti:luanti /var/lib/luanti /var/log/luanti

# A system-wide Luanti build discovers games under its static shared-data path.
install -d /usr/local/share/luanti/games
ln -sfn /var/lib/luanti/games/voxelibre /usr/local/share/luanti/games/voxelibre

install -d /etc/luanti
cat >/etc/luanti/luanti.conf <<'LUANTI_CONFIG'
port = 30000
server_name = Family Luanti Server
server_description = Private family VoxeLibre world
server_announce = false
max_users = 10
disallow_empty_password = true
creative_mode = false
enable_damage = true
enable_rollback_recording = true
ipv6_server = false
map_backend = sqlite3
player_backend = sqlite3
auth_backend = sqlite3
max_block_send_distance = 12
max_block_generate_distance = 10
LUANTI_CONFIG

cat >/etc/systemd/system/luanti.service <<'UNIT'
[Unit]
Description=Luanti VoxeLibre Server
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=luanti
Group=luanti
WorkingDirectory=/var/lib/luanti
ExecStart=/usr/local/bin/luantiserver --config /etc/luanti/luanti.conf --world /var/lib/luanti/worlds/family --gameid voxelibre
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=/var/lib/luanti /var/log/luanti

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now luanti.service

apt-get purge -y build-essential cmake || true
apt-get autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/* /usr/local/src/luanti

systemctl --no-pager --full status luanti.service
CONTAINER_SCRIPT

ct_ip="$(
  pct exec "$CT_ID" -- hostname -I 2>/dev/null |
    awk '{print $1}'
)"

log "Installation completed."
printf '\n'
printf 'Container ID : %s\n' "$CT_ID"
printf 'Container    : %s\n' "$CT_NAME"
printf 'IPv4 address : %s\n' "${ct_ip:-not detected}"
printf 'DHCP MAC     : %s\n' "$CT_MAC"
printf 'Game port    : 30000/UDP\n'
printf '\n'
printf 'Reserve the displayed IPv4 address for MAC %s in OPNsense DHCP.\n' "$CT_MAC"
printf 'Check logs with: pct exec %s -- journalctl -u luanti -f\n' "$CT_ID"
