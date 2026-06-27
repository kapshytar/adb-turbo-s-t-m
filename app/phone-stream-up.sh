#!/bin/bash
# No-copy стрим-маунт телефона в ~/PhoneStream (rclone + sftp + Termux sshd).
# Транспорт: USB (adb forward) приоритет, иначе Wi-Fi через mDNS. Идемпотентно + самовосстановление.
set -u
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
RCLONE=/usr/local/bin/rclone
MNT="$HOME/PhoneStream"
PORT=8022

# уже смонтировано и живо?
if mount | grep -q " $MNT " && ls "$MNT" >/dev/null 2>&1; then
  exit 0
fi

# 1) выбрать adb-устройство.
#    По умолчанию Wi-Fi-ПЕРВЫМ (стабильно для стоящего сервера на настенной зарядке;
#    не зависит от питания/тока USB-порта Mac). USB — только если форсить (для турбо-передач):
#    запуск "phone-stream-up.sh usb" или FORCE_USB=1.
pick_usb()  { "$ADB" devices | awk '/\tdevice$/{print $1}' | grep -v '_adb-tls' | grep -v ':' | head -1; }
pick_wifi() {
  local ep
  ep=$("$ADB" mdns services 2>/dev/null | awk '/_adb-tls-connect._tcp/{print $NF; exit}')
  [ -n "$ep" ] && "$ADB" connect "$ep" >/dev/null 2>&1
  "$ADB" devices | awk '/\tdevice$/{print $1}' | grep -E '_adb-tls|:' | head -1
}
TRANSPORT="${1:-auto}"
[ "${FORCE_USB:-}" = "1" ] && TRANSPORT="usb"
case "$TRANSPORT" in
  usb)  DEV=$(pick_usb);  [ -z "$DEV" ] && DEV=$(pick_wifi); MODE="USB (турбо)" ;;
  wifi) DEV=$(pick_wifi); [ -z "$DEV" ] && DEV=$(pick_usb);  MODE="Wi-Fi" ;;
  *)    DEV=$(pick_usb);  if [ -n "$DEV" ]; then MODE="USB (авто)"; else DEV=$(pick_wifi); MODE="Wi-Fi (авто)"; fi ;;
esac
[ -z "$DEV" ] && { echo "Нет adb-устройства (ни Wi-Fi, ни USB). Включи телефон/Wireless debugging."; exit 1; }
echo "adb-устройство: $DEV  [$MODE]"

# Снять power-saving на время работы как со стораджем (best-effort; экран НЕ будим).
# Прим.: радио-power-save Wi-Fi на нерутованном A12 с тёмным экраном полностью так не убить.
"$ADB" -s "$DEV" shell "settings put global wifi_sleep_policy 2; settings put global wifi_scan_throttle_enabled 0; dumpsys deviceidle disable" >/dev/null 2>&1

# 2) проброс порта sshd
"$ADB" -s "$DEV" forward tcp:$PORT tcp:$PORT >/dev/null 2>&1

# 3) sshd на телефоне отвечает?
if ! nc -z -G 3 127.0.0.1 $PORT 2>/dev/null; then
  echo "sshd на телефоне не отвечает. Запусти в Termux: sshd"
  exit 1
fi

# 4) (пере)монтировать
if mount | grep -q " $MNT "; then diskutil unmount force "$MNT" >/dev/null 2>&1; fi
rm -rf "$MNT"; mkdir -p "$MNT"
"$RCLONE" mount phone:storage/shared "$MNT" \
  --vfs-cache-mode writes --vfs-read-chunk-streams 8 --vfs-read-chunk-size 8M \
  --dir-cache-time 12h --volname Phone-Stream --no-modtime \
  --log-file /tmp/rclone_mount.log --log-level INFO --daemon
# активный канал (для индикации в трее)
case "$DEV" in *:*|*_adb-tls*) ACTIVE="Wi-Fi" ;; *) ACTIVE="USB" ;; esac
for i in $(seq 1 10); do
  sleep 1
  if mount | grep -q " $MNT "; then
    echo "$ACTIVE" > /tmp/phonestream.transport
    echo "Смонтировано (no-copy, многопоток) через $ACTIVE: $MNT"; exit 0
  fi
done
echo "Не удалось смонтировать. Лог:"; tail -4 /tmp/rclone_mount.log
exit 1
