#!/usr/bin/env bash
# uninstall.sh — снятие LaunchAgent для adbfs-phone

set -euo pipefail

PLIST_NAME="com.kapshytar.adbfs-phone.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_NAME"
MOUNTPOINT="$HOME/Phone"
UID_VAL="$(id -u)"

echo "=== Удаление adbfs LaunchAgent ==="

# Выгрузить агент
if launchctl list "$PLIST_NAME" &>/dev/null 2>&1; then
    launchctl bootout "gui/$UID_VAL" "$PLIST_DST" 2>/dev/null \
        || launchctl bootout "gui/$UID_VAL/$PLIST_NAME" 2>/dev/null \
        || true
    echo "✓ Агент выгружен"
else
    echo "Агент не был загружен, пропускаем bootout"
fi

# Удалить plist из LaunchAgents
if [ -f "$PLIST_DST" ]; then
    rm "$PLIST_DST"
    echo "✓ Удалён: $PLIST_DST"
fi

# Отмонтировать если смонтировано
if mount | grep -q " $MOUNTPOINT "; then
    echo "Отмонтируем $MOUNTPOINT..."
    diskutil unmount force "$MOUNTPOINT" 2>/dev/null \
        || umount "$MOUNTPOINT" 2>/dev/null \
        || true
    echo "✓ $MOUNTPOINT отмонтирован"
fi

echo ""
echo "Готово. Логи остались в /tmp/adbfs-phone.{out,err}.log"
