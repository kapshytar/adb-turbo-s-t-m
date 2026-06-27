#!/bin/bash
# «Передёрнуть» adb/USB — пере-сканировать шину и поймать отвалившийся телефон
# (USB просел при лимите заряда / Wi-Fi WD флапнул). Питание порта без sudo не toggle-нуть,
# но re-enumerate adb обычно восстанавливает дропнутое.
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
echo "Передёргиваю adb/USB…"
"$ADB" reconnect offline >/dev/null 2>&1
"$ADB" kill-server  >/dev/null 2>&1; sleep 1
"$ADB" start-server >/dev/null 2>&1; sleep 2
"$ADB" reconnect    >/dev/null 2>&1; sleep 1
# Wi-Fi через mDNS (если WD рекламируется)
EP=$("$ADB" mdns services 2>/dev/null | awk '/_adb-tls-connect._tcp/{print $NF; exit}')
[ -n "$EP" ] && "$ADB" connect "$EP" >/dev/null 2>&1
echo "Устройства:"; "$ADB" devices -l | grep -v "^$"
if "$ADB" devices | grep -q $'\tdevice'; then
  echo "✅ Телефон найден."
else
  echo "❌ Телефон не виден. Проверь кабель и что на телефоне включён USB-debugging / Wireless debugging."
fi
