#!/bin/bash
# «ПОДКЛЮЧИТЬ ВСЁ»: пробегается по ВСЕМ способам инициализации каждого канала
# и печатает итог — что поднялось. Идемпотентно (рабочее не ломает).
set -u

# shellcheck source=config.sh
source "$(cd "$(dirname "$0")" && pwd)/config.sh"

DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Подключаю все каналы…"

# 0) перезапуск adb-сервера — чинит протухший mDNS на macOS и пере-сканирует USB-шину.
#    НО: если смонтирован FUSE-том телефона, kill-server убьёт активный adb-форвард →
#    зависший маунт. В этом случае только reconnect offline.
if /sbin/mount | grep -qE 'Phone-USB|Phone-WiFi'; then
  echo "Обнаружен активный FUSE-маунт телефона — пропускаю kill-server, делаю reconnect offline."
  _to 8 "$ADB" reconnect offline >/dev/null 2>&1
else
  _to 8 "$ADB" kill-server  >/dev/null 2>&1; sleep 1
  _to 8 "$ADB" start-server >/dev/null 2>&1; sleep 2
  # 1) USB: re-enumerate (если порт живой — телефон поднимется как usb:)
  _to 8 "$ADB" reconnect offline >/dev/null 2>&1
fi

# 2) Wi-Fi adb / Wireless-debug — все способы:
#    a) mDNS (динамический порт WD)
_to 8 "$ADB" mdns services >/dev/null 2>&1; sleep 1
EP=$(_to 8 "$ADB" mdns services 2>/dev/null | awk '/_adb-tls-connect._tcp/{print $NF; exit}')
[ -n "$EP" ] && _to 8 "$ADB" connect "$EP" >/dev/null 2>&1

#    b) фикс-порт 5555 (если adbd слушает) — только если IP известен
IP=$(phone_ip)
if [ -n "$IP" ]; then
  _to 4 nc -z -G1 "$IP" 5555 >/dev/null 2>&1 && _to 8 "$ADB" connect "$IP:5555" >/dev/null 2>&1
else
  echo "Wi-Fi IP телефона неизвестен — пропускаю попытку подключения по IP."
fi

#    c) прямой connect на закэшированный порт WD (mDNS часто молчит; порт живёт до ребута).
#       Порт запоминается в write_wd_port при каждом успешном подключении.
AM=$(active_model)
if [ -n "$AM" ] && [ -n "$IP" ]; then
  WDP=$(read_wd_port "$AM")
  if [ -n "$WDP" ] && _to 4 nc -z -G1 "$IP" "$WDP" >/dev/null 2>&1; then
    _to 8 "$ADB" connect "$IP:$WDP" >/dev/null 2>&1
  fi
fi

#    запомнить порт WD активного устройства для будущих reconnect без mDNS
if [ -n "$AM" ]; then
  WDS=$(find_serial wifi "$AM")
  [ -n "$WDS" ] && write_wd_port "$AM" "${WDS##*:}"
fi

# 3) Wi-Fi SSH — проверка (поднять удалённо нельзя; watchdog на телефоне сам держит)
SSH_OK=no
if [ -n "$IP" ]; then
  _to 4 nc -z -G2 "$IP" 8022 >/dev/null 2>&1 && SSH_OK=yes
fi

sleep 2

# 4) тома (best effort)
bash "$DIR/phone-mount-all.sh" >/dev/null 2>&1 || true

# ── ИТОГ: что поднялось ──
echo "──────── РЕЗУЛЬТАТ ────────"
U=$(_to 8 "$ADB" devices -l 2>/dev/null | grep 'usb:' | awk '{print $1}')
[ -n "$U" ] && echo "USB (кабель): $U" || echo "USB: нет (проверь кабель=дата и порт)"
WC=$(_to 8 "$ADB" devices 2>/dev/null | grep -E ':[0-9]+|_adb-tls' | grep -c device || true)
[ "${WC:-0}" -gt 0 ] && echo "Wi-Fi adb (Wireless-debug): $WC вход(а)" || echo "Wi-Fi adb: нет. Тумблер WD может гореть «вкл», но listener СПИТ — открой на телефоне САМ ЭКРАН Wireless debugging (сервис проснётся, порт виден там же) и запусти меня снова."
[ "$SSH_OK" = yes ] && echo "Wi-Fi SSH (8022): жив" || echo "Wi-Fi SSH: нет (на телефоне запусти sshd: виджет Start-SSHD)"
/sbin/mount | grep -q Phone-USB  && echo "Папка USB смонтирована"  || echo "Папка USB не смонтирована"
/sbin/mount | grep -q Phone-WiFi && echo "Папка Wi-Fi смонтирована" || echo "Папка Wi-Fi не смонтирована"
exit 0
