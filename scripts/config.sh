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
# Также убивает ПОТОМКОВ целевого процесса (например adb внутри `_to N bash script.sh»),
# иначе они остаются сиротами и могут повесить систему в D-state.
_to() {
  local t="$1"; shift
  "$@" &
  local p=$!
  # watcher: через $t секунд убить целевой процесс и его потомков.
  # ВАЖНО: stdout/stderr watcher'а → /dev/null, иначе его sleep наследует пайп
  # и $( _to ... ) блокируется до конца таймаута, даже когда команда давно завершилась.
  ( sleep "$t"; pkill -9 -P "$p" 2>/dev/null; kill -9 "$p" 2>/dev/null ) >/dev/null 2>&1 &
  local w=$!
  wait "$p" 2>/dev/null
  local rc=$?
  # завершить watcher: СНАЧАЛА его дочерний sleep (пока PPID жив и pkill -P его видит),
  # ПОТОМ сам сабшелл — иначе sleep осиротеет и его не найти.
  pkill -P "$w" 2>/dev/null
  kill "$w" 2>/dev/null
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

# find_serial KIND [MODEL] — ЕДИНАЯ точка поиска серийника среди подключённых
# adb-устройств. Один awk-парсер `adb devices -l` (под таймаутом _to 8) вместо
# копий по разным скриптам.
#   KIND  = usb  — только USB-вход (в строке `adb devices -l` есть маркер usb:)
#           wifi — только Wi-Fi-вход (серийник вида ip:port; mDNS-имена с
#                  пробелами НЕ считаются серийником и не берутся)
#           any  — любой подключённый (device-статус), без разбора канала
#   MODEL = опционально.
#           - не передан вовсе          → берётся active_model (если она задана,
#                                          ищем строго её; иначе — любая модель)
#           - передан пустой строкой "" → фильтр по модели ОТКЛЮЧЁН явно (берём
#                                          первое подходящее по KIND устройство,
#                                          даже если active_model задана)
#           - передан непустой          → ищем строго эту модель
# Модель берём из поля `model:...` в `adb devices -l` (без getprop — быстро),
# '_' нормализуем в '-', как везде в проекте.
# adb_devices_l — `adb devices -l` с кэшем на 2с В РАМКАХ ПРОЦЕССА. Один transport зовёт
# find_serial до 4 раз; без кэша при протухших offline-TCP-записях это давало ~24с.
adb_devices_l() {
  # ФАЙЛОВЫЙ кэш (TTL 2с): find_serial зовётся через $(...) в субшеллах, поэтому
  # shell-переменная кэша не переживала бы вызов — без файла adb дёргался бы каждый
  # раз (3×3с=9с на один transport). _to 3: список не должен занимать больше; если adb
  # завис на протухших TCP-записях — лучше быстро вернуть что есть и уйти на SSH.
  local cache="/tmp/.phonestream_adbl" age
  if [ -f "$cache" ]; then age=$(( $(date +%s) - $(stat -f %m "$cache" 2>/dev/null || echo 0) )); else age=999; fi
  if [ "$age" -ge 2 ]; then
    _to 3 "$ADB" devices -l 2>/dev/null > "$cache.$$" && mv -f "$cache.$$" "$cache" || rm -f "$cache.$$"
  fi
  cat "$cache" 2>/dev/null
}

find_serial() {
  local kind="$1" model
  if [ $# -ge 2 ]; then model="$2"; else model=$(active_model); fi
  adb_devices_l | awk -v kind="$kind" -v m="$model" '
    / device / {
      serial=$1
      is_usb  = ($0 ~ /usb:/) ? 1 : 0
      is_wifi = (serial ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$/) ? 1 : 0
      if (kind=="usb"  && !is_usb)  next
      if (kind=="wifi" && !is_wifi) next
      mod=""
      for (i=2; i<=NF; i++) { if ($i ~ /^model:/) { mod=substr($i,7); gsub(/_/,"-",mod) } }
      if (m != "" && mod != m) next
      print serial; exit
    }'
}

# Кэш IP ПО МОДЕЛИ (чтобы IP одного телефона не затирал другой в общем кэше).
model_ip_file() { echo "$HOME/.phone_ip_$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"; }
write_model_ip() {   # model ip — атомарно, с валидацией
  local m="$1" ip="$2" f
  [ -n "$m" ] || return
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return
  f=$(model_ip_file "$m"); echo "$ip" > "$f.tmp" && mv "$f.tmp" "$f"
}
read_model_ip() { cat "$(model_ip_file "$1")" 2>/dev/null | tr -d '\r'; }

# active_ip — IP именно АКТИВНОГО устройства (по модели), БЫСТРО:
# 1) wifi-adb вход активной модели (ip:port) из adb devices -l → кэшируем по модели;
# 2) USB-вход активной модели → wlan0 → кэшируем по модели;
# 3) КЭШ ПО МОДЕЛИ (телефон доступен только по SSH, в adb его нет);
# 4) общий кэш phone_ip (последний резерв). Пункт 3 — ключ: IP ДРУГОГО телефона больше не тянется.
active_ip() {
  local m ip us
  m=$(active_model)
  if [ -n "$m" ]; then
    # IP wifi-входа активной модели (без getprop — модель из поля model:)
    ip=$(find_serial wifi "$m" | cut -d: -f1)
    [ -n "$ip" ] && { write_model_ip "$m" "$ip"; echo "$ip"; return; }
    # USB-вход активной модели → wlan0
    us=$(find_serial usb "$m")
    if [ -n "$us" ]; then
      ip=$(_to 8 "$ADB" -s "$us" shell "ip -f inet addr show wlan0 2>/dev/null" </dev/null 2>/dev/null \
           | awk '/inet /{print $2}' | cut -d/ -f1 | tr -d '\r' | head -1)
      [ -n "$ip" ] && { write_model_ip "$m" "$ip"; echo "$ip"; return; }
    fi
    # телефона нет в adb — берём его ПЕРСОНАЛЬНЫЙ кэш (не чужой)
    ip=$(read_model_ip "$m"); [ -n "$ip" ] && { echo "$ip"; return; }
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
  us=$(find_serial usb "$m")
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

# pick_usb — вернуть serial USB-устройства (первое) или пустую строку.
# Модель-агностично (НЕ фильтрует по active_model) — глобальный пик по всем
# подключённым USB-устройствам, как и раньше.
pick_usb() { find_serial usb ""; }

# pick_wifi — вернуть endpoint Wi-Fi-устройства (adb) или пустую строку.
# Модель-агностично, как и pick_usb. Сначала уже известный adb Wi-Fi девайс,
# иначе — пробуем поднять его через mDNS и смотрим снова.
pick_wifi() {
  local ep wifi
  wifi=$(find_serial wifi "")
  [ -n "$wifi" ] && { echo "$wifi"; return; }
  # попробовать mDNS
  ep=$(_to 8 "$ADB" mdns services 2>/dev/null | awk '/_adb-tls-connect._tcp/{print $NF; exit}')
  if [ -n "$ep" ]; then
    _to 8 "$ADB" connect "$ep" >/dev/null 2>&1
  fi
  find_serial wifi ""
}
