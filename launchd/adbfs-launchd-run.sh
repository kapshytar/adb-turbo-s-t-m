#!/usr/bin/env bash
# adbfs-launchd-run.sh — обёртка для запуска adbfs через launchd
# Выход 0  → launchd НЕ перезапускает (телефон не найден)
# Выход != 0 → launchd перезапустит через ThrottleInterval (adbfs упал)

set -euo pipefail

ADB_DIR="$HOME/Library/Android/sdk/platform-tools"
MOUNTPOINT="$HOME/Phone"
ADBFS_BIN="$HOME/PhoneAsExtStorage/adbfs-rootless/adbfs"
ADBFS_ROOT="/storage/emulated/0"
WAIT_SECS=30
RETRY_INTERVAL=3

export PATH="$ADB_DIR:/usr/local/bin:/usr/bin:/bin"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ── Найти первое USB-устройство Android (не эмулятор) ─────────────────────────
find_usb_device() {
    "$ADB_DIR/adb" devices 2>/dev/null \
        | awk 'NR>1 && /\tdevice$/ && !/emulator/' \
        | awk '{print $1}' \
        | grep -v '^$' \
        | head -1
}

# ── Ждём появления устройства до WAIT_SECS секунд ─────────────────────────────
log "Ожидание USB-устройства Android (до ${WAIT_SECS}с)..."
elapsed=0
SERIAL=""
while [ $elapsed -lt $WAIT_SECS ]; do
    SERIAL="$(find_usb_device)"
    if [ -n "$SERIAL" ]; then
        log "Найдено устройство: $SERIAL"
        break
    fi
    sleep "$RETRY_INTERVAL"
    elapsed=$((elapsed + RETRY_INTERVAL))
done

if [ -z "$SERIAL" ]; then
    log "Устройство не найдено за ${WAIT_SECS}с — выход 0 (launchd не будет молотить)."
    exit 0
fi

export ANDROID_SERIAL="$SERIAL"

# ── Создать точку монтирования ─────────────────────────────────────────────────
mkdir -p "$MOUNTPOINT"

# ── Если уже смонтировано — отмонтировать (stale mount после sleep/wake) ──────
if mount | grep -q " $MOUNTPOINT "; then
    log "Обнаружен stale mount на $MOUNTPOINT, отмонтируем..."
    diskutil unmount force "$MOUNTPOINT" 2>/dev/null || umount "$MOUNTPOINT" 2>/dev/null || true
    sleep 1
fi

log "Запуск adbfs: устройство=$SERIAL, корень=$ADBFS_ROOT, точка=$MOUNTPOINT"

# ── exec: launchd следит за этим процессом напрямую ───────────────────────────
exec "$ADBFS_BIN" "$MOUNTPOINT" \
    -f \
    -o "volname=Phone,noappledouble,noapplexattr,allow_other"
