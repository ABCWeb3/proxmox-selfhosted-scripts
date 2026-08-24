#!/usr/bin/env bash
set -Eeuo pipefail
readonly ACTION_DIR="/run/luanti-dashboard-actions"
readonly REQUEST="$ACTION_DIR/request"
readonly RESULT="$ACTION_DIR/result"
[[ -f "$REQUEST" ]] || exit 0
IFS= read -r action <"$REQUEST"
rm -f "$REQUEST"
case "$action" in
  start) systemctl start luanti.service ;;
  stop) systemctl stop luanti.service ;;
  restart) systemctl restart luanti.service ;;
  backup) systemctl start --wait luanti-backup.service ;;
  *) printf 'Rejected unsupported action.\n' >"$RESULT"; chmod 0644 "$RESULT"; exit 64 ;;
esac
printf '%s completed successfully at %s\n' "$action" "$(date --iso-8601=seconds)" >"$RESULT"
chmod 0644 "$RESULT"
logger -t luanti-dashboard "Administrative action completed: $action"
