#!/bin/bash
# phone-unmount.sh <usb|wifi|all>
# Размонтирует указанный канал (или оба при "all"):
#   diskutil unmount force, pkill демона, adb forward --remove, rmdir точки,
#   rm transport-файла.
set -u

ADB="$HOME/Library/Android/sdk/platform-tools/adb"

unmount_one() {
  local T="$1"
  local MNT LPORT

  if [ "$T" = "usb" ]; then
    MNT="$HOME/Phone-USB"
    LPORT=8022
  elif [ "$T" = "wifi" ]; then
    MNT="$HOME/Phone-WiFi"
    LPORT=8023
  else
    echo "Неизвестный транспорт: $T (usb|wifi|all)"
    return 1
  fi

  echo "Размонтирование $T ($MNT)…"

  # убить rclone-демон этой точки
  pkill -f "rclone mount.*$MNT" 2>/dev/null
  sleep 0.5

  # размонтировать том
  if mount | grep -q " $MNT "; then
    diskutil unmount force "$MNT" >/dev/null 2>&1 && echo "  unmount OK" || echo "  unmount: уже отключено"
  fi

  # снять adb forward (best-effort — устройство может быть уже отключено)
  "$ADB" forward --remove "tcp:${LPORT}" 2>/dev/null || true

  # убрать точку маунта (rmdir — только если пуста)
  rmdir "$MNT" 2>/dev/null || true

  # убрать transport-файл
  rm -f "/tmp/phonestream.${T}.transport"

  echo "  $T размонтирован."
}

ARG="${1:-}"
case "$ARG" in
  usb)  unmount_one usb ;;
  wifi) unmount_one wifi ;;
  all)
    unmount_one usb
    unmount_one wifi
    ;;
  *)
    echo "Использование: $0 <usb|wifi|all>"
    exit 1
    ;;
esac
