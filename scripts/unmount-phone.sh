#!/bin/bash
# FALLBACK (2026-07-02): adbfs-стек — рабочий фолбек (вся ФС телефона, ~/Phone*). Без watchdog, но с таймаутами.
# Актуальный стек: phone-mount.sh / phone-unmount.sh (rclone).
# Размонтирует все тома телефона.

# shellcheck source=config.sh
source "$(cd "$(dirname "$0")" && pwd)/config.sh"

for mnt in "$HOME/Phone" "$HOME/Phone-SD" "$HOME/Phone-System" "$HOME/droid"; do
  if mount | grep -q " $mnt "; then
    _to 12 umount "$mnt" 2>/dev/null || _to 12 diskutil unmount force "$mnt" 2>/dev/null
    if mount | grep -q " $mnt "; then echo "НЕ размонтировано: $mnt"; else echo "Размонтировано: $mnt"; fi
  fi
done
pkill -f "adbfs .*/Phone" 2>/dev/null
pkill -f "adbfs .*/droid" 2>/dev/null

# вернуть телефон в спокойный режим (батарея/нагрев), раз больше не работаем
"$HOME/PhoneAsExtStorage/adbfs-rootless/phone-restrict.sh" restore 2>/dev/null || true
echo "Готово."
