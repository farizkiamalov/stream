#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
log(){ echo "[$(date +%F %T)] $*"; }

log "Exporting configs and units into $ROOT"
mkdir -p "$ROOT/systemd" "$ROOT/scripts" "$ROOT/config" "$ROOT/webui"
cp -f /home/pi/quest-dual-v19.sh "$ROOT/" || true
cp -f /home/pi/quest-bindings.env "$ROOT/config/" || true
cp -f /home/pi/stream_daemon/schedule.json "$ROOT/config/" || true
cp -f /home/pi/scripts/display_watcher.sh "$ROOT/scripts/" || true
cp -f /home/pi/scripts/stream_scheduler.py "$ROOT/scripts/" || true
cp -f /home/pi/scripts/backup_sd_image.sh "$ROOT/scripts/" || true
cp -f /etc/systemd/system/quest-dual-v19.service "$ROOT/systemd/" || true
cp -f /etc/systemd/system/webui.service "$ROOT/systemd/" || true
cp -f /etc/systemd/system/display-watcher.service "$ROOT/systemd/" || true
cp -f /etc/systemd/system/stream-scheduler.service "$ROOT/systemd/" || true
cp -f /etc/systemd/system/stream-scheduler.timer "$ROOT/systemd/" || true
rsync -a --delete --exclude ".venv" --exclude "__pycache__" --exclude "*.pyc" \
  /home/pi/webui/app.py /home/pi/webui/requirements.txt /home/pi/webui/static/ "$ROOT/webui/" || true
log "Done"