# VR Stream (Raspberry Pi) — backup

This repository contains the configuration and scripts to run dual scrcpy streaming for Quest headsets over Wireless ADB on a Raspberry Pi, plus a small Web UI and helper services.

## Contents

- quest-dual-v19.sh — main watchdog for sleep/wake and scrcpy windows
- config/
  - quest-bindings.env — screen binding (Q3_POSITION=left|right)
  - schedule.json — stream schedule configuration (enabled, on_time, off_time)
- scripts/
  - display_watcher.sh — xrandr hotplug watcher (auto arrange + stream restart)
  - stream_scheduler.py — minute scheduler to start/stop the stream
  - backup_sd_image.sh — optional full SD backup script
- systemd/ — unit files
  - quest-dual-v19.service
  - webui.service
  - display-watcher.service
  - stream-scheduler.service
  - stream-scheduler.timer
- webui/
  - app.py, static/, requirements.txt

## Deploy

1) Copy systemd units and reload:

- sudo cp -f systemd/*.service systemd/*.timer /etc/systemd/system/
- sudo systemctl daemon-reload

2) Enable services:

- sudo systemctl enable --now quest-dual-v19.service
- sudo systemctl enable --now webui.service
- sudo systemctl enable --now display-watcher.service
- sudo systemctl enable --now stream-scheduler.timer

3) Web UI:

- Runs on port 8080
- Endpoints: / (panel), /api/status, /api/stream/(start|stop|restart), /api/bindings, /api/schedule

## Notes

- Edit config/quest-bindings.env to swap screens (Q3 left/right). Use Web UI too.
- Edit config/schedule.json or via Web UI.
- Background image for saver expected at /home/pi/background.png.

## License

This backup mirrors your deployed configuration; verify licenses of included upstream components (scrcpy, etc.).