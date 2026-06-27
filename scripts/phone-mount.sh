#!/bin/bash
# phone-mount.sh <usb|wifi>
# Монтирует один канал в независимую точку.
#   USB  → ~/Phone-USB   : adb forward tcp:8022→sshd(8022), host=127.0.0.1
#   Wi-Fi → ~/Phone-WiFi : ПРЯМОЙ SSH на IP телефона:8022 (БЕЗ adb, БЕЗ Wireless Debugging)
# Идемпотентно: если уже смонтировано и ls работает — exit 0.
set -u

# shellcheck source=config.sh
source "$(cd "$(dirname "$0")" && pwd)/config.sh"

PUSER=$("$RCLONE" config show phone 2>/dev/null | awk '/^\s*user\s*=/{print $3; exit}')
PUSER="${PUSER:-$PHONE_SSH_USER}"
KEY="$PHONE_SSH_KEY"

T="${1:-}"
[ "$T" = "usb" ] || [ "$T" = "wifi" ] || { echo "Использование: $0 <usb|wifi>"; exit 1; }

# ---- определить канал: HOST/PORT/точка ----
if [ "$T" = "usb" ]; then
  MNT="$HOME/Phone-USB"; LABEL="USB"; HOST="127.0.0.1"; RPORT="$PHONE_SSH_PORT"
  DEV=$(pick_usb)
else
  MNT="$HOME/Phone-WiFi"; LABEL="Wi-Fi"; RPORT="$PHONE_SSH_PORT"
  # IP из кэша (пишется keepalive/transport, пока телефон на USB); fallback — спросить adb
  HOST=$(phone_ip)
  if [ -z "$HOST" ]; then
    u=$(pick_usb)
    if [ -n "$u" ]; then
      ip_raw=$(_to 8 "$ADB" -s "$u" shell "ip -f inet addr show wlan0 2>/dev/null" 2>/dev/null \
               | awk '/inet /{print $2}' | cut -d/ -f1 | tr -d '\r' | head -1)
      [ -n "$ip_raw" ] && write_ip_cache "$ip_raw" && HOST="$ip_raw"
    fi
  fi
fi

# ---- атомарный lock ----
LOCK="/tmp/phonestream.${T}.lock"
mkdir "$LOCK" 2>/dev/null || { echo "Монтирование $LABEL уже идёт — подожди."; exit 0; }
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

# ---- уже смонтировано? ----
if mount | grep -q " $MNT " && ls "$MNT" >/dev/null 2>&1; then
  echo "Уже смонтировано: $MNT"; exit 0
fi

# ---- подготовка канала ----
if [ "$T" = "usb" ]; then
  [ -n "${DEV:-}" ] || { echo "Нет USB-устройства. Воткни кабель / включи USB-debugging."; exit 1; }
  echo "USB-устройство: $DEV"
  _to 8 "$ADB" -s "$DEV" shell "settings put global wifi_sleep_policy 2; dumpsys deviceidle disable" >/dev/null 2>&1
  _to 8 "$ADB" -s "$DEV" forward "tcp:${RPORT}" tcp:8022 >/dev/null 2>&1
  MODEL=$(_to 8 "$ADB" -s "$DEV" shell getprop ro.product.model 2>/dev/null | tr -d '\r')
else
  [ -n "$HOST" ] || { echo "Не знаю IP телефона. Подключи раз по USB (закэширую IP) или впиши в $PHONE_IP_CACHE."; exit 1; }
  echo "Wi-Fi прямой SSH: $HOST:$RPORT (Wireless Debugging НЕ нужен)"
  _to 4 ping -c1 -t2 "$HOST" >/dev/null 2>&1 || { echo "Телефон $HOST не пингуется (не в сети / спит)."; exit 1; }
  MODEL=$(ssh -i "$KEY" -p "$RPORT" \
    -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=6 \
    "$PUSER@$HOST" "getprop ro.product.model" 2>/dev/null | tr -d '\r')
fi
VOL="${MODEL:+$MODEL ($LABEL)}"; VOL="${VOL:-Phone $LABEL}"

# ---- очистить старую точку ----
pkill -f "rclone mount.*$MNT" 2>/dev/null; sleep 0.5
mount | grep -q " $MNT " && _to 12 diskutil unmount force "$MNT" >/dev/null 2>&1
rmdir "$MNT" 2>/dev/null   # НЕ rm -rf — это точка маунта, не данные
mkdir -p "$MNT"

# ---- SSH-probe (таймаут 6с) ----
CONN=":sftp,host=${HOST},port=${RPORT},user=${PUSER},key_file=${KEY},shell_type=none:"
if ! _to 12 "$RCLONE" lsd "$CONN" --timeout 6s --contimeout 6s --low-level-retries 1 >/dev/null 2>&1; then
  echo "sshd на телефоне недоступен по $LABEL ($HOST:$RPORT)."
  echo "Запусти sshd: виджет «Start-SSHD» (Termux:Widget) или ./sshd-on.sh в Termux, затем Mount снова."
  exit 2
fi

# ---- монтирование ----
LOG="/tmp/rclone_${T}.log"
"$RCLONE" mount \
  ":sftp,host=${HOST},port=${RPORT},user=${PUSER},key_file=${KEY},shell_type=none:storage/shared" \
  "$MNT" \
  --vfs-cache-mode writes --vfs-read-chunk-streams 8 --vfs-read-chunk-size 8M \
  --sftp-chunk-size 4M --buffer-size 128M --vfs-read-chunk-size-limit 128M \
  --dir-cache-time 24h --attr-timeout 1m --no-checksum --vfs-fast-fingerprint \
  --daemon-timeout 15s --sftp-concurrency 64 --sftp-skip-links --poll-interval 0 \
  --network-mode --noappledouble --noapplexattr --volname "$VOL" --no-modtime \
  --daemon --log-file "$LOG" --log-level INFO

# ---- дождаться маунта ----
for i in $(seq 1 10); do
  sleep 1
  if mount | grep -q " $MNT "; then
    echo "$LABEL" > "/tmp/phonestream.${T}.transport"
    # поднять проактивный watchdog (single-instance) — страж от D-state-зависаний
    nohup bash "$(cd "$(dirname "$0")" && pwd)/phone-watchdog.sh" >/dev/null 2>&1 & disown
    echo "Смонтировано ($LABEL) → $MNT  [volname: $VOL]"; exit 0
  fi
done
echo "Не удалось смонтировать $LABEL. Лог:"; tail -6 "$LOG"; exit 1
