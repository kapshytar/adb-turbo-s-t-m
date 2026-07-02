#!/bin/bash
# Быстрая МНОГОПОТОЧНАЯ заливка на телефон (rclone copy по SFTP, --transfers 8).
# Авто-канал: USB (через adb forward) → Wi-Fi SSH. Цель по умолчанию: /sdcard/Download.
# Использование: phone-upload.sh LOCAL_PATH [LOCAL_PATH ...]
set -u
[ $# -ge 1 ] || { echo "usage: phone-upload.sh LOCAL_PATH [...]"; exit 2; }
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
    echo "Нет быстрого канала (нужен USB или Wi-Fi SSH). Сейчас: $KIND"; exit 1 ;;
esac
echo "Канал: $KIND → $HOST:$PHONE_SSH_PORT  •  цель: $DEST_DIR"

CONN=":sftp,host=${HOST},port=${PHONE_SSH_PORT},user=${PHONE_SSH_USER},key_file=${PHONE_SSH_KEY},shell_type=none:"
RC=0
for src in "$@"; do
  [ -e "$src" ] || { echo "пропуск (нет): $src"; continue; }
  if [ -d "$src" ]; then DST="${CONN}${DEST_DIR}/$(basename "$src")"; else DST="${CONN}${DEST_DIR}"; fi
  echo "→ $(basename "$src")"
  "$RCLONE" copy "$src" "$DST" \
    --transfers 8 --multi-thread-streams 4 --multi-thread-cutoff 50M \
    --sftp-chunk-size 4M --sftp-concurrency 64 --ignore-checksum \
    --contimeout 10s --timeout 30s --low-level-retries 3 \
    --stats 2s --stats-one-line 2>&1 | tail -3
  rc=${PIPESTATUS[0]}; [ "$rc" -ne 0 ] && RC=$rc
done
[ "$RC" -eq 0 ] && echo "✅ Готово → $DEST_DIR" || echo "⚠️ Завершено с ошибками (код $RC)"
exit "$RC"
