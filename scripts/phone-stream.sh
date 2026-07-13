#!/bin/bash
# ЕДИНЫЙ СТРИМЕР с авто-выбором канала. Открывает видео БЕЗ выкачки (HTTP Range) в IINA.
#   USB          → rclone serve http поверх sshd телефона через adb forward (быстрый seek;
#                  требует Termux sshd — без него USB-стрим не работает)
#   Wi-Fi-SSH    → rclone serve http поверх прямого SFTP (range, надёжно)
#   Wi-Fi-adb    → adb_stream.py (range поверх adb exec-out; fallback без sshd)
# Использование: phone-stream.sh "/sdcard/DCIM/Media presence/x.mp4"
set -u
[ $# -ge 1 ] || { echo "usage: phone-stream.sh REMOTE_PATH"; exit 2; }
REMOTE="$1"
DIR=$(dirname "$REMOTE"); BASE=$(basename "$REMOTE")
PORT="${STREAM_PORT:-8970}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=config.sh
source "$HERE/config.sh"

# adb_stream.py stdlib-only → системного python3 достаточно, venv не нужен
PY=/usr/bin/python3
ADB_STREAM="$HERE/adb_stream.py"
[ -f "$ADB_STREAM" ] || ADB_STREAM="$HOME/PhoneAsExtStorage/adb_stream.py"
SSHUSER="$PHONE_SSH_USER"
KEY="$PHONE_SSH_KEY"

# Открывает $url в плеере и блокируется до его закрытия (rc=0) — тогда
# вызывающий код гасит фоновый стример. Полагаемся на код возврата самого
# `open` (а не на -d /Applications/App.app — QuickTime Player, например,
# на новых macOS лежит в /System/Applications, а не в /Applications).
# Если ни один плеер не нашёлся, открывает в браузере без ожидания (rc=1) —
# стример остаётся жить до следующего запуска стрима, как раньше.
open_player(){ url="$1"
  open -a IINA "$url" -W 2>/dev/null && return 0
  open -a "QuickTime Player" "$url" -W 2>/dev/null && return 0
  open "$url"; return 1; }

T=$(bash "$HERE/phone-transport.sh"); KIND="${T%%|*}"; TGT="${T#*|}"
echo "транспорт: $KIND ($TGT)"

# общий запуск rclone serve http поверх SFTP (быстрый seek: одно соединение,
# без порождения процесса на каждый range → IINA стартует быстро даже на mp4 с moov в конце)
serve_rclone(){ # $1=host $2=port
  pkill -f "rclone serve http" 2>/dev/null; pkill -f "adb_stream.py" 2>/dev/null; sleep 0.3
  nohup "$RCLONE" serve http \
    ":sftp,host=$1,port=$2,user=$SSHUSER,key_file=$KEY,shell_type=none:$DIR" \
    --addr "127.0.0.1:$PORT" --read-only \
    --vfs-read-chunk-size 8M --sftp-chunk-size 4M \
    --buffer-size 128M --vfs-read-chunk-size-limit 128M \
    >/tmp/phone-stream.log 2>&1 & disown
  # poll вместо sleep 2 — ждём до 4с (40 × 100мс)
  for i in $(seq 1 40); do
    nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    sleep 0.1
  done
  ENC=$(/usr/bin/python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$BASE")
  URL="http://127.0.0.1:$PORT/$ENC"; echo "URL: $URL"
  if open_player "$URL"; then
    pkill -f "rclone serve http" 2>/dev/null
    return 0
  fi
  return 1
}

case "$KIND" in
  usb)
    # форвард на sshd телефона и стрим через rclone (быстрый seek, как у Wi-Fi)
    _to 8 "$ADB" -s "$TGT" forward tcp:8022 tcp:8022 >/dev/null 2>&1
    if serve_rclone 127.0.0.1 8022; then
      # НЕ снимать forward, если ~/Phone-USB сейчас смонтирован через
      # phone-mount.sh — он держит tcp:8022 (тот же порт, см. config.sh).
      mount | grep -q " $HOME/Phone-USB " || "$ADB" -s "$TGT" forward --remove tcp:8022 >/dev/null 2>&1
    fi ;;
  wifi-ssh)
    serve_rclone "${TGT%%:*}" "${TGT##*:}" ;;
  wifi-adb)
    # нет прямого SSH — fallback на adb_stream поверх adb-WD
    pkill -f "adb_stream.py" 2>/dev/null; sleep 0.3
    nohup "$PY" "$ADB_STREAM" --serial "$TGT" --port "$PORT" "$REMOTE" >/tmp/phone-stream.log 2>&1 & disown
    # poll вместо sleep 2
    for i in $(seq 1 40); do
      nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
      sleep 0.1
    done
    # имя файла в URL — QuickTime сниффает контейнер из расширения (err -11828 без него)
    ENC=$(/usr/bin/python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$BASE")
    URL="http://127.0.0.1:$PORT/$ENC"; echo "URL: $URL"
    if open_player "$URL"; then
      pkill -f "adb_stream.py" 2>/dev/null
    fi ;;
  *)
    echo "Телефон недоступен (нет USB и Wi-Fi). Проверь, что он на зарядке/в сети, sshd запущен."; exit 1 ;;
esac
