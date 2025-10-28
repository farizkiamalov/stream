#!/usr/bin/env python3
import json
import os
import subprocess
from datetime import datetime, time

SVC = os.environ.get("STREAM_SERVICE", "quest-dual-v19.service")
CONF = "/home/pi/stream_daemon/schedule.json"
STATE = "/home/pi/stream_daemon/scheduler_state.json"


def sh(cmd: str) -> str:
    try:
        out = subprocess.check_output(cmd, shell=True, stderr=subprocess.STDOUT, text=True, timeout=4)
        return out.strip()
    except subprocess.CalledProcessError as e:
        return e.output.strip()
    except Exception as e:
        return str(e)


def read_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default


def write_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)


def svc_active() -> bool:
    return sh(f"systemctl is-active {SVC} || true").strip() == "active"


def svc_start():
    return sh(f"sudo systemctl start {SVC}")


def svc_stop():
    return sh(f"sudo systemctl stop {SVC}")


def parse_hhmm(s: str) -> time:
    h, m = [int(x) for x in s.split(":", 1)]
    return time(hour=h, minute=m)


def now_between(t_on: time, t_off: time, now: time) -> bool:
    # handles intervals crossing midnight
    if t_on <= t_off:
        return t_on <= now < t_off
    else:
        return now >= t_on or now < t_off


def main():
    cfg = read_json(CONF, {"enabled": False, "on_time": "09:00", "off_time": "21:00"})
    if not cfg.get("enabled"):
        return 0
    try:
        t_on = parse_hhmm(cfg.get("on_time", "09:00"))
        t_off = parse_hhmm(cfg.get("off_time", "21:00"))
    except Exception:
        return 0
    now_local = datetime.now().time().replace(second=0, microsecond=0)
    want_on = now_between(t_on, t_off, now_local)
    active = svc_active()
    # debouncing: remember last action to avoid flapping
    st = read_json(STATE, {"last_action": "", "last_time": ""})
    if want_on and not active:
        write_json(STATE, {"last_action": "start", "last_time": datetime.now().isoformat(timespec='seconds')})
        svc_start()
    elif (not want_on) and active:
        write_json(STATE, {"last_action": "stop", "last_time": datetime.now().isoformat(timespec='seconds')})
        svc_stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
