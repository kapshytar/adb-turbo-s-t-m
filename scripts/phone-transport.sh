#!/bin/bash
# МОЗГ ТРАНСПОРТА: выбирает самый быстрый/надёжный канал до телефона и печатает строку:
#   usb|SERIAL          — воткнут по USB (самый стабильный; предпочитается)
#   wifi-ssh|IP:PORT    — прямой SSH по Wi-Fi (надёжно; не флапает как adb-WD)
#   wifi-adb|ENDPOINT   — adb по Wi-Fi (Wireless Debugging mdns; последний выбор, флапает)
#   none|               — телефон недоступен
# Пока телефон на USB — кэширует его Wi-Fi-IP в ~/.phone_wifi_ip, чтобы потом
# (без кабеля) знать, куда стучаться по SSH. Все вызовы с таймаутами (без D-state-висяка).
set -u
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
IPCACHE="$HOME/.phone_wifi_ip"
SSHPORT="${PHONE_SSH_PORT:-8022}"
SSHUSER="${PHONE_SSH_USER:-u0_a520}"

# 1) USB — предпочтительно
usb=$("$ADB" devices -l 2>/dev/null | awk '/ device .*usb:/{print $1; exit}')
if [ -n "$usb" ]; then
  # обновим кэш Wi-Fi-IP телефона для будущего фолбэка
  ip=$("$ADB" -s "$usb" shell "ip -f inet addr show wlan0 2>/dev/null" 2>/dev/null \
        | awk '/inet /{print $2}' | cut -d/ -f1 | tr -d '\r' | head -1)
  [ -n "$ip" ] && echo "$ip" > "$IPCACHE"
  echo "usb|$usb"; exit 0
fi

# 2) Прямой SSH по Wi-Fi (надёжный канал)
ip=$(cat "$IPCACHE" 2>/dev/null | tr -d '\r')
if [ -n "$ip" ] && ping -c1 -t1 "$ip" >/dev/null 2>&1; then
  # порт sshd открыт? (nc с таймаутом)
  if nc -z -G2 "$ip" "$SSHPORT" >/dev/null 2>&1; then
    echo "wifi-ssh|$ip:$SSHPORT"; exit 0
  fi
  # телефон пингуется, но sshd спит — попробуем «разбудить» через adb-WD (если есть), затем ещё раз
fi

# 3) Wi-Fi adb (Wireless Debugging через mDNS) — поднять и отдать (последний выбор)
ep=$("$ADB" mdns services 2>/dev/null | awk '/_adb-tls-connect._tcp/{print $NF; exit}')
if [ -n "$ep" ]; then
  "$ADB" connect "$ep" >/dev/null 2>&1
  # если знаем IP — стукнем sshd ещё раз (вдруг проснулся)
  if [ -n "${ip:-}" ] && nc -z -G2 "$ip" "$SSHPORT" >/dev/null 2>&1; then
    echo "wifi-ssh|$ip:$SSHPORT"; exit 0
  fi
  echo "wifi-adb|$ep"; exit 0
fi

# 4) последний шанс: знаем IP, пингуется, но sshd не отвечал — отдадим wifi-ssh как цель «разбудить»
if [ -n "${ip:-}" ] && ping -c1 -t1 "$ip" >/dev/null 2>&1; then
  echo "wifi-ssh|$ip:$SSHPORT"; exit 0
fi

echo "none|"; exit 1
