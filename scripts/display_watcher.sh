#!/usr/bin/env bash
# Be resilient: do not exit on individual command errors
set -Euo pipefail

LOG="/home/pi/display-watcher.log"
DISPLAY=":0"
XAUTHORITY="/home/pi/.Xauthority"
export DISPLAY XAUTHORITY

log(){ echo "[$(date +'%F %T')] $*" | tee -a "$LOG"; }
shh(){ bash -lc "$1" 2>&1 | sed 's/^/  /' | tee -a "$LOG" >/dev/null; return 0; }

arrange_outputs(){
  # Gather connected outputs (names only)
  local q; q=$(xrandr --query || true)
  local outs=()
  while read -r name state _rest; do
    if [[ "$state" == "connected" ]]; then outs+=("$name"); fi
  done < <(echo "$q" | awk '/ connected/{print $1, $2}')
  if [[ ${#outs[@]} -eq 0 ]]; then
    log "[XRANDR] no connected outputs"
    return 1
  fi
  log "[XRANDR] connected: ${outs[*]}"
  # Side-by-side without turning outputs off (reduces flicker)
  local last=""
  for o in "${outs[@]}"; do
    if [[ -z "$last" ]]; then
      shh "xrandr --output $o --auto --primary"
      last="$o"
    else
      shh "xrandr --output $o --auto --right-of $last"
      last="$o"
    fi
  done
  return 0
}

restart_stream_if_active(){
  local st
  st=$(systemctl is-active quest-dual-v19.service || true)
  if [[ "$st" == "active" ]]; then
    log "[STREAM] restart quest-dual-v19.service"
    shh "sudo systemctl restart quest-dual-v19.service"
  else
    log "[STREAM] service not active ($st), skip restart"
  fi
}

sig_now(){
  # Only list of connected outputs (names), sorted; ignore geometry to avoid self-triggering
  local q
  q=$(xrandr --query 2>/dev/null || true)
  echo "$q" | awk '/ connected/{print $1}' | sort | tr '\n' ';'
}

COOLDOWN_SECS=10
last_action=0
log "[BOOT] display-watcher start"
last_sig=""
unchanged=0
while true; do
  sleep 3
  cur_sig=$(sig_now || true)
  if [[ -z "$cur_sig" ]]; then
    continue
  fi
  if [[ "$cur_sig" == "$last_sig" ]]; then
    ((unchanged++))
    continue
  fi
  # changed; require it to be stable for 2 consecutive checks
  sleep 1
  cur2=$(sig_now || true)
  if [[ "$cur2" != "$cur_sig" ]]; then
    # still bouncing
    last_sig="$cur2"
    unchanged=0
    continue
  fi
  # Cooldown to avoid loops
  now=$(date +%s)
  if (( now - last_action < COOLDOWN_SECS )); then
    last_sig="$cur_sig"
    unchanged=0
    log "[EVENT] change detected but in cooldown (skip)"
    continue
  fi
  log "[EVENT] topology change: '$last_sig' -> '$cur_sig'"
  last_sig="$cur_sig"
  unchanged=0
  if arrange_outputs; then
    sleep 1
    restart_stream_if_active
    last_action=$(date +%s)
  fi
done
