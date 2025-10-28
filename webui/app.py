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
HOSTAPD_CONF = "/etc/hostapd/hostapd.conf"
WPAS_CONF = "/etc/wpa_supplicant/wpa_supplicant-wlan1.conf"

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


# ------- Network (AP / Client) helpers -------
def read_hostapd():
    ssid = None
    passwd = None
    try:
        if os.path.exists(HOSTAPD_CONF):
            with open(HOSTAPD_CONF) as f:
                for raw in f:
                    line = raw.strip()
                    if not line or line.startswith('#'):
                        continue
                    if line.startswith('ssid='):
                        ssid = line.split('=', 1)[1]
                    elif line.startswith('wpa_passphrase='):
                        passwd = line.split('=', 1)[1]
    except Exception:
        pass
    return {"ssid": ssid or "", "password": passwd or ""}


def write_hostapd(new_ssid: str, new_password: str | None):
    if not os.path.exists(HOSTAPD_CONF):
        raise FileNotFoundError(f"{HOSTAPD_CONF} not found")
    new_ssid = (new_ssid or "").strip()
    if not (1 <= len(new_ssid) <= 32):
        raise ValueError("SSID length must be 1..32")
    if new_password is not None and len(new_password) > 0 and not (8 <= len(new_password) <= 63):
        raise ValueError("Password must be 8..63 characters or empty to keep current")

    # Read and replace lines
    with open(HOSTAPD_CONF) as f:
        lines = f.readlines()
    had_ssid = False
    had_pass = False
    for i, raw in enumerate(lines):
        line = raw.lstrip()
        if line.startswith('ssid=') and not raw.lstrip().startswith('#'):
            lines[i] = raw.split('ssid=', 1)[0] + f"ssid={new_ssid}\n"
            had_ssid = True
        elif line.startswith('wpa_passphrase=') and not raw.lstrip().startswith('#'):
            if new_password is not None and len(new_password) > 0:
                lines[i] = raw.split('wpa_passphrase=', 1)[0] + f"wpa_passphrase={new_password}\n"
            had_pass = True
    # Insert if missing
    if not had_ssid:
        lines.append(f"\nssid={new_ssid}\n")
    if not had_pass and new_password is not None and len(new_password) > 0:
        lines.append(f"wpa_passphrase={new_password}\n")
    tmp = HOSTAPD_CONF + ".tmp"
    with open(tmp, 'w') as f:
        f.writelines(lines)
    os.replace(tmp, HOSTAPD_CONF)


def read_client_wifi():
    """Return configured Wi‑Fi and current WAN info (interface, IP, gateway, SSID if wireless)."""
    configured_ssid = ""
    try:
        if os.path.exists(WPAS_CONF):
            with open(WPAS_CONF) as f:
                text = f.read()
            # naive parse first occurrence of ssid=\"...\" inside network={}
            import re
            m = re.search(r"network\s*=\s*\{[\s\S]*?ssid=\"([^\"]+)\"", text, re.MULTILINE)
            if m:
                configured_ssid = m.group(1)
    except Exception:
        pass

    # Detect WAN (default route)
    route = sh("ip route show default | head -n1 || true").strip()
    wan_dev = ""
    gw = ""
    if route:
        parts = route.split()
        # default via <gw> dev <dev>
        try:
            if "via" in parts:
                gw = parts[parts.index("via") + 1]
            if "dev" in parts:
                wan_dev = parts[parts.index("dev") + 1]
        except Exception:
            pass
    wan_ip = sh("ip -4 addr show $(ip route show default | awk '/default/ {print $5; exit}') | awk '/inet /{print $2; exit}' || true").strip()
    # If WAN is wireless, get SSID via iwgetid <dev> -r
    wan_ssid = sh("dev=$(ip route show default | awk '/default/ {print $5; exit}'); [ -n \"$dev\" ] && iwgetid $dev -r || true").strip()
    return {"configured_ssid": configured_ssid, "wan_dev": wan_dev, "wan_ip": wan_ip, "wan_gw": gw, "wan_ssid": wan_ssid}


def write_client_wifi(ssid: str, password: str):
    ssid = (ssid or "").strip()
    password = (password or "").strip()
    if not (1 <= len(ssid) <= 32):
        raise ValueError("Client SSID length must be 1..32")
    if not (8 <= len(password) <= 63):
        raise ValueError("Client password must be 8..63 characters")
    # Generate PSK via wpa_passphrase for safety
    psk_block = sh(f"wpa_passphrase {json.dumps(ssid)} {json.dumps(password)} | sed '1,2d' | sed '$d'")
    # Ensure base header exists
    base = "ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev\nupdate_config=1\ncountry=PL\n\n"
    existing = ""
    if os.path.exists(WPAS_CONF):
        try:
            with open(WPAS_CONF) as f:
                existing = f.read()
        except Exception:
            existing = ""
    # Replace our managed block
    start = "# BEGIN webui"
    end = "# END webui"
    import re
    if start in existing and end in existing:
        new = re.sub(r"# BEGIN webui[\s\S]*# END webui", f"{start}\nnetwork={{\n    ssid=\"{ssid}\"\n{psk_block}\n}}\n{end}", existing)
    else:
        if existing.strip():
            new = existing.strip() + f"\n\n{start}\nnetwork={{\n    ssid=\"{ssid}\"\n{psk_block}\n}}\n{end}\n"
        else:
            new = base + f"{start}\nnetwork={{\n    ssid=\"{ssid}\"\n{psk_block}\n}}\n{end}\n"
    # Write to /tmp first, then sudo mv into place
    import tempfile
    tmp_fd, tmp_path = tempfile.mkstemp(prefix="wpa_supplicant_", suffix=".conf", text=True)
    try:
        with os.fdopen(tmp_fd, 'w') as f:
            f.write(new)
        sh(f"sudo mv {tmp_path} {WPAS_CONF}")
        sh(f"sudo chmod 600 {WPAS_CONF}")
    except Exception:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
        raise


def network_mode():
    # If hostapd active -> AP mode. Else if associated -> client.
    ap_active = sh("systemctl is-active hostapd || true").strip() == "active"
    if ap_active:
        return "ap"
    ssid = sh("iwgetid -r || true").strip()
    if ssid:
        return "client"
    return "unknown"


def internet_ping():
    """Ping a couple of well-known hosts and return first success latency in ms."""
    for host in ("1.1.1.1", "8.8.8.8"):
        cmd = "ping -c1 -w2 -n %s 2>/dev/null | awk -F'time=' '/time=/{print $2}' | awk '{print $1}' | head -n1" % host
        out = sh(cmd)
        try:
            if out:
                ms = float(out)
                return {"ok": True, "ms": ms, "host": host}
        except Exception:
            pass
    return {"ok": False, "ms": None, "host": None}


def wan_wireless_stats(dev: str):
    """Return signal dBm and bitrate for a wireless WAN interface."""
    if not dev or not dev.startswith("wl"):
        return {"signal_dbm": None, "tx_bitrate_mbps": None, "rx_bitrate_mbps": None}
    out = sh(f"iw dev {dev} link || true")
    import re
    sig = None
    tx = None
    rx = None
    for line in out.splitlines():
        line = line.strip()
        m = re.search(r"signal:\s*(-?\d+)\s*dBm", line)
        if m:
            try:
                sig = int(m.group(1))
            except Exception:
                pass
        m = re.search(r"tx bitrate:\s*([0-9.]+)\s*MBit/s", line)
        if m:
            try:
                tx = float(m.group(1))
            except Exception:
                pass
        m = re.search(r"rx bitrate:\s*([0-9.]+)\s*MBit/s", line)
        if m:
            try:
                rx = float(m.group(1))
            except Exception:
                pass
    return {"signal_dbm": sig, "tx_bitrate_mbps": tx, "rx_bitrate_mbps": rx}


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


@app.get("/api/network/status")
def api_network_status():
    mode = network_mode()
    ap = read_hostapd()
    cli = read_client_wifi()
    # Attach WAN wireless stats if applicable
    if cli.get("wan_dev"):
        cli.update(wan_wireless_stats(cli.get("wan_dev")))
    # Do not expose plain AP password in API
    ap_masked = {"ssid": ap.get("ssid", ""), "password": "***" if ap.get("password") else ""}
    inet = internet_ping()
    return jsonify({
        "mode": mode,
        "ap": ap_masked,
        "client": cli,
        "internet": inet,
    })


@app.post("/api/network/ap")
def api_network_ap_update():
    try:
        data = request.get_json(force=True) or {}
    except Exception:
        data = {}
    ssid = (data.get("ssid") or "").strip()
    password = data.get("password")
    if password is not None:
        password = password.strip()
    try:
        write_hostapd(ssid, password)
        # Restart AP services to apply
        out1 = sh("sudo systemctl restart hostapd")
        out2 = sh("sudo systemctl restart dnsmasq || true")
        return jsonify({"ok": True, "out": out1 + "\n" + out2})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 400


@app.post("/api/network/client")
def api_network_client_update():
    try:
        data = request.get_json(force=True) or {}
    except Exception:
        data = {}
    ssid = (data.get("ssid") or "").strip()
    password = (data.get("password") or "").strip()
    apply_now = bool(data.get("apply_now", False))
    try:
        write_client_wifi(ssid, password)
        out = ""
        if apply_now:
            # Try to reconfigure wlan1 without touching AP on wlan0
            out += sh("sudo systemctl restart wpa_supplicant@wlan1 || true") + "\n"
            out += sh("sudo wpa_cli -i wlan1 reconfigure || true") + "\n"
            # Renew DHCP on wlan1 (dhclient preferred, fallback dhcpcd)
            out += sh("sudo dhclient -r wlan1 || true") + "\n"
            out += sh("sudo dhclient wlan1 || sudo dhcpcd -n wlan1 || true") + "\n"
        return jsonify({"ok": True, "configured": read_client_wifi(), "out": out.strip()})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 400


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=APP_PORT, debug=False)
