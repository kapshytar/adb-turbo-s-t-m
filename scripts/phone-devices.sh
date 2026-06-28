#!/bin/bash
# phone-devices.sh — перечислить подключённые adb-устройства.
# Вывод: по одной строке на устройство, TAB-разделители:
#   SERIAL<TAB>MODEL<TAB>KIND<TAB>ACTIVE
# KIND  = USB   если строка содержит маркер usb: в `adb devices -l`
#         Wi-Fi  иначе
# ACTIVE = * если серийник совпадает с active_serial(), иначе пусто
#
# Используется PhoneStream.app для подменю выбора устройства (adb-уровень).
# SSH/Wi-Fi-операции (mount-wifi, stream, upload, download) идут на SSH-сервер
# по закэшированному IP — этот скрипт их НЕ затрагивает.

source "$(cd "$(dirname "$0")" && pwd)/config.sh"

# Получаем активный серийник один раз
ACTIVE=$(active_serial)

# adb devices -l: строки вида «SERIAL  device  ...usb:...» или «IP:PORT  device  ...»
"$ADB" devices -l 2>/dev/null | while IFS= read -r line; do
  # пропускаем заголовок и пустые строки
  [[ "$line" == "List of devices"* ]] && continue
  [[ -z "$line" ]] && continue

  # только строки с «device» в статусе (не unauthorized, offline)
  echo "$line" | grep -qw 'device' || continue

  serial=$(echo "$line" | awk '{print $1}')
  [ -z "$serial" ] && continue

  # KIND: если строка содержит маркер usb: — USB, иначе Wi-Fi
  if echo "$line" | grep -q 'usb:'; then
    kind="USB"
  else
    kind="Wi-Fi"
  fi

  # MODEL: через _to с таймаутом 6 сек; если пусто — серийник
  model=$(_to 6 "$ADB" -s "$serial" shell getprop ro.product.model 2>/dev/null \
    | tr -d '\r' | tr -d '\n')
  [ -z "$model" ] && model="$serial"

  # ACTIVE
  if [ "$serial" = "$ACTIVE" ]; then
    active_mark="*"
  else
    active_mark=""
  fi

  printf '%s\t%s\t%s\t%s\n' "$serial" "$model" "$kind" "$active_mark"
done
