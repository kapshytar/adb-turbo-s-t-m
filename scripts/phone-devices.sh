#!/bin/bash
# phone-devices.sh — перечислить подключённые adb-устройства (БЫСТРО, без getprop).
# Модель берём прямо из `adb devices -l` (поле model:...), поэтому мгновенно и без
# поедания stdin. Вывод: SERIAL<TAB>MODEL<TAB>KIND<TAB>ACTIVE (TAB-разделители).
#   KIND   = USB если в строке есть маркер usb:, иначе Wi-Fi
#   ACTIVE = * у активного. Активный = выбранная МОДЕЛЬ (active_model); если не выбрана —
#            ДЕФОЛТ первое USB-устройство (иначе первое), чтобы галочка/каналы работали сразу.
set -u
source "$(cd "$(dirname "$0")" && pwd)/config.sh"

ACTIVE_MODEL=$(active_model)

serials=(); models=(); kinds=()
while IFS= read -r line; do
  case "$line" in "List of devices"*|"") continue;; esac
  echo "$line" | grep -qw 'device' || continue
  serial=$(awk '{print $1}' <<<"$line"); [ -z "$serial" ] && continue
  model=$(echo "$line" | grep -oE 'model:[^ ]+' | cut -d: -f2 | tr '_' '-')
  [ -z "$model" ] && model="$serial"
  if echo "$line" | grep -q 'usb:'; then kind="USB"; else kind="Wi-Fi"; fi
  serials+=("$serial"); models+=("$model"); kinds+=("$kind")
done < <(_to 8 "$ADB" devices -l 2>/dev/null)

[ "${#serials[@]}" -eq 0 ] && exit 0

# индекс активного — по МОДЕЛИ (первое устройство выбранной модели через find_serial),
# иначе первое USB (find_serial usb ""), иначе первое подключённое.
active_idx=-1
if [ -n "$ACTIVE_MODEL" ]; then
  active_serial_hit=$(find_serial any "$ACTIVE_MODEL")
  if [ -n "$active_serial_hit" ]; then
    for i in "${!serials[@]}"; do [ "${serials[$i]}" = "$active_serial_hit" ] && { active_idx=$i; break; }; done
  fi
fi
if [ "$active_idx" -lt 0 ]; then
  active_serial_hit=$(find_serial usb "")
  if [ -n "$active_serial_hit" ]; then
    for i in "${!serials[@]}"; do [ "${serials[$i]}" = "$active_serial_hit" ] && { active_idx=$i; break; }; done
  fi
fi
[ "$active_idx" -lt 0 ] && active_idx=0

for i in "${!serials[@]}"; do
  mark=""; [ "$i" -eq "$active_idx" ] && mark="*"
  printf '%s\t%s\t%s\t%s\n' "${serials[$i]}" "${models[$i]}" "${kinds[$i]}" "$mark"
done
