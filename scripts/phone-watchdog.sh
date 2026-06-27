#!/bin/bash
# Watchdog: если есть FUSE-маунт телефона, но adb-устройство ПРОПАЛО — мёртвый маунт
# вешает ОС. Тогда: force-unmount + kill rclone, и всё в ЛОГ (для диагностики причины).
# Следим за adb (Codex), а не за самой точкой (её опрос может сам зависнуть).
# Сам выходит, когда маунтов телефона больше нет.
set -u
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
LOG="$HOME/PhoneAsExtStorage/phone-watchdog.log"
POINTS=("$HOME/Phone-USB" "$HOME/Phone-WiFi" "$HOME/Phone" "$HOME/Phone-SD" "$HOME/Phone-System")
log(){ echo "$(date '+%F %T') $*" >> "$LOG"; }

# single instance
LOCK="/tmp/phone-watchdog.lock"
if ! mkdir "$LOCK" 2>/dev/null; then exit 0; fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

log "watchdog START (pid $$)"
idle=0
while sleep 3; do
  # есть ли вообще phone-маунт?
  mounted=""
  for m in "${POINTS[@]}"; do
    /sbin/mount 2>/dev/null | grep -q " $m " && mounted="$mounted $m"
  done
  if [ -z "$mounted" ]; then
    idle=$((idle+1))
    # 60с без маунтов → watchdog не нужен, выходим
    [ "$idle" -ge 20 ] && { log "нет маунтов 60с → выход"; exit 0; }
    continue
  fi
  idle=0
  # маунт есть — живо ли adb-устройство?
  if ! "$ADB" devices 2>/dev/null | grep -q $'\tdevice'; then
    log "DEAD: есть маунт ($mounted), но adb-устройств НЕТ → отстреливаю"
    pkill -f "rclone mount" 2>/dev/null && log "  killed: rclone mount"
    for m in $mounted; do
      diskutil unmount force "$m" >/dev/null 2>&1 && log "  unmounted: $m"
      umount -f "$m" >/dev/null 2>&1
      rmdir "$m" 2>/dev/null
    done
    log "  cleanup done (см. что было примонтировано выше — причина висяка зафиксирована)"
  fi
done
