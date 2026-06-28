#!/bin/bash
# config.sh — единая конфигурация для всех phone-*.sh скриптов.
# Подключать: source "$(cd "$(dirname "$0")" && pwd)/config.sh"

ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"

# rclone: найти бинарник по приоритету (env > PATH > известные пути)
if [ -z "${RCLONE:-}" ]; then
  RCLONE="$(command -v rclone 2>/dev/null)"
fi
[ -x "${RCLONE:-}" ] || RCLONE=/usr/local/bin/rclone
[ -x "$RCLONE"      ] || RCLONE=/opt/homebrew/bin/rclone

PHONE_SSH_PORT="${PHONE_SSH_PORT:-8022}"
PHONE_SSH_USER="${PHONE_SSH_USER:-u0_a520}"
PHONE_SSH_KEY="${PHONE_SSH_KEY:-$HOME/.ssh/id_ed25519_phone}"
PHONE_IP_CACHE="${PHONE_IP_CACHE:-$HOME/.phone_wifi_ip}"

# phone_ip — читает кэш IP; возвращает пустую строку если не известен.
# НЕ хардкодит fallback-IP — лучше явный «неизвестен», чем стучаться не туда.
phone_ip() { cat "$PHONE_IP_CACHE" 2>/dev/null | tr -d '\r'; }

# _to N CMD [ARGS…] — запустить CMD с таймаутом N секунд (macOS без coreutils timeout).
# Убивает дочерний процесс И watcher-sleep, чтобы не плодить осиротевшие sleep.
_to() {
  local t="$1"; shift
  "$@" &
  local p=$!
  # watcher: через $t секунд убить целевой процесс
  ( sleep "$t"; kill -9 "$p" 2>/dev/null ) &
  local w=$!
  wait "$p" 2>/dev/null
  local rc=$?
  # завершить watcher и его дочерний sleep
  kill "$w" 2>/dev/null
  pkill -P "$w" 2>/dev/null
  wait "$w" 2>/dev/null
  return $rc
}

# Атомарная запись IP в кэш с валидацией формата
write_ip_cache() {
  local ip="$1"
  # валидация: только a.b.c.d
  if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    echo "$ip" > "${PHONE_IP_CACHE}.tmp" && mv "${PHONE_IP_CACHE}.tmp" "$PHONE_IP_CACHE"
  fi
}

# PHONE_ACTIVE_FILE — хранит МОДЕЛЬ выбранного устройства (НЕ серийник:
# у Wi-Fi серийники летучие — динамический WD-порт меняется, выбор «откатывался»).
PHONE_ACTIVE_FILE="$HOME/.phone_active_model"

# active_model — выбранная модель (или пусто)
active_model() { cat "$PHONE_ACTIVE_FILE" 2>/dev/null | tr -d '\r'; }

# active_serial — серийник любого подключённого устройства активной модели
active_serial() {
  local m s mod; m=$(active_model); [ -n "$m" ] || return
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    mod=$(_to 6 "$ADB" -s "$s" shell getprop ro.product.model </dev/null 2>/dev/null | tr -d '\r' | tr -d '\n')
    [ "$mod" = "$m" ] && { echo "$s"; return; }
  done < <("$ADB" devices 2>/dev/null | awk '$2=="device"{print $1}')
}

# active_ip — IP именно АКТИВНОГО устройства (по модели), БЫСТРО:
# 1) если у активной модели есть wifi-adb вход (ip:port) → берём его IP из adb devices -l;
# 2) иначе USB-вход активной модели → спрашиваем wlan0;
# 3) иначе кэш phone_ip. НЕ использует общий кэш, который может быть от ДРУГОГО телефона.
active_ip() {
  local m ip us
  m=$(active_model)
  if [ -n "$m" ]; then
    # IP wifi-входа активной модели (без getprop — модель из поля model:)
    ip=$("$ADB" devices -l 2>/dev/null | awk -v m="$m" '
      / device / {
        serial=$1; mod=""
        for(i=2;i<=NF;i++){ if($i ~ /^model:/){ mod=substr($i,7); gsub(/_/,"-",mod) } }
        if(mod==m && serial ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:/){ split(serial,a,":"); print a[1]; exit }
      }')
    [ -n "$ip" ] && { echo "$ip"; return; }
    # USB-вход активной модели → wlan0
    us=$("$ADB" devices -l 2>/dev/null | awk -v m="$m" '
      / device .*usb:/ {
        serial=$1; mod=""
        for(i=2;i<=NF;i++){ if($i ~ /^model:/){ mod=substr($i,7); gsub(/_/,"-",mod) } }
        if(mod==m){ print serial; exit }
      }')
    if [ -n "$us" ]; then
      ip=$(_to 8 "$ADB" -s "$us" shell "ip -f inet addr show wlan0 2>/dev/null" </dev/null 2>/dev/null \
           | awk '/inet /{print $2}' | cut -d/ -f1 | tr -d '\r' | head -1)
      [ -n "$ip" ] && { echo "$ip"; return; }
    fi
  fi
  phone_ip
}

# active_ssh_ok — есть ли у АКТИВНОГО устройства живой sshd (любым путём): yes/no.
# Wi-Fi: nc active_ip:8022. USB: adb forward 8022 + nc 127.0.0.1:8022.
# От этого зависит доступность mount/upload/download/stream.
active_ssh_ok() {
  local ip us
  ip=$(active_ip)
  if [ -n "$ip" ] && _to 3 nc -z -G2 "$ip" 8022 >/dev/null 2>&1; then echo yes; return; fi
  # USB-вход активной модели → проба через ОТДЕЛЬНЫЙ локальный порт 18022 (НЕ 8022 — чтобы не
  # сломать живой USB-маунт, который держит forward 8022). Проверяем rc форварда; чистим за собой.
  local m; m=$(active_model)
  us=$("$ADB" devices -l 2>/dev/null | awk -v m="$m" '
    / device .*usb:/ { s=$1; mod=""; for(i=2;i<=NF;i++){if($i ~ /^model:/){mod=substr($i,7);gsub(/_/,"-",mod)}} if(mod==m){print s; exit} }')
  if [ -n "$us" ]; then
    "$ADB" -s "$us" forward --remove tcp:18022 >/dev/null 2>&1   # снять возможный протухший
    if _to 6 "$ADB" -s "$us" forward tcp:18022 tcp:8022 >/dev/null 2>&1; then
      local r=no
      _to 3 nc -z -G2 127.0.0.1 18022 >/dev/null 2>&1 && r=yes
      "$ADB" -s "$us" forward --remove tcp:18022 >/dev/null 2>&1
      [ "$r" = yes ] && { echo yes; return; }
    fi
  fi
  echo no
}

# adb_dev — серийник активной модели → иначе первый USB
adb_dev() {
  local a; a=$(active_serial)
  [ -n "$a" ] && { echo "$a"; return; }
  pick_usb
}

# pick_usb — вернуть serial USB-устройства (первое) или пустую строку
pick_usb() { "$ADB" devices -l 2>/dev/null | awk '/ device / && /usb:/ {print $1}' | head -1; }

# pick_wifi — вернуть endpoint Wi-Fi-устройства (adb) или пустую строку
pick_wifi() {
  local ep ip
  # сначала — уже известный adb Wi-Fi девайс
  ip=$("$ADB" devices -l 2>/dev/null | awk '/ device / && !/usb:/ {print $1}' | grep ':' | head -1)
  [ -n "$ip" ] && { echo "$ip"; return; }
  # попробовать mDNS
  ep=$(_to 8 "$ADB" mdns services 2>/dev/null | awk '/_adb-tls-connect._tcp/{print $NF; exit}')
  if [ -n "$ep" ]; then
    _to 8 "$ADB" connect "$ep" >/dev/null 2>&1
  fi
  "$ADB" devices -l 2>/dev/null | awk '/ device / && !/usb:/ {print $1}' | grep ':' | head -1
}
