#!/bin/bash
# ЕДИНЫЙ СТРИМЕР с авто-выбором канала. Открывает видео БЕЗ выкачки (HTTP Range) в IINA.
#   USB / Wi-Fi-adb  → adb_stream.py (range поверх adb exec-out)
#   Wi-Fi-SSH        → rclone serve http поверх прямого SFTP (range, надёжно)
# Использование: phone-stream.sh "/sdcard/DCIM/Media presence/x.mp4"
set -u
[ $# -ge 1 ] || { echo "usage: phone-stream.sh REMOTE_PATH"; exit 2; }
REMOTE="$1"
DIR=$(dirname "$REMOTE"); BASE=$(basename "$REMOTE")
PORT="${STREAM_PORT:-8970}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
PY="$HOME/PhoneAsExtStorage/ADBFileExplorer/venv/bin/python3"
RCLONE="/usr/local/bin/rclone"
KEY="$HOME/.ssh/id_ed25519_phone"
SSHUSER="${PHONE_SSH_USER:-u0_a520}"

open_player(){ url="$1"
  if [ -d /Applications/IINA.app ]; then open -a IINA "$url"
  elif [ -d "/Applications/QuickTime Player.app" ]; then open -a "QuickTime Player" "$url"
  else open "$url"; fi; }

T=$(bash "$HERE/phone-transport.sh"); KIND="${T%%|*}"; TGT="${T#*|}"
echo "транспорт: $KIND ($TGT)"

case "$KIND" in
  usb|wifi-adb)
    pkill -f "adb_stream.py" 2>/dev/null; sleep 0.3
    nohup "$PY" "$HOME/PhoneAsExtStorage/adb_stream.py" --port "$PORT" "$REMOTE" >/tmp/phone-stream.log 2>&1 & disown
    sleep 2
    URL="http://127.0.0.1:$PORT/"
    echo "URL: $URL"; open_player "$URL" ;;
  wifi-ssh)
    IP="${TGT%%:*}"; SP="${TGT##*:}"
    pkill -f "rclone serve http" 2>/dev/null; sleep 0.3
    nohup "$RCLONE" serve http \
      ":sftp,host=$IP,port=$SP,user=$SSHUSER,key_file=$KEY,shell_type=none:$DIR" \
      --addr "127.0.0.1:$PORT" --read-only >/tmp/phone-stream.log 2>&1 & disown
    sleep 2
    ENC=$(/usr/bin/python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$BASE")
    URL="http://127.0.0.1:$PORT/$ENC"
    echo "URL: $URL"; open_player "$URL" ;;
  *)
    echo "❌ Телефон недоступен (нет USB и Wi-Fi). Проверь, что он на зарядке/в сети, sshd запущен."; exit 1 ;;
esac
