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

# ── SSH-достижимые телефоны, которых НЕТ в adb с живым статусом ──
# adb-over-5555 часто уходит в offline, mDNS на macOS пуст → телефон-сервер пропадал
# из пикера, хотя жив по SSH. Берём модели из персональных кэшей IP и проверяем sshd:8022.
shopt -s nullglob 2>/dev/null
for f in "$HOME"/.phone_ip_*; do
  case "$f" in *.tmp) continue;; esac
  m="${f##*/.phone_ip_}"; [ -n "$m" ] || continue
  dup=0; for x in "${models[@]:-}"; do [ "$x" = "$m" ] && { dup=1; break; }; done
  [ "$dup" = 1 ] && continue
  ip=$(cat "$f" 2>/dev/null | tr -d '\r'); [ -n "$ip" ] || continue
  _to 2 nc -z -G2 "$ip" 8022 >/dev/null 2>&1 || continue   # только если sshd реально жив
  serials+=("ssh:$ip"); models+=("$m"); kinds+=("Wi-Fi")
done
shopt -u nullglob 2>/dev/null

[ "${#serials[@]}" -eq 0 ] && exit 0

# индекс активного — по ИМЕНИ МОДЕЛИ (работает и для adb-, и для SSH-строк),
# иначе первое USB, иначе первое в списке.
active_idx=-1
if [ -n "$ACTIVE_MODEL" ]; then
  for i in "${!models[@]}"; do [ "${models[$i]}" = "$ACTIVE_MODEL" ] && { active_idx=$i; break; }; done
fi
if [ "$active_idx" -lt 0 ]; then
  for i in "${!kinds[@]}"; do [ "${kinds[$i]}" = "USB" ] && { active_idx=$i; break; }; done
  [ "$active_idx" -lt 0 ] && active_idx=0
fi

for i in "${!serials[@]}"; do
  mark=""; [ "$i" -eq "$active_idx" ] && mark="*"
  printf '%s\t%s\t%s\t%s\n' "${serials[$i]}" "${models[$i]}" "${kinds[$i]}" "$mark"
done
