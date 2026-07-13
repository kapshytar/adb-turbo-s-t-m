#!/bin/bash
# No-copy стрим-маунт телефона в ~/PhoneStream (rclone + sftp + Termux sshd).
# Транспорт: USB (adb forward) приоритет, иначе Wi-Fi через mDNS. Идемпотентно + самовосстановление.
set -u

# shellcheck source=config.sh
source "$(cd "$(dirname "$0")" && pwd)/config.sh"

# ADB/RCLONE приходят из config.sh (там же Apple-Silicon-поиск rclone и env-overrides)
MNT="$HOME/PhoneStream"
PORT=8022

# single-instance lock (атомарный mkdir) — защита от гонки/множественных вызовов из трея,
# чтобы повторные нажатия Mount не плодили rclone-демонов.
LOCK="/tmp/phonestream.up.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "Операция монтирования уже идёт — подожди."; exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

# уже смонтировано и живо?
if mount | grep -q " $MNT " && _to 3 ls "$MNT" >/dev/null 2>&1; then
  exit 0
fi

# НЕ смонтировано корректно → подчистить зависшие rclone-демоны и битый маунт,
# иначе повторные запуски плодят демонов (приводило к зависанию Finder).
pkill -f "rclone mount phone:" 2>/dev/null
sleep 1
if mount | grep -q " $MNT "; then diskutil unmount force "$MNT" >/dev/null 2>&1; fi
rmdir "$MNT" 2>/dev/null   # ВАЖНО: rmdir, НЕ rm -rf — на смонтированной точке rm -rf удалял бы файлы телефона

# 1) выбрать adb-устройство.
#    По умолчанию Wi-Fi-ПЕРВЫМ (стабильно для стоящего сервера на настенной зарядке;
#    не зависит от питания/тока USB-порта Mac). USB — только если форсить (для турбо-передач):
#    запуск "phone-stream-up.sh usb" или FORCE_USB=1.
#    pick_usb/pick_wifi — из config.sh (уже source-нут выше); model-агностичны.
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
_to 8 "$ADB" -s "$DEV" shell "settings put global wifi_sleep_policy 2; settings put global wifi_scan_throttle_enabled 0; dumpsys deviceidle disable" >/dev/null 2>&1

# 2) проброс порта sshd
_to 8 "$ADB" -s "$DEV" forward tcp:$PORT tcp:$PORT >/dev/null 2>&1

# 3) sshd на телефоне отвечает?
if ! nc -z -G 3 127.0.0.1 $PORT 2>/dev/null; then
  echo "Проброс порта недоступен (adb forward). Переподключи телефон."
  exit 1
fi
# nc видит локальный adb-forward даже если sshd на телефоне мёртв — поэтому проверяем РЕАЛЬНЫЙ SSH:
if ! _to 15 "$RCLONE" lsd phone: --timeout 6s --contimeout 6s --low-level-retries 1 >/dev/null 2>&1; then
  echo "sshd на телефоне не запущен. Запусти его: на телефоне тапни виджет «Start-SSHD» (Termux:Widget) или открой Termux и выполни ./sshd-on.sh — затем нажми Mount снова."
  exit 2
fi

# 4) (пере)монтировать
if mount | grep -q " $MNT "; then diskutil unmount force "$MNT" >/dev/null 2>&1; fi
rmdir "$MNT" 2>/dev/null; mkdir -p "$MNT"
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
