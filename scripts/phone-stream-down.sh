#!/bin/bash
# Размонтирует no-copy стрим (~/PhoneStream) и убирает проброс порта.

# shellcheck source=config.sh
source "$(cd "$(dirname "$0")" && pwd)/config.sh"

MNT="$HOME/PhoneStream"
_to 8 umount "$MNT" 2>/dev/null || _to 12 diskutil unmount force "$MNT" 2>/dev/null
rm -f /tmp/phonestream.transport 2>/dev/null
_to 8 "$ADB" forward --remove tcp:8022 2>/dev/null
if mount | grep -q " $MNT "; then echo "НЕ размонтировано: $MNT"; else echo "Размонтировано: $MNT"; fi
