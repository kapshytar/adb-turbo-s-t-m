#!/bin/bash
# СТРАЖ USB-ЛИНКА. Задача: пока телефон воткнут по USB — Mac НЕ должен тушить дата-линк.
# Причина дропов: (1) macOS усыпляет USB-порты при system sleep; (2) Samsung на ~85%
# перестаёт заряжаться → разряд → линк проседает. В macOS НЕТ пер-девайсного "не суспендить
# USB" (это Windows-фича). Поэтому: caffeinate (нет idle/system sleep пока USB воткнут)
# + трафик по линку каждые 5с (adb shell true) + авто-reconnect. Single-instance. Лог.
set -u

# shellcheck source=config.sh
source "$(cd "$(dirname "$0")" && pwd)/config.sh"

LOG="$HOME/PhoneAsExtStorage/phone-keepalive.log"
LOCK="/tmp/phone-keepalive.lock"
mkdir "$LOCK" 2>/dev/null || { echo "keepalive уже запущен"; exit 0; }

log(){ echo "$(date '+%F %T') $*" >> "$LOG"; }

# Ротация лога: если >1МБ → сдвинуть в .1
if [ -f "$LOG" ] && [ "$(stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  mv "$LOG" "${LOG}.1"
fi

CAFF_PID=""
start_caff(){
  # уже жив?
  [ -n "$CAFF_PID" ] && kill -0 "$CAFF_PID" 2>/dev/null && return
  # Убить предыдущих сирот-caffeinate (если keepalive был прерван ненормально)
  pkill -f "caffeinate -ism" 2>/dev/null
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

log "keepalive START (pid $$)"
miss=0; gone=0; fail_streak=0; tick=0
while sleep 5; do
  tick=$((tick+1))
  # Периодический пинг Wi-Fi-adb входа активной модели: не даёт listener'у Wireless
  # Debugging уснуть (Samsung усыпляет его в простое) + кэшируем порт для reconnect.
  # Частота: раз в PHONE_WD_PING_MIN минут (деф. 5 — баланс: пинг чаще = больше
  # микропробуждений радио телефона; если listener засыпает раньше — уменьшить).
  if [ $((tick % (12 * ${PHONE_WD_PING_MIN:-5}))) -eq 0 ]; then
    wd=$(find_serial wifi 2>/dev/null)
    if [ -n "$wd" ] && _to 8 "$ADB" -s "$wd" shell true >/dev/null 2>&1; then
      am=$(active_model); [ -n "$am" ] && write_wd_port "$am" "${wd##*:}"
    fi
  fi
  # есть ли USB-устройство? (по маркеру usb: в devices -l)
  usb_dev=$(_to 8 "$ADB" devices -l 2>/dev/null | awk '/ device .*usb:/{print $1; exit}')
  if [ -n "$usb_dev" ]; then
    gone=0
    start_caff                      # USB воткнут → не давать компу уснуть
    if _to 8 "$ADB" -s "$usb_dev" shell true >/dev/null 2>&1; then
      miss=0
      [ "$fail_streak" -gt 0 ] && log "ping restored after $fail_streak fail(s)"
      fail_streak=0
    else
      miss=$((miss+1)); fail_streak=$((fail_streak+1))
      # агрегация: первый fail сразу, затем каждый 12-й (~раз в минуту при интервале 5с)
      { [ "$fail_streak" -eq 1 ] || [ $((fail_streak % 12)) -eq 0 ]; } && log "ping fail #$fail_streak ($usb_dev)"
      [ "$miss" -ge 2 ] && { _to 8 "$ADB" reconnect >/dev/null 2>&1; log "  adb reconnect"; miss=0; }
    fi
  else
    # USB нет. Подождём (вдруг моргнул) — через ~30с отпускаем сон.
    gone=$((gone+1))
    [ "$gone" -ge 6 ] && stop_caff
    # на всякий — поднять, если есть любое adb-устройство (Wi-Fi/WD), но без caffeinate
    any=$(_to 8 "$ADB" devices 2>/dev/null | awk '$2=="device"{print $1; exit}')
    [ -z "$any" ] && _to 8 "$ADB" reconnect >/dev/null 2>&1
  fi
done
