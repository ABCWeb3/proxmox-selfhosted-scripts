#!/usr/bin/env bash
set -Eeuo pipefail
action="${1:-}"
case "$action" in
  start) systemctl start luanti.service ;;
  stop) systemctl stop luanti.service ;;
  restart) systemctl restart luanti.service ;;
  backup) systemctl start --wait luanti-backup.service ;;
  logs) journalctl -u luanti.service -n 120 --no-pager -o short-iso ;;
  *) echo "Unsupported dashboard action" >&2; exit 64 ;;
esac
logger -t luanti-dashboard "Administrative action: $action"
