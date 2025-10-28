#!/usr/bin/env python3
import os
import json
import subprocess
from datetime import datetime
from flask import Flask, request, jsonify, send_from_directory

APP_PORT = int(os.environ.get("WEBUI_PORT", "8080"))
SERVICE_NAME = os.environ.get("STREAM_SERVICE", "quest-dual-v19.service")
LEASES_FILE = "/var/lib/misc/dnsmasq.leases"
BINDINGS_FILE = "/home/pi/quest-bindings.env"
SCHEDULE_FILE = "/home/pi/stream_daemon/schedule.json"

app = Flask(__name__, static_folder="static", template_folder="templates")


def sh(cmd):
    try:
        out = subprocess.check_output(cmd, shell=True, stderr=subprocess.STDOUT, text=True, timeout=3)
        return out.strip()
    except subprocess.CalledProcessError as e:
        return e.output.strip()
    except Exception as e:
        return str(e)


def cpu_percent():
    # Parse Cpu(s) line from top -bn1
    out = sh("LANG=C top -bn1 | grep 'Cpu(s)' | sed 's/.*, *\([0-9.]*\)%* id.*/\1/'")
    try:
        idle = float(out)
        return round(100.0 - idle, 1)
    except Exception:
        return None


def cpu_temp_c():
    try:
        with open("/sys/class/thermal/thermal_zone0/temp") as f:
            millic = int(f.read().strip())
            return round(millic / 1000.0, 1)
    except Exception:
        # vcgencmd fallback
        out = sh("vcgencmd measure_temp | grep -oE '[0-9.]+'")
        try:
            return float(out)
        except Exception:
            return None


def service_state():
    out = sh(f"systemctl is-active {SERVICE_NAME} || true")
    enabled = sh(f"systemctl is-enabled {SERVICE_NAME} || true")
    return {"active": out.strip(), "enabled": enabled.strip()}


def read_bindings():
    # Default: Q3 on left
    q3_pos = "left"
    try:
        if os.path.exists(BINDINGS_FILE):
            with open(BINDINGS_FILE) as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith('#'):
                        continue
                    if line.startswith("Q3_POSITION="):
                        q3_pos = line.split("=", 1)[1].strip().strip('"').strip("'")
                        break
    except Exception:
        pass
    q3s_pos = "right" if q3_pos == "left" else "left"
    return {"q3_position": q3_pos, "q3s_position": q3s_pos}


def write_bindings(q3_position: str):
    q3_position = (q3_position or "").strip().lower()
    if q3_position not in ("left", "right"):
        raise ValueError("q3_position must be 'left' or 'right'")
    content = "# Screen bindings for quest-dual-v19.sh\n# Allowed values: left | right\nQ3_POSITION=" + q3_position + "\n"
    with open(BINDINGS_FILE, "w") as f:
        f.write(content)


def swap_bindings():
    cur = read_bindings().get("q3_position", "left")
    new_pos = "right" if cur == "left" else "left"
    write_bindings(new_pos)
    return new_pos


def xrandr_arrange_side_by_side():
    # Try to arrange all connected outputs horizontally left->right
    q = sh("DISPLAY=:0 XAUTHORITY=/home/pi/.Xauthority xrandr --query")
    outputs = []
    for line in q.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1] == "connected":
            outputs.append(parts[0])
    cmds = []
    if not outputs:
        return {"ok": False, "msg": "no connected outputs"}
    # Turn on first
    first = outputs[0]
    cmds.append(f"DISPLAY=:0 XAUTHORITY=/home/pi/.Xauthority xrandr --output {first} --auto")
    last = first
    for out in outputs[1:]:
        cmds.append(f"DISPLAY=:0 XAUTHORITY=/home/pi/.Xauthority xrandr --output {out} --auto --right-of {last}")
        last = out
    out_log = []
    for c in cmds:
        out_log.append(sh(c))
    return {"ok": True, "outputs": outputs, "log": out_log}


def list_clients():
    """Return ONLY clients currently associated to wlan0 (AP)."""
    # 1) Who is associated now (authoritative)? -> iw station dump
    macs = []
    iw_out = sh("iw dev wlan0 station dump | awk '/^Station /{print $2}'")
    for line in iw_out.splitlines():
        m = line.strip()
        if m:
            macs.append(m.lower())

    # 2) Map MAC -> IP via neighbor table
    ip_by_mac = {}
    neigh = sh("ip -4 neigh show dev wlan0 | awk '{for(i=1;i<=NF;i++){if($i==\"lladdr\"){print $1, $(i+1)}}}'")
    for row in neigh.splitlines():
        cols = row.split()
        if len(cols) >= 2:
            ip_by_mac[cols[1].lower()] = cols[0]

    # 3) Optional names from dnsmasq leases (if present)
    name_by_mac = {}
    try:
        if os.path.exists(LEASES_FILE):
            with open(LEASES_FILE) as f:
                for line in f:
                    parts = line.strip().split()
                    if len(parts) >= 5:
                        _, mac, ip, name, _ = parts[:5]
                        name_by_mac[mac.lower()] = name
    except Exception:
        pass

    clients = []
    for mac in macs:
        clients.append({
            "mac": mac,
            "ip": ip_by_mac.get(mac, ""),
            "name": name_by_mac.get(mac, ""),
        })
    return clients


def read_schedule():
    default = {"enabled": False, "on_time": "09:00", "off_time": "21:00"}
    try:
        if os.path.exists(SCHEDULE_FILE):
            with open(SCHEDULE_FILE) as f:
                data = json.load(f)
                # basic sanitize
                enabled = bool(data.get("enabled", False))
                on_time = str(data.get("on_time", "09:00"))[:5]
                off_time = str(data.get("off_time", "21:00"))[:5]
                return {"enabled": enabled, "on_time": on_time, "off_time": off_time}
    except Exception:
        pass
    return default


def write_schedule(enabled: bool, on_time: str, off_time: str):
    data = {"enabled": bool(enabled), "on_time": on_time[:5], "off_time": off_time[:5]}
    os.makedirs(os.path.dirname(SCHEDULE_FILE), exist_ok=True)
    tmp = SCHEDULE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, SCHEDULE_FILE)


@app.get("/")
def index():
    return send_from_directory("static", "index.html")


@app.get("/api/status")
def api_status():
    return jsonify({
        "time": datetime.now().isoformat(),
        "cpu_percent": cpu_percent(),
        "cpu_temp_c": cpu_temp_c(),
        "service": service_state(),
        "clients": list_clients(),
        "bindings": read_bindings(),
        "schedule": read_schedule(),
    })


@app.post("/api/stream/start")
def api_stream_start():
    out = sh(f"sudo systemctl start {SERVICE_NAME}")
    return jsonify({"ok": True, "out": out})


@app.post("/api/stream/stop")
def api_stream_stop():
    out = sh(f"sudo systemctl stop {SERVICE_NAME}")
    return jsonify({"ok": True, "out": out})


@app.post("/api/stream/restart")
def api_stream_restart():
    out = sh(f"sudo systemctl restart {SERVICE_NAME}")
    return jsonify({"ok": True, "out": out})


@app.get("/api/bindings")
def api_get_bindings():
    return jsonify(read_bindings())


@app.post("/api/bindings")
def api_set_bindings():
    try:
        data = request.get_json(force=True) or {}
    except Exception:
        data = {}
    q3_position = data.get("q3_position")
    try:
        write_bindings(q3_position)
        return jsonify({"ok": True, "bindings": read_bindings()})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 400


@app.get("/api/schedule")
def api_get_schedule():
    return jsonify(read_schedule())


@app.post("/api/schedule")
def api_set_schedule():
    try:
        data = request.get_json(force=True) or {}
    except Exception:
        data = {}
    enabled = bool(data.get("enabled", False))
    on_time = str(data.get("on_time", "09:00"))
    off_time = str(data.get("off_time", "21:00"))
    try:
        write_schedule(enabled, on_time, off_time)
        return jsonify({"ok": True, "schedule": read_schedule()})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 400


@app.post("/api/bindings/swap")
def api_swap_bindings():
    new_pos = swap_bindings()
    return jsonify({"ok": True, "bindings": read_bindings(), "q3_position": new_pos})


@app.post("/api/display/reset")
def api_display_reset():
    res = xrandr_arrange_side_by_side()
    return jsonify(res)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=APP_PORT, debug=False)
