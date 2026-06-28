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

# PHONE_ACTIVE_FILE — хранит серийник выбранного устройства для adb-операций
PHONE_ACTIVE_FILE="$HOME/.phone_active_serial"

# active_serial — отдаёт серийник ТОЛЬКО если он сохранён И сейчас подключён
active_serial() {
  local s
  s=$(cat "$PHONE_ACTIVE_FILE" 2>/dev/null | tr -d '\r')
  [ -n "$s" ] && "$ADB" devices 2>/dev/null | grep -q "^$s[[:space:]]" && echo "$s"
}

# adb_dev — активный серийник (если подключён) → иначе первый USB
adb_dev() {
  local a
  a=$(active_serial)
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
