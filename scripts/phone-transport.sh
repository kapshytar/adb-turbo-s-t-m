#!/bin/bash
# МОЗГ ТРАНСПОРТА: выбирает самый быстрый/надёжный канал до телефона и печатает строку:
#   usb|SERIAL          — воткнут по USB (самый стабильный; предпочитается)
#   wifi-ssh|IP:PORT    — прямой SSH по Wi-Fi (надёжно; не флапает как adb-WD)
#   wifi-adb|ENDPOINT   — adb по Wi-Fi (Wireless Debugging mdns; последний выбор, флапает)
#   none|               — телефон недоступен
# Пока телефон на USB — кэширует его Wi-Fi-IP в ~/.phone_wifi_ip, чтобы потом
# (без кабеля) знать, куда стучаться по SSH. Все вызовы с таймаутами (без D-state-висяка).
set -u

# shellcheck source=config.sh
source "$(cd "$(dirname "$0")" && pwd)/config.sh"

# Нормализовать model: заменить '_' → '-' (как в adb devices -l)
_norm_model() { echo "$1" | tr '_' '-'; }

# Получить активную модель
m=$(active_model)

if [ -n "$m" ]; then
  # ── РЕЖИМ АКТИВНОГО УСТРОЙСТВА ──────────────────────────────────────────
  # 1) USB активной модели
  usb=$(find_serial usb "$m")
  if [ -n "$usb" ]; then
    # обновить кэш Wi-Fi-IP
    ip=$(_to 8 "$ADB" -s "$usb" shell "ip -f inet addr show wlan0 2>/dev/null" </dev/null 2>/dev/null \
          | awk '/inet /{print $2}' | cut -d/ -f1 | tr -d '\r' | head -1)
    [ -n "$ip" ] && write_ip_cache "$ip"
    echo "usb|$usb"; exit 0
  fi

  # 2) Wi-Fi SSH — берём IP активного устройства
  ip=$(active_ip)
  if [ -n "$ip" ] && _to 4 ping -c1 -t1 "$ip" >/dev/null 2>&1; then
    if _to 2 nc -z -G2 "$ip" "$PHONE_SSH_PORT" >/dev/null 2>&1; then
      echo "wifi-ssh|$ip:$PHONE_SSH_PORT"; exit 0
    fi
    # пингуется, sshd не отвечает — нет Termux sshd на этом устройстве или спит
  fi

  # 3) Wi-Fi adb активной модели
  wifi_adb=$(find_serial wifi "$m")
  if [ -n "$wifi_adb" ]; then
    # sshd мог проснуться — попробуем ещё раз
    if [ -n "${ip:-}" ] && _to 2 nc -z -G2 "$ip" "$PHONE_SSH_PORT" >/dev/null 2>&1; then
      echo "wifi-ssh|$ip:$PHONE_SSH_PORT"; exit 0
    fi
    echo "wifi-adb|$wifi_adb"; exit 0
  fi

  # 4) последний шанс: IP известен, пингуется
  if [ -n "${ip:-}" ] && _to 4 ping -c1 -t1 "$ip" >/dev/null 2>&1; then
    echo "wifi-ssh|$ip:$PHONE_SSH_PORT"; exit 0
  fi

  echo "none|"; exit 1
fi

# ── РЕЖИМ БЕЗ АКТИВНОГО УСТРОЙСТВА (глобальный, как было) ───────────────

# 1) USB — предпочтительно
usb=$(find_serial usb "")
if [ -n "$usb" ]; then
  ip=$(_to 8 "$ADB" -s "$usb" shell "ip -f inet addr show wlan0 2>/dev/null" </dev/null 2>/dev/null \
        | awk '/inet /{print $2}' | cut -d/ -f1 | tr -d '\r' | head -1)
  [ -n "$ip" ] && write_ip_cache "$ip"
  echo "usb|$usb"; exit 0
fi

# 2) Прямой SSH по Wi-Fi (надёжный канал)
ip=$(phone_ip)
if [ -n "$ip" ] && _to 4 ping -c1 -t1 "$ip" >/dev/null 2>&1; then
  if _to 4 nc -z -G2 "$ip" "$PHONE_SSH_PORT" >/dev/null 2>&1; then
    echo "wifi-ssh|$ip:$PHONE_SSH_PORT"; exit 0
  fi
fi

# 3) Wi-Fi adb (Wireless Debugging через mDNS)
ep=$(_to 8 "$ADB" mdns services 2>/dev/null | awk '/_adb-tls-connect._tcp/{print $NF; exit}')
if [ -n "$ep" ]; then
  _to 8 "$ADB" connect "$ep" >/dev/null 2>&1
  if [ -n "${ip:-}" ] && _to 4 nc -z -G2 "$ip" "$PHONE_SSH_PORT" >/dev/null 2>&1; then
    echo "wifi-ssh|$ip:$PHONE_SSH_PORT"; exit 0
  fi
  echo "wifi-adb|$ep"; exit 0
fi

# 4) последний шанс
if [ -n "${ip:-}" ] && _to 4 ping -c1 -t1 "$ip" >/dev/null 2>&1; then
  echo "wifi-ssh|$ip:$PHONE_SSH_PORT"; exit 0
fi

echo "none|"; exit 1
