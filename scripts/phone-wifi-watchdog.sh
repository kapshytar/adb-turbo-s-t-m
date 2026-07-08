#!/bin/bash
# Watchdog для Wi-Fi-стораджа: если телефон стал недоступен (ушёл из дома / уснул),
# force-unmount ДО того как мёртвый маунт повесит ОС. Следит пингом, а не путём.
set -u

# shellcheck source=config.sh
source "$(cd "$(dirname "$0")" && pwd)/config.sh"

# IP: из переменной окружения или из кэша — НЕ хардкодим
IP="${PHONE_IP:-$(phone_ip)}"
MNT="$HOME/Phone-WiFi"
LOG="$HOME/PhoneAsExtStorage/phone-wifi-watchdog.log"
LOCK=/tmp/phone-wifi-watchdog.lock
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM
# ротация: >1MB → оставить хвост (у остальных логгеров так же; без неё лог рос бесконечно)
if [ -f "$LOG" ] && [ "$(stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  tail -c 262144 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
log(){ echo "$(date '+%F %T') $*" >> "$LOG"; }

if [ -z "$IP" ]; then
  log "wifi-watchdog: IP телефона неизвестен (PHONE_IP не задан, кэш пуст) — выход"
  exit 1
fi

log "wifi-watchdog START (ip=$IP)"
miss=0
while sleep 5; do
  /sbin/mount 2>/dev/null | grep -q " $MNT " || { log "маунта нет → выход"; exit 0; }
  if _to 4 ping -c1 -t2 "$IP" >/dev/null 2>&1; then
    miss=0
  else
    miss=$((miss+1)); log "ping fail #$miss ($IP)"
    if [ "$miss" -ge 3 ]; then
      log "телефон недоступен 15с → force-unmount (защита ОС от висяка)"
      pkill -f "rclone mount.*$MNT" 2>/dev/null
      _to 12 diskutil unmount force "$MNT" >/dev/null 2>&1
      umount -f "$MNT" >/dev/null 2>&1
      rmdir "$MNT" 2>/dev/null
      log "  unmounted, выход"
      exit 0
    fi
  fi
done
