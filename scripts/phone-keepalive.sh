#!/bin/bash
# СТРАЖ USB-ЛИНКА. Задача: пока телефон воткнут по USB — Mac НЕ должен тушить дата-линк.
# Причина дропов: (1) macOS усыпляет USB-порты при system sleep; (2) Samsung на ~85%
# перестаёт заряжаться → разряд → линк проседает. В macOS НЕТ пер-девайсного "не суспендить
# USB" (это Windows-фича). Поэтому: caffeinate (нет idle/system sleep пока USB воткнут)
# + трафик по линку каждые 5с (adb shell true) + авто-reconnect. Single-instance. Лог.
set -u
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
LOG="$HOME/PhoneAsExtStorage/phone-keepalive.log"
LOCK="/tmp/phone-keepalive.lock"
mkdir "$LOCK" 2>/dev/null || { echo "keepalive уже запущен"; exit 0; }
log(){ echo "$(date '+%F %T') $*" >> "$LOG"; }

CAFF_PID=""
start_caff(){
  # уже жив?
  [ -n "$CAFF_PID" ] && kill -0 "$CAFF_PID" 2>/dev/null && return
  # -i нет idle-sleep, -s нет system-sleep (на адаптере), -m нет disk-sleep.
  # Дисплею спать можно (это не суспендит USB). Без sudo.
  caffeinate -ism >/dev/null 2>&1 &
  CAFF_PID=$!
  log "caffeinate ON (USB подключён → блокирую сон, линк не уснёт) pid=$CAFF_PID"
}
stop_caff(){
  [ -n "$CAFF_PID" ] && { kill "$CAFF_PID" 2>/dev/null; log "caffeinate OFF (USB нет → разрешаю сон)"; CAFF_PID=""; }
}
trap 'stop_caff; rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

# хелпер: adb с таймаутом (без D-state-висяка). macOS без coreutils timeout.
adb_to(){ # $1=сек, далее adb-аргументы
  local t="$1"; shift
  "$ADB" "$@" >/dev/null 2>&1 &
  local p=$!
  ( sleep "$t"; kill -9 "$p" 2>/dev/null ) 2>/dev/null & local w=$!
  wait "$p" 2>/dev/null; local rc=$?
  kill "$w" 2>/dev/null
  return $rc
}

log "keepalive START (pid $$)"
miss=0; gone=0
while sleep 5; do
  # есть ли USB-устройство? (по маркеру usb: в devices -l)
  usb_dev=$("$ADB" devices -l 2>/dev/null | awk '/ device .*usb:/{print $1; exit}')
  if [ -n "$usb_dev" ]; then
    gone=0
    start_caff                      # USB воткнут → не давать компу уснуть
    if adb_to 8 -s "$usb_dev" shell true; then
      miss=0
    else
      miss=$((miss+1)); log "ping fail #$miss ($usb_dev)"
      [ "$miss" -ge 2 ] && { "$ADB" reconnect >/dev/null 2>&1; log "  adb reconnect"; miss=0; }
    fi
  else
    # USB нет. Подождём (вдруг моргнул) — через ~30с отпускаем сон.
    gone=$((gone+1))
    [ "$gone" -ge 6 ] && stop_caff
    # на всякий — поднять, если есть любое adb-устройство (Wi-Fi/WD), но без caffeinate
    any=$("$ADB" devices 2>/dev/null | awk '$2=="device"{print $1; exit}')
    [ -z "$any" ] && "$ADB" reconnect >/dev/null 2>&1
  fi
done
