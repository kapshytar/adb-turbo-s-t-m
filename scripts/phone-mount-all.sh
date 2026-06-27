#!/bin/bash
# phone-mount-all.sh
# Монтирует USB если USB-устройство доступно И Wi-Fi если Wi-Fi-устройство доступно.
# Оба монтируются параллельно (запуск в фоне), затем ждём оба.
# Выход: 0 если хотя бы один смонтирован, 1 если ни одного.
set -u

ADB="$HOME/Library/Android/sdk/platform-tools/adb"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

pick_usb()  { "$ADB" devices -l | awk '/ device / && /usb:/ {print $1}' | head -1; }
pick_wifi() {
  local ep ip
  ip=$("$ADB" devices -l | awk '/ device / && !/usb:/ {print $1}' | grep ':' | head -1)
  [ -n "$ip" ] && { echo "$ip"; return; }
  ep=$("$ADB" mdns services 2>/dev/null | awk '/_adb-tls-connect._tcp/{print $NF; exit}')
  [ -n "$ep" ] && "$ADB" connect "$ep" >/dev/null 2>&1
  "$ADB" devices -l | awk '/ device / && !/usb:/ {print $1}' | grep ':' | head -1
}

USB_DEV=$(pick_usb)
WIFI_DEV=$(pick_wifi)

if [ -z "$USB_DEV" ] && [ -z "$WIFI_DEV" ]; then
  echo "Нет ни одного adb-устройства (ни USB, ни Wi-Fi). Включи телефон / Wireless debugging."
  exit 1
fi

PIDS=()
LAUNCHED=()

if [ -n "$USB_DEV" ]; then
  echo "USB-устройство найдено: $USB_DEV — запускаю монтирование USB…"
  bash "$SCRIPTS_DIR/phone-mount.sh" usb &
  PIDS+=($!)
  LAUNCHED+=(usb)
else
  echo "USB-устройство не найдено — пропускаю USB."
fi

if [ -n "$WIFI_DEV" ]; then
  echo "Wi-Fi-устройство найдено: $WIFI_DEV — запускаю монтирование Wi-Fi…"
  bash "$SCRIPTS_DIR/phone-mount.sh" wifi &
  PIDS+=($!)
  LAUNCHED+=(wifi)
else
  echo "Wi-Fi-устройство не найдено — пропускаю Wi-Fi."
fi

# дождаться обоих фоновых процессов
RC_USB=0
RC_WIFI=0
IDX=0
for PID in "${PIDS[@]}"; do
  wait "$PID"
  CODE=$?
  T="${LAUNCHED[$IDX]}"
  if [ "$T" = "usb" ]; then RC_USB=$CODE; fi
  if [ "$T" = "wifi" ]; then RC_WIFI=$CODE; fi
  IDX=$((IDX + 1))
done

# итог
MOUNTED=0
for T in "${LAUNCHED[@]}"; do
  if [ "$T" = "usb" ] && [ "$RC_USB" -eq 0 ]; then
    echo "USB том: OK (~/Phone-USB)"
    MOUNTED=$((MOUNTED + 1))
  elif [ "$T" = "usb" ]; then
    echo "USB том: ОШИБКА (код $RC_USB)"
  fi
  if [ "$T" = "wifi" ] && [ "$RC_WIFI" -eq 0 ]; then
    echo "Wi-Fi том: OK (~/Phone-WiFi)"
    MOUNTED=$((MOUNTED + 1))
  elif [ "$T" = "wifi" ]; then
    echo "Wi-Fi том: ОШИБКА (код $RC_WIFI)"
  fi
done

[ "$MOUNTED" -gt 0 ] && exit 0 || exit 1
