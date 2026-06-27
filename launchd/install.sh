#!/usr/bin/env bash
# install.sh — установка LaunchAgent для adbfs-phone

set -euo pipefail

PLIST_NAME="com.kapshytar.adbfs-phone.plist"
PLIST_SRC="$(cd "$(dirname "$0")" && pwd)/$PLIST_NAME"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_NAME"
UID_VAL="$(id -u)"

echo "=== Установка adbfs LaunchAgent ==="

# Сделать обёртку исполняемой
chmod +x "$(dirname "$0")/adbfs-launchd-run.sh"
echo "✓ Скрипт adbfs-launchd-run.sh → executable"

# Скопировать plist
mkdir -p "$HOME/Library/LaunchAgents"
cp "$PLIST_SRC" "$PLIST_DST"
echo "✓ Скопирован: $PLIST_DST"

# Проверить синтаксис plist
if command -v plutil &>/dev/null; then
    plutil -lint "$PLIST_DST" && echo "✓ plist прошёл lint"
fi

# Загрузить агент (современный синтаксис macOS 10.15+)
if launchctl list "$PLIST_NAME" &>/dev/null 2>&1; then
    echo "Агент уже загружен, перезагружаем..."
    launchctl bootout "gui/$UID_VAL/$PLIST_NAME" 2>/dev/null || true
    sleep 1
fi

launchctl bootstrap "gui/$UID_VAL" "$PLIST_DST"
echo "✓ Агент загружен: com.kapshytar.adbfs-phone"

echo ""
echo "Проверить статус:  launchctl list com.kapshytar.adbfs-phone"
echo "Логи stdout:       tail -f /tmp/adbfs-phone.out.log"
echo "Логи stderr:       tail -f /tmp/adbfs-phone.err.log"
echo "Точка монтирования: $HOME/Phone"
