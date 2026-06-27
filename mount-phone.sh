#!/bin/bash
# Монтирует Android-телефон как диск(и) через adbfs + macFUSE.
#   ./mount-phone.sh            -> внутренняя память в ~/Phone (+ внешняя SD в ~/Phone-SD, если есть)
#   ./mount-phone.sh system     -> весь системный корень телефона в ~/Phone-System
#   ./mount-phone.sh -s SERIAL  -> выбрать конкретный телефон
set -u

ADB="$HOME/Library/Android/sdk/platform-tools/adb"
ADBFS="$HOME/PhoneAsExtStorage/adbfs-rootless/adbfs"
export PATH="$HOME/Library/Android/sdk/platform-tools:$PATH"

MODE="internal"
SERIAL=""
while [ $# -gt 0 ]; do
  case "$1" in
    system) MODE="system";;
    -s) shift; SERIAL="${1:-}";;
    *) SERIAL="$1";;
  esac
  shift
done

# выбрать устройство (предпочесть USB)
if [ -z "$SERIAL" ]; then
  SERIAL=$("$ADB" devices | awk '$2=="device"{print $1}' | grep -v ':' | head -1)
  [ -z "$SERIAL" ] && SERIAL=$("$ADB" devices | awk '$2=="device"{print $1}' | head -1)
fi
if [ -z "$SERIAL" ]; then
  echo "Телефон не найден. Подключи по USB и разреши отладку."; exit 1
fi
export ANDROID_SERIAL="$SERIAL"
echo "Устройство: $SERIAL"

# снять ограничения телефона только на время работы
"$HOME/PhoneAsExtStorage/adbfs-rootless/phone-restrict.sh" lift >/dev/null 2>&1 || true

# смонтировать один том: $1=device-root ("" = система), $2=точка монтирования, $3=имя тома
mount_one() {
  local root="$1" mnt="$2" vol="$3"
  if mount | grep -q " $mnt "; then echo "Уже смонтировано: $mnt"; open "$mnt"; return 0; fi
  mkdir -p "$mnt"
  # noappledouble/noapplexattr — чтобы Finder/Spotlight не плодили ._-файлы и не дёргали полные закачки
  ADBFS_ROOT="$root" nohup "$ADBFS" "$mnt" -f \
      -o "volname=$vol,noappledouble,noapplexattr" \
      > "/tmp/adbfs_$(basename "$mnt").log" 2>&1 &
  disown
  for i in $(seq 1 16); do
    sleep 0.5
    if mount | grep -q " $mnt "; then echo "Смонтировано: $mnt"; open "$mnt"; return 0; fi
  done
  echo "Не удалось смонтировать $mnt. Лог: /tmp/adbfs_$(basename "$mnt").log"; return 1
}

if [ "$MODE" = "system" ]; then
  mount_one "" "$HOME/Phone-System" "Phone System"
  exit $?
fi

# внутренняя память
mount_one "/storage/emulated/0" "$HOME/Phone" "Phone"

# внешняя SD (папка вида XXXX-XXXX в /storage)
SD=$("$ADB" shell "ls /storage/ 2>/dev/null" | tr -d '\r' | grep -E '^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$' | head -1)
if [ -n "$SD" ]; then
  echo "Найдена внешняя SD: $SD"
  mount_one "/storage/$SD" "$HOME/Phone-SD" "Phone SD"
fi
