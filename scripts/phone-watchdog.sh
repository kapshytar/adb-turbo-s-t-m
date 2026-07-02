#!/bin/bash
# ПРОАКТИВНЫЙ watchdog против D-state-висяка всей macOS.
# Для каждой ЖИВОЙ точки маунта телефона каждые 3с:
#   1) stat С ТАЙМАУТОМ — если файловая операция не вернулась за 3с, маунт начал виснуть → force-unmount НЕМЕДЛЕННО (до ухода ядра в непрерываемый I/O);
#   2) доступность бэкенда (USB: usb-устройство в adb; Wi-Fi: ping IP) — 2 промаха (~6с) → force-unmount.
# Покрывает И USB, И Wi-Fi (любой транспорт), реагирует быстро. Сам выходит, когда маунтов нет.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
source "$HERE/config.sh"

LOG="$HOME/PhoneAsExtStorage/phone-watchdog.log"
USB_MNT="$HOME/Phone-USB"
WIFI_MNT="$HOME/Phone-WiFi"
log(){ echo "$(date '+%F %T') $*" >> "$LOG"; }

LOCK="/tmp/phone-watchdog.lock"
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM
# ротация лога
[ "$(stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt 5242880 ] && mv "$LOG" "$LOG.1" 2>/dev/null
log "watchdog START (проактивный stat+reachability)"

force_unmount(){ # $1=mountpoint $2=причина
  # per-mountpoint lock — не плодить параллельные diskutil unmount force на ту же точку
  # при серийных промахах (mkdir атомарен между процессами/фоновыми job'ами).
  local fu_lock="/tmp/phone-watchdog.force_unmount.$(basename "$1").lock"
  mkdir "$fu_lock" 2>/dev/null || { log "ОТСТРЕЛ $1 ($2) → уже выполняется, пропуск"; return; }
  log "ОТСТРЕЛ $1 ($2) → kill rclone + force-unmount"
  pkill -f "rclone mount.*$1" 2>/dev/null
  # force-unmount в фоне с таймаутом, чтобы сам watchdog не завис
  ( _to 10 diskutil unmount force "$1" >/dev/null 2>&1; umount -f "$1" >/dev/null 2>&1; rmdir "$fu_lock" 2>/dev/null ) >/dev/null 2>&1 &
}

idle=0; usb_miss=0; wifi_miss=0
while sleep 3; do
  any=0

  # ---- USB-том ----
  if /sbin/mount | grep -q " $USB_MNT "; then
    any=1
    if ! _to 3 stat "$USB_MNT" >/dev/null 2>&1; then
      force_unmount "$USB_MNT" "stat завис"; usb_miss=0
    elif [ -n "$(pick_usb)" ]; then
      usb_miss=0
    else
      usb_miss=$((usb_miss+1)); log "USB бэкенд недоступен #$usb_miss"
      [ "$usb_miss" -ge 2 ] && { force_unmount "$USB_MNT" "USB-устройство пропало"; usb_miss=0; }
    fi
  else usb_miss=0; fi

  # ---- Wi-Fi-том ----
  if /sbin/mount | grep -q " $WIFI_MNT "; then
    any=1
    ip=$(phone_ip)
    if ! _to 3 stat "$WIFI_MNT" >/dev/null 2>&1; then
      force_unmount "$WIFI_MNT" "stat завис"; wifi_miss=0
    elif [ -n "$ip" ] && _to 2 ping -c1 -t1 "$ip" >/dev/null 2>&1; then
      wifi_miss=0
    else
      wifi_miss=$((wifi_miss+1)); log "Wi-Fi бэкенд ($ip) недоступен #$wifi_miss"
      [ "$wifi_miss" -ge 2 ] && { force_unmount "$WIFI_MNT" "телефон недоступен по Wi-Fi"; wifi_miss=0; }
    fi
  else wifi_miss=0; fi

  # НЕ выходим без маунтов — сторож должен жить всё время, пока работает трей,
  # иначе маунт, созданный позже, останется без защиты (трей убьёт нас при выходе).
  : "$any"
done
