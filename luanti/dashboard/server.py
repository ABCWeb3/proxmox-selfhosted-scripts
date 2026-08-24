#!/usr/bin/env python3
import base64
import hashlib
import hmac
import json
import os
import re
import subprocess
import time
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path

STATIC_DIR = Path("/opt/luanti-dashboard/static")
WORLD_DIR = Path("/var/lib/luanti/worlds/family")
DATA_DIR = WORLD_DIR / "dashboard"
BACKUP_DIR = Path("/var/backups/luanti")
CONFIG_FILE = Path("/etc/luanti-dashboard.json")
ACTION_DIR = Path("/run/luanti-dashboard-actions")

def read_json(path, fallback):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return fallback

def service_value(prop):
    try:
        return subprocess.check_output(["systemctl", "show", "luanti", f"--property={prop}", "--value"], text=True, timeout=2).strip()
    except (subprocess.SubprocessError, OSError):
        return ""

def directory_size(path):
    total = 0
    try:
        for root, _, files in os.walk(path):
            for name in files:
                try:
                    total += (Path(root) / name).stat().st_size
                except OSError:
                    pass
    except OSError:
        pass
    return total

def memory_mb():
    pid = service_value("MainPID")
    if not pid or pid == "0":
        return 0
    try:
        for line in Path(f"/proc/{pid}/status").read_text().splitlines():
            if line.startswith("VmRSS:"):
                return round(int(line.split()[1]) / 1024, 1)
    except (OSError, ValueError):
        pass
    return 0

def uptime_seconds():
    started = service_value("ActiveEnterTimestampMonotonic")
    try:
        boot_seconds = float(Path("/proc/uptime").read_text().split()[0])
        return max(0, int(boot_seconds - (int(started) / 1_000_000)))
    except (OSError, ValueError, IndexError):
        return 0

def backup_files():
    try:
        files = sorted(BACKUP_DIR.glob("luanti-family-*.tar.gz"), key=lambda p: p.stat().st_mtime, reverse=True)
        return [{"name": p.name, "time": int(p.stat().st_mtime), "size": p.stat().st_size} for p in files]
    except OSError:
        return []

def latest_backup():
    try:
        files = sorted(BACKUP_DIR.glob("luanti-family-*.tar.gz"), key=lambda p: p.stat().st_mtime, reverse=True)
        if files:
            item = files[0]
            return {"name": item.name, "time": int(item.stat().st_mtime), "size": item.stat().st_size, "count": len(files)}
    except OSError:
        pass
    return {"name": None, "time": None, "size": 0, "count": 0}

def dashboard_payload():
    state = read_json(DATA_DIR / "state.json", {"players": [], "player_count": 0, "generated_at": None})
    chat = read_json(DATA_DIR / "chat.json", [])
    return {"generated_at": int(time.time()), "state": state, "chat": chat[:50], "backups": backup_files(), "server": {"status": service_value("ActiveState") or "unknown", "memory_mb": memory_mb(), "uptime_seconds": uptime_seconds(), "world_bytes": directory_size(WORLD_DIR), "port": 30000, "backup": latest_backup()}}

class DashboardHandler(SimpleHTTPRequestHandler):
    server_version = "LuantiDashboard/1.0"
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(STATIC_DIR), **kwargs)
    def log_message(self, fmt, *args):
        return
    def authorized(self):
        config = read_json(CONFIG_FILE, {})
        header = self.headers.get("Authorization", "")
        if not header.startswith("Basic "):
            return False
        try:
            decoded = base64.b64decode(header[6:]).decode("utf-8")
            username, password = decoded.split(":", 1)
        except (ValueError, UnicodeDecodeError):
            return False
        candidate = hashlib.sha256(password.encode()).hexdigest()
        return username == config.get("username") and hmac.compare_digest(candidate, config.get("password_sha256", ""))
    def require_auth(self):
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="Luanti Family Dashboard", charset="UTF-8"')
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
    def do_GET(self):
        if not self.authorized():
            self.require_auth()
            return
        if self.path.startswith("/api/backups/"):
            name = self.path.split("/")[-1]
            if not name.startswith("luanti-family-") or not name.endswith(".tar.gz"):
                self.send_error(404); return
            path = BACKUP_DIR / name
            try:
                data = path.read_bytes()
            except OSError:
                self.send_error(404); return
            self.send_response(200)
            self.send_header("Content-Type", "application/gzip")
            self.send_header("Content-Disposition", f'attachment; filename="{name}"')
            self.send_header("Content-Length", str(len(data)))
            self.end_headers(); self.wfile.write(data); return
        if self.path == "/api/logs":
            result = subprocess.run(["journalctl", "-u", "luanti.service", "-n", "120", "--no-pager", "-o", "short-iso"], text=True, capture_output=True, timeout=8)
            payload = json.dumps({"ok": result.returncode == 0, "logs": result.stdout[-30000:], "error": result.stderr}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(payload))); self.end_headers(); self.wfile.write(payload); return
        if self.path == "/api/dashboard":
            payload = json.dumps(dashboard_payload()).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        super().do_GET()
    def do_POST(self):
        if not self.authorized():
            self.require_auth(); return
        if self.path == "/api/game-command":
            if self.headers.get("Content-Type", "").split(";")[0] != "application/json":
                self.send_error(415); return
            try:
                length = min(int(self.headers.get("Content-Length", "0")), 4096)
                command = json.loads(self.rfile.read(length))
                action = command.get("action")
                player = command.get("player", "")
                message = command.get("message", "")
                if action not in {"announce", "kick", "ban", "unban"}:
                    raise ValueError("Unsupported action")
                if action == "announce":
                    if not isinstance(message, str) or not message.strip() or len(message) > 300:
                        raise ValueError("Announcement must contain 1-300 characters")
                    payload_data = {"action": action, "message": message.strip()}
                else:
                    if not isinstance(player, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,32}", player):
                        raise ValueError("Invalid player name")
                    payload_data = {"action": action, "player": player}
                target = DATA_DIR / "command.json"
                fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o660)
                with os.fdopen(fd, "w") as handle:
                    json.dump(payload_data, handle)
                response, code = {"ok": True, "message": action + " queued."}, 202
            except FileExistsError:
                response, code = {"ok": False, "message": "Another game command is pending."}, 409
            except (ValueError, json.JSONDecodeError) as exc:
                response, code = {"ok": False, "message": str(exc)}, 400
            except OSError as exc:
                response, code = {"ok": False, "message": "Could not queue command: " + str(exc)}, 500
            payload = json.dumps(response).encode()
            self.send_response(code); self.send_header("Content-Type", "application/json"); self.send_header("Cache-Control", "no-store"); self.send_header("Content-Length", str(len(payload))); self.end_headers(); self.wfile.write(payload); return
        if self.path != "/api/action" or self.headers.get("Content-Type", "").split(";")[0] != "application/json":
            self.send_error(404); return
        try:
            length = min(int(self.headers.get("Content-Length", "0")), 2048)
            action = json.loads(self.rfile.read(length)).get("action")
        except (ValueError, json.JSONDecodeError):
            self.send_error(400); return
        if action not in {"start", "stop", "restart", "backup"}:
            self.send_error(400); return
        try:
            request = ACTION_DIR / "request"
            fd = os.open(request, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as handle:
                handle.write(action + "\n")
            response, code = {"ok": True, "message": action + " accepted. Status will refresh automatically."}, 202
        except FileExistsError:
            response, code = {"ok": False, "message": "Another administrative action is still running."}, 409
        except OSError as exc:
            response, code = {"ok": False, "message": "Could not queue action: " + str(exc)}, 500
        payload = json.dumps(response).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.send_header("Cache-Control", "no-store"); self.send_header("Content-Length", str(len(payload))); self.end_headers(); self.wfile.write(payload)

if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), DashboardHandler).serve_forever()
