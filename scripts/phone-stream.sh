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

# ── владение стримером: PID-файл вместо глобальных pkill ──
# Раньше уборка была `pkill -f "rclone serve http"` / `pkill -f "adb_stream.py"` —
# она сносила ЛЮБОЙ одноимённый процесс в системе, в т.ч. чужой. Теперь стример
# принадлежит запуску: PID пишется в файл, убивается только он.
PIDFILE="/tmp/phone-stream.$PORT.pid"
STREAM_PID=""

kill_stale(){   # снять стример прошлого запуска (в т.ч. брошенный браузер-фолбэком)
  [ -f "$PIDFILE" ] || return 0
  old=$(cat "$PIDFILE" 2>/dev/null)
  case "${old:-x}" in ''|*[!0-9]*) rm -f "$PIDFILE"; return 0;; esac
  if kill -0 "$old" 2>/dev/null; then
    kill "$old" 2>/dev/null; sleep 0.3; kill -9 "$old" 2>/dev/null
  fi
  rm -f "$PIDFILE"
}

# Гасим стример на ЛЮБОМ выходе, включая Ctrl+C: осиротевший rclone держит
# SFTP-сессию к телефону и не даёт радио уснуть (телефон должен спать).
# Пустой STREAM_PID = браузер-фолбэк: там стример обязан пережить скрипт,
# его снимет kill_stale следующего запуска.
cleanup(){
  [ -n "$STREAM_PID" ] || return 0
  kill "$STREAM_PID" 2>/dev/null
  rm -f "$PIDFILE"
}
trap cleanup EXIT INT TERM

# Ждём порт до 4с И проверяем, что жив ИМЕННО наш процесс: иначе при занятом
# порту (bind error) открывался бы чужой или мёртвый URL.
wait_ready(){
  for _ in $(seq 1 40); do
    kill -0 "$STREAM_PID" 2>/dev/null || {
      echo "стример не стартовал — см. /tmp/phone-stream.log"; return 1; }
    nc -z 127.0.0.1 "$PORT" 2>/dev/null && return 0
    sleep 0.1
  done
  echo "порт $PORT не открылся за 4с — см. /tmp/phone-stream.log"; return 1
}

# Открывает $url в плеере и блокируется до его закрытия (rc=0) — тогда
# вызывающий код гасит фоновый стример. Полагаемся на код возврата самого
# `open` (а не на -d /Applications/App.app — QuickTime Player, например,
# на новых macOS лежит в /System/Applications, а не в /Applications).
# Если ни один плеер не нашёлся, открывает в браузере без ожидания (rc=1) —
# стример остаётся жить до следующего запуска стрима, как раньше: обнуляем
# STREAM_PID, чтобы trap его не снёс (PID остаётся в pidfile для kill_stale).
open_player(){ url="$1"
  open -a IINA "$url" -W 2>/dev/null && return 0
  open -a "QuickTime Player" "$url" -W 2>/dev/null && return 0
  open "$url"; STREAM_PID=""; return 1; }

kill_stale   # снять стример прошлого запуска (порт 8970 один на всех)

T=$(bash "$HERE/phone-transport.sh"); KIND="${T%%|*}"; TGT="${T#*|}"
echo "транспорт: $KIND ($TGT)"

# общий запуск rclone serve http поверх SFTP (быстрый seek: одно соединение,
# без порождения процесса на каждый range → IINA стартует быстро даже на mp4 с moov в конце)
serve_rclone(){ # $1=host $2=port
  nohup "$RCLONE" serve http \
    ":sftp,host=$1,port=$2,user=$SSHUSER,key_file=$KEY,shell_type=none:$DIR" \
    --addr "127.0.0.1:$PORT" --read-only \
    --vfs-read-chunk-size 8M --sftp-chunk-size 4M \
    --buffer-size 128M --vfs-read-chunk-size-limit 128M \
    >/tmp/phone-stream.log 2>&1 &
  STREAM_PID=$!; echo "$STREAM_PID" > "$PIDFILE"
  wait_ready || return 1
  ENC=$(/usr/bin/python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$BASE")
  URL="http://127.0.0.1:$PORT/$ENC"; echo "URL: $URL"
  open_player "$URL"   # стример снимет trap cleanup при выходе
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
    nohup "$PY" "$ADB_STREAM" --serial "$TGT" --port "$PORT" "$REMOTE" >/tmp/phone-stream.log 2>&1 &
    STREAM_PID=$!; echo "$STREAM_PID" > "$PIDFILE"
    wait_ready || exit 1
    # имя файла в URL — QuickTime сниффает контейнер из расширения (err -11828 без него)
    ENC=$(/usr/bin/python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$BASE")
    URL="http://127.0.0.1:$PORT/$ENC"; echo "URL: $URL"
    open_player "$URL" ;;   # стример снимет trap cleanup при выходе
  *)
    echo "Телефон недоступен (нет USB и Wi-Fi). Проверь, что он на зарядке/в сети, sshd запущен."; exit 1 ;;
esac
