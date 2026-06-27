#!/bin/bash
# Watchdog для Wi-Fi-стораджа: если телефон стал недоступен (ушёл из дома / уснул),
# force-unmount ДО того как мёртвый маунт повесит ОС. Следит пингом, а не путём.
set -u
IP="${PHONE_IP:-192.168.1.202}"
MNT="$HOME/PhoneWiFi"
LOG="$HOME/PhoneAsExtStorage/phone-wifi-watchdog.log"
LOCK=/tmp/phone-wifi-watchdog.lock
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM
log(){ echo "$(date '+%F %T') $*" >> "$LOG"; }
log "wifi-watchdog START (ip=$IP)"
miss=0
while sleep 5; do
  /sbin/mount 2>/dev/null | grep -q " $MNT " || { log "маунта нет → выход"; exit 0; }
  if ping -c1 -t2 "$IP" >/dev/null 2>&1; then
    miss=0
  else
    miss=$((miss+1)); log "ping fail #$miss ($IP)"
    if [ "$miss" -ge 3 ]; then
      log "телефон недоступен 15с → force-unmount (защита ОС от висяка)"
      pkill -f "rclone mount.*$MNT" 2>/dev/null
      diskutil unmount force "$MNT" >/dev/null 2>&1
      umount -f "$MNT" >/dev/null 2>&1
      rmdir "$MNT" 2>/dev/null
      log "  unmounted, выход"
      exit 0
    fi
  fi
done
