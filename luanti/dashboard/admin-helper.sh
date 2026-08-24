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
  settings)
    systemctl start --wait luanti-backup.service
    /usr/bin/python3 - <<'PY'
import json
from pathlib import Path
request=Path("/run/luanti-dashboard-actions/settings.json")
config=Path("/etc/luanti/luanti.conf")
data=json.loads(request.read_text())
allowed={"server_name","server_description","max_users","enable_pvp"}
if set(data) != allowed: raise SystemExit("Invalid settings keys")
if not isinstance(data["server_name"],str) or not 1<=len(data["server_name"])<=80: raise SystemExit("Invalid server name")
if not isinstance(data["server_description"],str) or len(data["server_description"])>300: raise SystemExit("Invalid description")
if not isinstance(data["max_users"],int) or not 1<=data["max_users"]<=100: raise SystemExit("Invalid max users")
if not isinstance(data["enable_pvp"],bool): raise SystemExit("Invalid PvP value")
lines=config.read_text().splitlines()
values={"server_name":data["server_name"],"server_description":data["server_description"],"max_users":str(data["max_users"]),"enable_pvp":"true" if data["enable_pvp"] else "false"}
out=[]; seen=set()
for line in lines:
    key=line.split("=",1)[0].strip() if "=" in line and not line.lstrip().startswith("#") else ""
    if key in values: out.append(f"{key} = {values[key]}"); seen.add(key)
    else: out.append(line)
for key,value in values.items():
    if key not in seen: out.append(f"{key} = {value}")
config.write_text("\n".join(out)+"\n")
request.unlink(missing_ok=True)
PY
    systemctl restart luanti.service
    ;;
  *) printf 'Rejected unsupported action.\n' >"$RESULT"; chmod 0644 "$RESULT"; exit 64 ;;
esac
printf '%s completed successfully at %s\n' "$action" "$(date --iso-8601=seconds)" >"$RESULT"
chmod 0644 "$RESULT"
logger -t luanti-dashboard "Administrative action completed: $action"
