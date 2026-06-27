#!/bin/bash
# phone-mount-all.sh
# Монтирует ТОЛЬКО USB (он стабилен). Wi-Fi FUSE-маунт НЕ авто-монтируется — он хрупкий
# (FUSE-по-сети вешает ОС при флапе Wi-Fi) и поднимается только явной кнопкой «Mount Wi-Fi».
# Для файлов по Wi-Fi используй браузер/IINA/SSH, а не Finder-маунт.
# Выход: 0 если USB смонтирован, 1 если нет.
set -u

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPTS_DIR/config.sh"

USB_DEV=$(pick_usb)
if [ -z "$USB_DEV" ]; then
  echo "USB-устройство не найдено. (Wi-Fi-папку монтируй явно через «Mount Wi-Fi» — она last-resort.)"
  exit 1
fi

echo "USB-устройство найдено: $USB_DEV — монтирую USB…"
bash "$SCRIPTS_DIR/phone-mount.sh" usb
rc=$?

# после успешного маунта — поднять проактивный watchdog (страж от зависаний)
if [ "$rc" -eq 0 ]; then
  nohup bash "$SCRIPTS_DIR/phone-watchdog.sh" >/dev/null 2>&1 & disown
fi
exit "$rc"
