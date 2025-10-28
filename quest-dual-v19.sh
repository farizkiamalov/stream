#!/usr/bin/env bash
set -Eeuo pipefail

# ===== CONFIG =====
# Экраны
L_X=0;     L_Y=0;     L_W=1920; L_H=1080   # Q3 слева
R_X=1920;  R_Y=0;     R_W=1920; R_H=1080   # Q3S справа

# IP адреса (закреплены в dnsmasq по MAC)
Q3_IPS=("192.168.50.65")
Q3S_IPS=("192.168.50.45")

# Параметры кодека/частоты (стабильный дуал-поток для RPi4, низкая задержка)
# Советы: MAX_SIZE=1280 снижает нагрузку на CPU/GPU и Wi‑Fi, 30fps/6M/30ms — компромисс «задержка/плавность»
MAX_SIZE=1280
Q3_PORT=27190;  Q3_FPS=30;  Q3_BR="6M";  Q3_VBUF=30;   Q3_CODEC="h264"
Q3S_PORT=27191; Q3S_FPS=30; Q3S_BR="6M"; Q3S_VBUF=30;  Q3S_CODEC="h264"

# Названия окон/заставок
WIN_Q3="Q3_MON0";   SAVER_Q3="${WIN_Q3}_SAVER"
WIN_Q3S="Q3S_MON1"; SAVER_Q3S="${WIN_Q3S}_SAVER"
BG="/home/pi/background.png"

# Бинарники/логи
ADB="/usr/bin/adb"
SCRCPY="/usr/local/bin/scrcpy"
SCRCPY_SERVER="/usr/local/share/scrcpy/scrcpy-server"
FEH="$(command -v feh || true)"
LOG_DIR="/home/pi"; LOG_MAIN="$LOG_DIR/quest-dual-v19.log"

# ===== ENV/X =====
export DISPLAY=":0"
export XAUTHORITY="/home/pi/.Xauthority"
export XDG_RUNTIME_DIR="/run/user/1000"
export SDL_VIDEODRIVER="x11"
export SDL_RENDER_VSYNC="0"
export LIBGL_ALWAYS_SOFTWARE="0"
mkdir -p "$XDG_RUNTIME_DIR"; chown pi:pi "$XDG_RUNTIME_DIR" 2>/dev/null || true
command -v xset >/dev/null 2>&1 && { xset s off -dpms || true; xset s noblank || true; } >/dev/null 2>&1

log(){ echo "[$(date +'%F %T')] $*" | tee -a "$LOG_MAIN"; }
adb_devices(){ "$ADB" devices | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g'; }
adb_devices_log(){ log "[ADB] $(adb_devices)"; }
ensure_adb(){ "$ADB" start-server >/dev/null 2>&1 || true; }

# adb shell with timeout to avoid hangs
adb_sh(){
  local ser="$1"; shift
  timeout 2s "$ADB" -s "$ser" shell "$@" 2>/dev/null || true
}

# ===== BINDINGS (which device goes to which screen) =====
# Optional config file to override default placement: /home/pi/quest-bindings.env
# Example content: Q3_POSITION=left   # values: left|right ; Q3S is auto opposite
Q3_POSITION="left"
if [[ -f "/home/pi/quest-bindings.env" ]]; then
  # shellcheck disable=SC1091
  source "/home/pi/quest-bindings.env" || true
fi
if [[ "${Q3_POSITION}" == "left" ]]; then Q3S_POSITION="right"; else Q3S_POSITION="left"; fi

geom_for(){
  # $1: position (left|right)
  case "$1" in
    left)  G_X=$L_X; G_Y=$L_Y; G_W=$L_W; G_H=$L_H ;;
    right) G_X=$R_X; G_Y=$R_Y; G_W=$R_W; G_H=$R_H ;;
    *)     G_X=$L_X; G_Y=$L_Y; G_W=$L_W; G_H=$L_H ;;
  esac
}

# Вернуть 0 если экран проснут (Awake/state=ON), иначе 1
is_awake(){
  local ser="$1"
  local power
  power=$(adb_sh "$ser" "dumpsys power | grep -m1 'Display Power'")
  # Проснулся если Display Power: state=ON или mWakefulness=Awake
  if echo "$power" | grep -q 'state=ON'; then return 0; fi
  local wak
  wak=$(adb_sh "$ser" "dumpsys power | grep -m1 'mWakefulness='")
  if echo "$wak" | grep -q 'Awake'; then return 0; fi
  # OFF/Asleep/Dozing/unknown -> спит
  return 1
}

# Вернуть состояние ADB для конкретного serial (device|offline|unauthorized|<empty>)
adb_state(){
  local ser="$1"
  "$ADB" devices | awk -v d="$ser" '$1==d{print $2}'
}

# Найти подключенный через ADB serial среди заданных IPов
pick_serial_by_adb(){
  local -n arr="$1"
  local ip
  for ip in "${arr[@]}"; do
    if [[ "$(adb_state "${ip}:5555")" == "device" ]]; then
      echo "${ip}:5555"
      return 0
    fi
  done
  echo ""
  return 1
}

find_ip(){
  local -n arr="$1"
  for ip in "${arr[@]}"; do 
    ping -c1 -W1 "$ip" >/dev/null 2>&1 && { echo "$ip"; return 0; }
  done
  echo ""
  return 1
}

connect_ip(){
  local ip="$1"
  local ser="${ip}:5555"
  local tries="${2:-10}"
  local out st
  for i in $(seq 1 "$tries"); do
    st="$("$ADB" devices | awk -v d="$ser" '$1==d{print $2}')"
    [[ "$st" == "device" ]] && { echo "$ser"; return 0; }
    out="$("$ADB" connect "$ser" 2>&1 || true)"
    log "[ADB] connect#$i $ser: $out"
    sleep 0.3
  done
  echo ""
}

pids_scrcpy(){ pgrep -f "scrcpy .*--window-title=${1}" 2>/dev/null || true; }
pids_saver(){ pgrep -f "feh .* --title ${1}" 2>/dev/null || true; }
stop_saver(){ pkill -f "feh .* --title ${1}" 2>/dev/null || true; }

# Проверка что устройство не offline/disconnected (проверяем stderr лог)
scrcpy_active(){
  local win="$1"
  local err_log="$LOG_DIR/${win}_err.log"
  local out_log="$LOG_DIR/${win}.log"
  [[ ! -f "$err_log" ]] && return 0  # Нет лога — считаем активным
  
  # Проверяем последние 3 строки на offline/disconnected
  if tail -3 "$err_log" 2>/dev/null | grep -qE "(offline|disconnected)"; then
    return 1  # Найдено offline/disconnected — неактивен
  fi
  
  # Дополнительная проверка: если лог НЕ ПУСТОЙ и не обновлялся >300 секунд — считаем зависшим
  if [[ -s "$err_log" ]]; then  # -s проверяет что файл не пустой
    local log_age=$(( $(date +%s) - $(stat -c %Y "$err_log" 2>/dev/null || echo 0) ))
    if [[ $log_age -gt 300 ]]; then
      log "[WARN] ${win} stderr log stale (${log_age}s), considering inactive"
      return 1  # Старый лог с ошибками — возможно зависло
    fi
  fi
  
  return 0  # Активен
}

spawn_saver(){
  local t="$1" x="$2" y="$3" w="$4" h="$5"
  [[ -z "$FEH" || ! -f "$BG" ]] && return 0
  DISPLAY=:0 XAUTHORITY=/home/pi/.Xauthority nohup "$FEH" --no-fehbg -x --borderless \
        --image-bg black --geometry "${w}x${h}+${x}+${y}" --title "$t" "$BG" \
        >> "$LOG_DIR/${t}_saver.log" 2>&1 &
  log "[SAVER] ${t} ${w}x${h}+${x}+${y}"
}

run_scrcpy(){
  local ser="$1" x="$2" y="$3" w="$4" h="$5" t="$6" port="$7" fps="$8" br="$9" vbuf="${10}" codec="${11}" rdr="${12}"
  ADB="$ADB" SCRCPY_SERVER_PATH="$SCRCPY_SERVER" \
  "$SCRCPY" \
    --serial="$ser" \
    --no-audio --no-control \
    --render-driver="$rdr" \
    --video-codec="$codec" \
    --max-fps="$fps" --video-bit-rate="$br" --max-size="$MAX_SIZE" \
    --video-buffer="$vbuf" \
    --port="$port" \
    --window-borderless --window-title="$t" \
    --window-x="$x" --window-y="$y" --window-width="$w" --window-height="$h" \
    >> "$LOG_DIR/${t}.log" 2>> "$LOG_DIR/${t}_err.log" &
}

spawn_scrcpy(){
  local ser="$1" x="$2" y="$3" w="$4" h="$5" t="$6" port="$7" fps="$8" br="$9" vbuf="${10}" codec="${11}"
  local err_log="$LOG_DIR/${t}_err.log"
  
  stop_saver "$t"
  # Убиваем ВСЕ старые процессы этого окна (может быть несколько дублей)
  pkill -9 -f "scrcpy .*--window-title=${t}" 2>/dev/null || true
  pkill -9 -f "scrcpy .*--port=${port}" 2>/dev/null || true
  sleep 0.5
  # Очищаем stderr лог чтобы детектор offline не срабатывал на старые записи
  > "$err_log"
  log "[SCRCPY] start ${ser} -> ${t} (software) 1080p@${fps} buf=${vbuf} br=${br} at ${w}x${h}+${x}+${y}"
  run_scrcpy "$ser" "$x" "$y" "$w" "$h" "$t" "$port" "$fps" "$br" "$vbuf" "$codec" "software"
}

# ===== MAIN =====
log "[BOOT] quest-dual-v19 start (Q3=${Q3_POSITION}, Q3S=${Q3S_POSITION})"; ensure_adb
IP_Q3="$(find_ip Q3_IPS || true)";   SER_Q3=""
IP_Q3S="$(find_ip Q3S_IPS || true)"; SER_Q3S=""
# Сначала пробуем использовать уже подключенные через ADB устройства
SER_Q3="$(pick_serial_by_adb Q3_IPS || true)"
SER_Q3S="$(pick_serial_by_adb Q3S_IPS || true)"
# Если не нашли через ADB — пробуем ping+connect
if [[ -z "$SER_Q3" && -n "$IP_Q3" ]]; then SER_Q3="$(connect_ip "$IP_Q3" 12)" || true; fi
if [[ -z "$SER_Q3S" && -n "$IP_Q3S" ]]; then SER_Q3S="$(connect_ip "$IP_Q3S" 12)" || true; fi
log "[STATE] Q3=${SER_Q3:-none} ; Q3S=${SER_Q3S:-none}"; adb_devices_log

# Счетчики неактивности для детектора CPU

# первичный запуск / заставки (учитываем привязку экранов и состояние дисплея)
if [[ -n "$SER_Q3" ]]; then
  if is_awake "$SER_Q3"; then
    geom_for "$Q3_POSITION"; spawn_scrcpy "$SER_Q3"  $G_X $G_Y $G_W $G_H "$WIN_Q3"  $Q3_PORT  $Q3_FPS  $Q3_BR  $Q3_VBUF  $Q3_CODEC
  else
    : > "$LOG_DIR/${WIN_Q3}_sleep"; log "[SLEEP] Q3 initial state: sleep/off"
    geom_for "$Q3_POSITION"; spawn_saver "$SAVER_Q3"  $G_X $G_Y $G_W $G_H
  fi
else
  geom_for "$Q3_POSITION"; spawn_saver "$SAVER_Q3"  $G_X $G_Y $G_W $G_H
fi
if [[ -n "$SER_Q3S" ]]; then
  if is_awake "$SER_Q3S"; then
    geom_for "$Q3S_POSITION"; spawn_scrcpy "$SER_Q3S" $G_X $G_Y $G_W $G_H "$WIN_Q3S" $Q3S_PORT $Q3S_FPS $Q3S_BR $Q3S_VBUF $Q3S_CODEC
  else
    : > "$LOG_DIR/${WIN_Q3S}_sleep"; log "[SLEEP] Q3S initial state: sleep/off"
    geom_for "$Q3S_POSITION"; spawn_saver "$SAVER_Q3S" $G_X $G_Y $G_W $G_H
  fi
else
  geom_for "$Q3S_POSITION"; spawn_saver "$SAVER_Q3S" $G_X $G_Y $G_W $G_H
fi

# вотчер — гарнитуры могут быть не одновременно
SLEEP_CHECK_COUNTER=0
while true; do
  sleep 2
  SLEEP_CHECK_COUNTER=$((SLEEP_CHECK_COUNTER + 1))
  
  # Каждые 4 секунды проверяем состояние экрана через logcat (быстрее реакция)
  if [[ $SLEEP_CHECK_COUNTER -ge 1 ]]; then
    SLEEP_CHECK_COUNTER=0
    
    # Сначала проверим текущее состояние ADB, чтобы не блокироваться на shell при offline
    # Если устройство не в статусе "device", помечаем сон и переводим в режим переподключения
    if [[ -n "$SER_Q3" ]]; then
      st_q3="$(adb_state "$SER_Q3")"
      if [[ "$st_q3" != "device" || -z "$st_q3" ]]; then
        [[ -f "$LOG_DIR/${WIN_Q3}_sleep" ]] || log "[STATE] Q3 adb=${st_q3:-none} -> mark sleep & reconnect"
        : > "$LOG_DIR/${WIN_Q3}_sleep"
        if pgrep -f "scrcpy .*--window-title=${WIN_Q3}" >/dev/null; then
          log "[SLEEP] Q3 sleeping (adb $st_q3), killing scrcpy"
          pkill -9 -f "scrcpy .*--window-title=${WIN_Q3}" 2>/dev/null || true
        fi
        SER_Q3=""
      fi
    fi
    if [[ -n "$SER_Q3S" ]]; then
      st_q3s="$(adb_state "$SER_Q3S")"
      if [[ "$st_q3s" != "device" || -z "$st_q3s" ]]; then
        [[ -f "$LOG_DIR/${WIN_Q3S}_sleep" ]] || log "[STATE] Q3S adb=${st_q3s:-none} -> mark sleep & reconnect"
        : > "$LOG_DIR/${WIN_Q3S}_sleep"
        if pgrep -f "scrcpy .*--window-title=${WIN_Q3S}" >/dev/null; then
          log "[SLEEP] Q3S sleeping (adb $st_q3s), killing scrcpy"
          pkill -9 -f "scrcpy .*--window-title=${WIN_Q3S}" 2>/dev/null || true
        fi
        SER_Q3S=""
      fi
    fi
    
    # Q3 - проверка событий экрана
    if [[ -n "$SER_Q3" ]]; then
      # logcat читаем только если adb=device, иначе пропускаем (уже помечено как sleep выше)
  last_event=$(adb_sh "$SER_Q3" "logcat -d -s PowerManagerService:I -t 20 | grep -E 'Waking up|Going to sleep' | tail -1")
      if echo "$last_event" | grep -q "Going to sleep"; then
        # Очки заснули
        if [[ ! -f "$LOG_DIR/${WIN_Q3}_sleep" ]]; then
          touch "$LOG_DIR/${WIN_Q3}_sleep"
          log "[SLEEP] Q3 screen off detected"
        fi
      elif echo "$last_event" | grep -q "Waking up"; then
        # Очки проснулись
        if [[ -f "$LOG_DIR/${WIN_Q3}_sleep" ]]; then
          rm -f "$LOG_DIR/${WIN_Q3}_sleep"
          log "[WAKE] Q3 screen on detected"
        fi
      else
        # Нет явного события — решаем по dumpsys power, без "assumed" эвристики
  power_q3=$(adb_sh "$SER_Q3" "dumpsys power | grep -E 'mWakefulness=|Display Power' | head -n 4")
        if echo "$power_q3" | grep -qE 'Awake|state=ON'; then
          if [[ -f "$LOG_DIR/${WIN_Q3}_sleep" ]]; then
            rm -f "$LOG_DIR/${WIN_Q3}_sleep"
            log "[WAKE] Q3 dumpsys indicates awake, clearing sleep"
          fi
        elif echo "$power_q3" | grep -qE 'Asleep|Dozing|state=OFF'; then
          if [[ ! -f "$LOG_DIR/${WIN_Q3}_sleep" ]]; then
            : > "$LOG_DIR/${WIN_Q3}_sleep"
            log "[SLEEP] Q3 dumpsys indicates sleep, setting saver"
          fi
        fi
      fi
    fi
    
    # Q3S - проверка событий экрана
    if [[ -n "$SER_Q3S" ]]; then
  last_event=$(adb_sh "$SER_Q3S" "logcat -d -s PowerManagerService:I -t 20 | grep -E 'Waking up|Going to sleep' | tail -1")
      if echo "$last_event" | grep -q "Going to sleep"; then
        # Очки заснули
        if [[ ! -f "$LOG_DIR/${WIN_Q3S}_sleep" ]]; then
          touch "$LOG_DIR/${WIN_Q3S}_sleep"
          log "[SLEEP] Q3S screen off detected"
        fi
      elif echo "$last_event" | grep -q "Waking up"; then
        # Очки проснулись
        if [[ -f "$LOG_DIR/${WIN_Q3S}_sleep" ]]; then
          rm -f "$LOG_DIR/${WIN_Q3S}_sleep"
          log "[WAKE] Q3S screen on detected"
        fi
      else
        # Нет явного события — решаем по dumpsys power, без "assumed" эвристики
  power_q3s=$(adb_sh "$SER_Q3S" "dumpsys power | grep -E 'mWakefulness=|Display Power' | head -n 4")
        if echo "$power_q3s" | grep -qE 'Awake|state=ON'; then
          if [[ -f "$LOG_DIR/${WIN_Q3S}_sleep" ]]; then
            rm -f "$LOG_DIR/${WIN_Q3S}_sleep"
            log "[WAKE] Q3S dumpsys indicates awake, clearing sleep"
          fi
        elif echo "$power_q3s" | grep -qE 'Asleep|Dozing|state=OFF'; then
          if [[ ! -f "$LOG_DIR/${WIN_Q3S}_sleep" ]]; then
            : > "$LOG_DIR/${WIN_Q3S}_sleep"
            log "[SLEEP] Q3S dumpsys indicates sleep, setting saver"
          fi
        fi
      fi
    fi
  fi
  
  # ========== Q3 ==========
  if [[ -n "$SER_Q3" ]]; then
    # Очки подключены, проверяем спят ли
    if [[ -f "$LOG_DIR/${WIN_Q3}_sleep" ]]; then
      # Очки спят - убиваем scrcpy если запущен, показываем заставку
      if pgrep -f "scrcpy .*--window-title=${WIN_Q3}" >/dev/null; then
        log "[SLEEP] Q3 sleeping, killing scrcpy"
        pkill -9 -f "scrcpy .*--window-title=${WIN_Q3}" 2>/dev/null || true
      fi
      if [[ -z "$(pids_saver "$SAVER_Q3")" ]]; then geom_for "$Q3_POSITION"; spawn_saver "$SAVER_Q3" $G_X $G_Y $G_W $G_H; fi
    else
      # Очки НЕ спят - проверяем работает ли scrcpy
      if ! pgrep -f "scrcpy .*--window-title=${WIN_Q3}" >/dev/null; then
        # scrcpy не запущен - запускаем
        geom_for "$Q3_POSITION"; spawn_scrcpy "$SER_Q3" $G_X $G_Y $G_W $G_H "$WIN_Q3" $Q3_PORT $Q3_FPS $Q3_BR $Q3_VBUF $Q3_CODEC
      else
        # scrcpy работает - проверим активность потока, иначе переключим на заставку
        if ! scrcpy_active "$WIN_Q3"; then
          : > "$LOG_DIR/${WIN_Q3}_sleep"
          log "[WARN] Q3 stream inactive, switching to saver"
          pkill -9 -f "scrcpy .*--window-title=${WIN_Q3}" 2>/dev/null || true
          geom_for "$Q3_POSITION"; spawn_saver "$SAVER_Q3" $G_X $G_Y $G_W $G_H
        else
          # scrcpy активен - убираем заставку
          stop_saver "$SAVER_Q3"
        fi
      fi
    fi
  else
    # Очки не подключены, пробуем найти и подключиться
    SER_Q3="$(pick_serial_by_adb Q3_IPS || true)"
    if [[ -z "$SER_Q3" ]]; then
      [[ -n "$IP_Q3" ]] || IP_Q3="$(find_ip Q3_IPS || true)"
      if [[ -n "$IP_Q3" ]]; then
        # Нашли IP, подключаемся
        SER_Q3="$(connect_ip "$IP_Q3" 3)" || true
      fi
    fi
    if [[ -n "$SER_Q3" ]]; then
      # Считаем, что при успешном переподключении очки проснулись (logcat мог быть недоступен)
      if [[ -f "$LOG_DIR/${WIN_Q3}_sleep" ]]; then
        rm -f "$LOG_DIR/${WIN_Q3}_sleep"
        log "[WAKE] Q3 reconnected, assuming awake"
      fi
      geom_for "$Q3_POSITION"; spawn_scrcpy "$SER_Q3" $G_X $G_Y $G_W $G_H "$WIN_Q3" $Q3_PORT $Q3_FPS $Q3_BR $Q3_VBUF $Q3_CODEC
    else
      # Не нашли IP/ADB, показываем заставку
      if [[ -z "$(pids_saver "$SAVER_Q3")" ]]; then geom_for "$Q3_POSITION"; spawn_saver "$SAVER_Q3" $G_X $G_Y $G_W $G_H; fi
    fi
  fi
  
  # ========== Q3S ==========
  if [[ -n "$SER_Q3S" ]]; then
    # Очки подключены, проверяем спят ли
    if [[ -f "$LOG_DIR/${WIN_Q3S}_sleep" ]]; then
      # Очки спят - убиваем scrcpy если запущен, показываем заставку
      if pgrep -f "scrcpy .*--window-title=${WIN_Q3S}" >/dev/null; then
        log "[SLEEP] Q3S sleeping, killing scrcpy"
        pkill -9 -f "scrcpy .*--window-title=${WIN_Q3S}" 2>/dev/null || true
      fi
      if [[ -z "$(pids_saver "$SAVER_Q3S")" ]]; then geom_for "$Q3S_POSITION"; spawn_saver "$SAVER_Q3S" $G_X $G_Y $G_W $G_H; fi
    else
      # Очки НЕ спят - проверяем работает ли scrcpy
      if ! pgrep -f "scrcpy .*--window-title=${WIN_Q3S}" >/dev/null; then
        # scrcpy не запущен - запускаем
        geom_for "$Q3S_POSITION"; spawn_scrcpy "$SER_Q3S" $G_X $G_Y $G_W $G_H "$WIN_Q3S" $Q3S_PORT $Q3S_FPS $Q3S_BR $Q3S_VBUF $Q3S_CODEC
      else
        # scrcpy работает - проверим активность потока, иначе переключим на заставку
        if ! scrcpy_active "$WIN_Q3S"; then
          : > "$LOG_DIR/${WIN_Q3S}_sleep"
          log "[WARN] Q3S stream inactive, switching to saver"
          pkill -9 -f "scrcpy .*--window-title=${WIN_Q3S}" 2>/dev/null || true
          geom_for "$Q3S_POSITION"; spawn_saver "$SAVER_Q3S" $G_X $G_Y $G_W $G_H
        else
          # scrcpy активен - убираем заставку
          stop_saver "$SAVER_Q3S"
        fi
      fi
    fi
  else
    # Очки не подключены, пробуем найти и подключиться
    SER_Q3S="$(pick_serial_by_adb Q3S_IPS || true)"
    if [[ -z "$SER_Q3S" ]]; then
      [[ -n "$IP_Q3S" ]] || IP_Q3S="$(find_ip Q3S_IPS || true)"
      if [[ -n "$IP_Q3S" ]]; then
        # Нашли IP, подключаемся
        SER_Q3S="$(connect_ip "$IP_Q3S" 3)" || true
      fi
    fi
    if [[ -n "$SER_Q3S" ]]; then
      # Считаем WAKE при переподключении (буфер мог очиститься)
      if [[ -f "$LOG_DIR/${WIN_Q3S}_sleep" ]]; then
        rm -f "$LOG_DIR/${WIN_Q3S}_sleep"
        log "[WAKE] Q3S reconnected, assuming awake"
      fi
      geom_for "$Q3S_POSITION"; spawn_scrcpy "$SER_Q3S" $G_X $G_Y $G_W $G_H "$WIN_Q3S" $Q3S_PORT $Q3S_FPS $Q3S_BR $Q3S_VBUF $Q3S_CODEC
    else
      # Не нашли IP/ADB, показываем заставку
      if [[ -z "$(pids_saver "$SAVER_Q3S")" ]]; then geom_for "$Q3S_POSITION"; spawn_saver "$SAVER_Q3S" $G_X $G_Y $G_W $G_H; fi
    fi
  fi
done
