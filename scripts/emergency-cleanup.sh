#!/bin/bash
# Аварийная чистка: снять зависшие маунты/демоны и перезапустить Finder.
pkill -9 -f rclone 2>/dev/null
pkill -9 -f adbfs 2>/dev/null
pkill -9 -f phone-stream 2>/dev/null
sleep 1
diskutil unmount force "$HOME/PhoneStream" 2>/dev/null
diskutil unmount force /Volumes/PhoneStream 2>/dev/null
umount -f "$HOME/PhoneStream" 2>/dev/null
rmdir "$HOME/PhoneStream" 2>/dev/null   # rmdir, НЕ rm -rf (безопасно: на смонтированной точке просто не сработает)
rm -f /tmp/phonestream.transport 2>/dev/null
# adb мог зависнуть на отвалившемся Wi-Fi — перезапустить сервер
"$HOME/Library/Android/sdk/platform-tools/adb" kill-server 2>/dev/null
killall Finder 2>/dev/null
echo "cleanup done"
