#!/bin/bash
# Снимает ограничения телефона на время работы (lift) и возвращает покой (restore).
# Идея: когда телефон простаивает — пусть спит/экономит; ограничения снимаем только пока работаем.
#   ./phone-restrict.sh lift      -> снять ограничения (сохранив текущие значения)
#   ./phone-restrict.sh restore   -> вернуть как было (или дефолты)
set -u
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
BK="$HOME/PhoneAsExtStorage/adbfs-rootless/.phone_restrict_backup"

SERIAL=$("$ADB" devices | awk '$2=="device"{print $1}' | grep -v ':' | head -1)
[ -z "$SERIAL" ] && SERIAL=$("$ADB" devices | awk '$2=="device"{print $1}' | head -1)
[ -z "$SERIAL" ] && { echo "Телефон не найден"; exit 1; }
S() { "$ADB" -s "$SERIAL" shell "$@"; }

case "${1:-}" in
  lift)
    # сохранить текущие значения один раз (чтобы restore вернул именно их)
    if [ ! -f "$BK" ]; then
      {
        echo "stay=$(S settings get global stay_on_while_plugged_in | tr -d '\r')"
        echo "scan=$(S settings get global wifi_scan_throttle_enabled | tr -d '\r')"
        echo "phantom=$(S settings get global settings_enable_monitor_phantom_procs | tr -d '\r')"
        echo "maxph=$(S /system/bin/device_config get activity_manager max_phantom_processes | tr -d '\r')"
      } > "$BK"
    fi
    S settings put global stay_on_while_plugged_in 3
    S settings put global wifi_sleep_policy 2
    S settings put global wifi_scan_throttle_enabled 0
    S dumpsys deviceidle disable >/dev/null 2>&1
    S /system/bin/device_config put activity_manager max_phantom_processes 2147483647 >/dev/null 2>&1
    S settings put global settings_enable_monitor_phantom_procs false
    echo "Ограничения сняты (рабочий режим)."
    ;;
  restore)
    # значения из бэкапа, иначе вменяемые дефолты
    stay=0; scan=1; phantom=true; maxph=32
    if [ -f "$BK" ]; then . "$BK"; fi
    # null/пустые -> дефолты
    [ "${stay:-null}" = "null" ] && stay=0
    [ "${scan:-null}" = "null" ] && scan=1
    [ "${phantom:-null}" = "null" ] && phantom=true
    [ "${maxph:-null}" = "null" ] && maxph=32
    S settings put global stay_on_while_plugged_in "$stay"
    S settings put global wifi_scan_throttle_enabled "$scan"
    S settings put global settings_enable_monitor_phantom_procs "$phantom"
    S /system/bin/device_config put activity_manager max_phantom_processes "$maxph" >/dev/null 2>&1
    S dumpsys deviceidle enable >/dev/null 2>&1
    rm -f "$BK"
    echo "Покой возвращён (stay=$stay scan=$scan phantom=$phantom maxph=$maxph, Doze включён)."
    ;;
  *)
    echo "usage: $0 {lift|restore}"; exit 1;;
esac
