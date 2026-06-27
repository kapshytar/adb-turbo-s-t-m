#!/bin/bash
# Размонтирует все тома телефона.
for mnt in "$HOME/Phone" "$HOME/Phone-SD" "$HOME/Phone-System" "$HOME/droid"; do
  if mount | grep -q " $mnt "; then
    umount "$mnt" 2>/dev/null || diskutil unmount force "$mnt" 2>/dev/null
    if mount | grep -q " $mnt "; then echo "НЕ размонтировано: $mnt"; else echo "Размонтировано: $mnt"; fi
  fi
done
pkill -f "adbfs .*/Phone" 2>/dev/null
pkill -f "adbfs .*/droid" 2>/dev/null

# вернуть телефон в спокойный режим (батарея/нагрев), раз больше не работаем
"$HOME/PhoneAsExtStorage/adbfs-rootless/phone-restrict.sh" restore 2>/dev/null || true
echo "Готово."
