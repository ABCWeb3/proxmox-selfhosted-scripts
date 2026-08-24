# Luanti on Proxmox

Creates an unprivileged Debian 12 LXC and installs:

- Luanti dedicated server 5.17.0
- VoxeLibre
- A private family world
- A hardened systemd service

## Defaults

| Setting | Value |
|---|---|
| CT ID | 108 |
| Hostname | luanti |
| Bridge | vmbr1 |
| Storage | local-lvm |
| Network | DHCP |
| Fixed MAC | 02:00:00:00:01:08 |
| RAM | 2048 MB |
| Swap | 1024 MB |
| CPU | 2 cores |
| Disk | 16 GB |
| Game port | 30000/UDP |

Run `install.sh` as root on the Proxmox host.

The installer refuses to overwrite an existing CT with the same ID.

## Optional overrides

Environment variables can override the defaults:

```bash
CT_ID=108 BRIDGE=vmbr1 STORAGE=local-lvm bash install.sh
```

## DHCP reservation

After installation, note the assigned IPv4 address. In OPNsense, reserve that address for:

```text
02:00:00:00:01:08
```

The container will continue using DHCP, but OPNsense will always give it the same address.

## Useful commands

```bash
pct exec 108 -- systemctl status luanti
pct exec 108 -- journalctl -u luanti -f
pct exec 108 -- systemctl restart luanti
```

## Client connection

Add a server in the Luanti client using the container's IPv4 address and UDP port `30000`.
Each player chooses a unique username and creates a password on first connection.
