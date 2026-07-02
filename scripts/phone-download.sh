#!/bin/bash
# Скачать веб-URL ПРЯМО на телефон (rclone copyurl по SFTP), минуя диск Mac.
# Авто-канал: USB (через adb forward) → Wi-Fi SSH. Цель по умолчанию: /sdcard/Download.
# Использование: phone-download.sh "https://...файл"
set -u
[ $# -ge 1 ] || { echo "usage: phone-download.sh URL"; exit 2; }
URL="$1"
case "$URL" in
  http://*|https://*) : ;;
  *) echo "Только http/https-ссылки (защита от file:// и пр.)."; exit 2 ;;
esac
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
source "$HERE/config.sh"
DEST_DIR="${PHONE_UPLOAD_DIR:-/sdcard/Download}"

T=$(_to 15 bash "$HERE/phone-transport.sh"); KIND="${T%%|*}"; TGT="${T#*|}"
case "$KIND" in
  usb)
    _to 8 "$ADB" -s "$TGT" forward "tcp:${PHONE_SSH_PORT}" tcp:8022 >/dev/null 2>&1
    HOST=127.0.0.1 ;;
  wifi-ssh)
    HOST="${TGT%%:*}" ;;
  *)
    echo "Нет канала для записи (нужен USB или Wi-Fi SSH). Сейчас: $KIND"; exit 1 ;;
esac
echo "Канал: $KIND → $HOST:$PHONE_SSH_PORT  •  цель: $DEST_DIR"

CONN=":sftp,host=${HOST},port=${PHONE_SSH_PORT},user=${PHONE_SSH_USER},key_file=${PHONE_SSH_KEY},shell_type=none:${DEST_DIR}"
"$RCLONE" copyurl "$URL" "$CONN" --auto-filename --sftp-chunk-size 4M \
  --contimeout 10s --timeout 30s --low-level-retries 3 -q 2>&1 | tail -3
rc=${PIPESTATUS[0]}
[ "$rc" -eq 0 ] && echo "✅ Скачано на телефон → $DEST_DIR" || echo "❌ Не удалось (проверь ссылку и канал)"
exit "$rc"
