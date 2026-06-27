#!/bin/bash
# Размонтирует no-copy стрим (~/PhoneStream) и убирает проброс порта.
MNT="$HOME/PhoneStream"
umount "$MNT" 2>/dev/null || diskutil unmount force "$MNT" 2>/dev/null
rm -f /tmp/phonestream.transport 2>/dev/null
~/Library/Android/sdk/platform-tools/adb forward --remove tcp:8022 2>/dev/null
if mount | grep -q " $MNT "; then echo "НЕ размонтировано: $MNT"; else echo "Размонтировано: $MNT"; fi
