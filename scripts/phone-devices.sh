#!/bin/bash
# phone-devices.sh — перечислить подключённые adb-устройства.
# Вывод: по строке на устройство, TAB-разделители: SERIAL<TAB>MODEL<TAB>KIND<TAB>ACTIVE
#   KIND   = USB если в `adb devices -l` есть маркер usb:, иначе Wi-Fi
#   ACTIVE = * у активного. Активный = выбранный (active_serial); если не выбран —
#            ДЕФОЛТ первое USB-устройство (иначе первое в списке), чтобы галочка и
#            привязка каналов в трее работали сразу.
# Влияет на adb-уровень (USB-mount, scrcpy, cache). SSH/Wi-Fi-операции идут на сервер.
set -u
source "$(cd "$(dirname "$0")" && pwd)/config.sh"

ACTIVE_MODEL=$(active_model)

serials=(); models=(); kinds=()
while IFS= read -r line; do
  [[ "$line" == "List of devices"* ]] && continue
  [[ -z "$line" ]] && continue
  echo "$line" | grep -qw 'device' || continue
  serial=$(echo "$line" | awk '{print $1}'); [ -z "$serial" ] && continue
  if echo "$line" | grep -q 'usb:'; then kind="USB"; else kind="Wi-Fi"; fi
  model=$(_to 6 "$ADB" -s "$serial" shell getprop ro.product.model </dev/null 2>/dev/null | tr -d '\r' | tr -d '\n')
  [ -z "$model" ] && model="$serial"
  serials+=("$serial"); models+=("$model"); kinds+=("$kind")
done < <("$ADB" devices -l 2>/dev/null)

[ "${#serials[@]}" -eq 0 ] && exit 0

# индекс активного — по МОДЕЛИ (первое устройство выбранной модели)
active_idx=-1
if [ -n "$ACTIVE_MODEL" ]; then
  for i in "${!models[@]}"; do [ "${models[$i]}" = "$ACTIVE_MODEL" ] && { active_idx=$i; break; }; done
fi
if [ "$active_idx" -lt 0 ]; then
  for i in "${!serials[@]}"; do [ "${kinds[$i]}" = "USB" ] && { active_idx=$i; break; }; done
  [ "$active_idx" -lt 0 ] && active_idx=0
fi

for i in "${!serials[@]}"; do
  mark=""; [ "$i" -eq "$active_idx" ] && mark="*"
  printf '%s\t%s\t%s\t%s\n' "${serials[$i]}" "${models[$i]}" "${kinds[$i]}" "$mark"
done
