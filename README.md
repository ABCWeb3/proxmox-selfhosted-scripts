# Proxmox Self-Hosted Scripts

Installation and management scripts for self-hosted services running on Proxmox VE.

## Projects

- **Luanti** — family multiplayer game server.

## Planned structure

```text
luanti/
  install.sh
  update.sh
  backup.sh
```

## Security

- Never commit passwords, tokens, private keys, or real `.env` files.
- Review every script before running it as `root`.
- Use configuration variables instead of hard-coded network details.

## License

No license has been selected yet.
