#!/bin/bash
# phone-mount.sh <usb|wifi>
# Монтирует один канал (USB или Wi-Fi) в независимую точку маунта.
# USB  → ~/Phone-USB,  порт 8022, volname "Phone USB"
# Wi-Fi → ~/Phone-WiFi, порт 8023, volname "Phone WiFi"
# Идемпотентно: если уже смонтировано и ls работает — exit 0.
set -u

ADB="$HOME/Library/Android/sdk/platform-tools/adb"
RCLONE=/usr/local/bin/rclone

# ---- получить user из rclone config, fallback u0_a520 ----
PUSER=$("$RCLONE" config show phone 2>/dev/null | awk '/^\s*user\s*=/{print $3; exit}')
PUSER="${PUSER:-u0_a520}"

# ---- разобрать аргумент ----
T="${1:-}"
if [ "$T" != "usb" ] && [ "$T" != "wifi" ]; then
  echo "Использование: $0 <usb|wifi>"
  exit 1
fi

# ---- per-transport переменные ----
pick_usb()  { "$ADB" devices | awk '/\tdevice$/{print $1}' | grep -v '_adb-tls' | grep -v ':' | head -1; }
pick_wifi() {
  local ep
  ep=$("$ADB" mdns services 2>/dev/null | awk '/_adb-tls-connect._tcp/{print $NF; exit}')
  [ -n "$ep" ] && "$ADB" connect "$ep" >/dev/null 2>&1
  "$ADB" devices | awk '/\tdevice$/{print $1}' | grep -E '_adb-tls|:' | head -1
}

if [ "$T" = "usb" ]; then
  LPORT=8022
  MNT="$HOME/Phone-USB"
  VOL="Phone USB"
  LABEL="USB"
  DEV=$(pick_usb)
else
  LPORT=8023
  MNT="$HOME/Phone-WiFi"
  VOL="Phone WiFi"
  LABEL="Wi-Fi"
  DEV=$(pick_wifi)
fi

# ---- per-transport атомарный lock (защита от гонки повторных вызовов) ----
LOCK="/tmp/phonestream.${T}.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "Операция монтирования $LABEL уже идёт — подожди."
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

# ---- уже смонтировано и живо? ----
if mount | grep -q " $MNT " && ls "$MNT" >/dev/null 2>&1; then
  echo "Уже смонтировано: $MNT"
  exit 0
fi

# ---- нет устройства? ----
if [ -z "$DEV" ]; then
  echo "Нет adb-устройства для $LABEL. Включи телефон / Wireless debugging."
  exit 1
fi
echo "adb-устройство ($LABEL): $DEV"

# имя тома = модель телефона + канал (видно в Finder: напр. "SM-G975F (USB)")
MODEL=$("$ADB" -s "$DEV" shell getprop ro.product.model 2>/dev/null | tr -d '\r')
[ -n "$MODEL" ] && VOL="$MODEL ($LABEL)"

# ---- снять power-save (best-effort, экран НЕ будим) ----
"$ADB" -s "$DEV" shell "settings put global wifi_sleep_policy 2; dumpsys deviceidle disable" >/dev/null 2>&1

# ---- убить ТОЛЬКО демона этой точки + размонтировать ----
pkill -f "rclone mount.*$MNT" 2>/dev/null
sleep 0.5
if mount | grep -q " $MNT "; then
  diskutil unmount force "$MNT" >/dev/null 2>&1
fi
rmdir "$MNT" 2>/dev/null   # НЕ rm -rf — точка маунта, не данные
mkdir -p "$MNT"

# ---- проброс порта: USB tcp:8022→8022; Wi-Fi tcp:8023→8022 ----
"$ADB" -s "$DEV" forward "tcp:${LPORT}" tcp:8022 >/dev/null 2>&1

# ---- real SSH-probe через rclone connection string (таймаут 6с) ----
CONN=":sftp,host=127.0.0.1,port=${LPORT},user=${PUSER},key_file=${HOME}/.ssh/id_ed25519_phone:"
if ! "$RCLONE" lsd "$CONN" --timeout 6s --contimeout 6s --low-level-retries 1 >/dev/null 2>&1; then
  echo "sshd на телефоне не запущен или недоступен по $LABEL."
  echo "Запусти его: на телефоне тапни виджет «Start-SSHD» (Termux:Widget)"
  echo "или открой Termux и выполни ./sshd-on.sh — затем нажми Mount снова."
  exit 2
fi

# ---- монтирование через rclone connection string ----
LOG="/tmp/rclone_${T}.log"
"$RCLONE" mount \
  ":sftp,host=127.0.0.1,port=${LPORT},user=${PUSER},key_file=${HOME}/.ssh/id_ed25519_phone:storage/shared" \
  "$MNT" \
  --vfs-cache-mode writes \
  --vfs-read-chunk-streams 8 \
  --vfs-read-chunk-size 8M \
  --dir-cache-time 12h \
  --volname "$VOL" \
  --no-modtime \
  --daemon \
  --log-file "$LOG" \
  --log-level INFO

# ---- дождаться появления маунта (до ~10с) ----
for i in $(seq 1 10); do
  sleep 1
  if mount | grep -q " $MNT "; then
    echo "$LABEL" > "/tmp/phonestream.${T}.transport"
    echo "Смонтировано ($LABEL) → $MNT  [volname: $VOL]"
    exit 0
  fi
done
echo "Не удалось смонтировать $LABEL. Лог:"
tail -6 "$LOG"
exit 1
