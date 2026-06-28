#!/bin/bash
# run-tests.sh — быстрый регрессионный прогон ключевых путей PhoneStream.
# Покрытие: синтаксис, config-хелперы, _to (таймаут/без сирот), валидация IP-кэша,
# phone-devices формат, авто-выбор канала (transport), active_ip, статус диска,
# стрим с range, upload (мультипоток), download. Тесты, требующие телефон/sshd,
# автоматически SKIP-аются, если канал недоступен. Не мутирует выбор устройства
# (сохраняет/восстанавливает ~/.phone_active_model).
#
# Запуск: bash tests/run-tests.sh
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"   # adbfs-rootless/
source "$HERE/config.sh"

PASS=0; FAIL=0; SKIP=0
ok(){   printf "  \033[32mPASS\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
no(){   printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }
skip(){ printf "  \033[33mSKIP\033[0m %s\n" "$1"; SKIP=$((SKIP+1)); }
hdr(){  printf "\n== %s ==\n" "$1"; }

# сохранить выбор устройства и восстановить в конце
SAVED_MODEL=$(active_model)
restore(){ if [ -n "$SAVED_MODEL" ]; then printf '%s' "$SAVED_MODEL" > "$PHONE_ACTIVE_FILE"; else rm -f "$PHONE_ACTIVE_FILE"; fi; }
trap restore EXIT

IPRE='^[0-9]{1,3}(\.[0-9]{1,3}){3}$'

# ───────── 1. Синтаксис всех скриптов ─────────
hdr "Синтаксис (bash -n)"
for f in "$HERE"/*.sh; do
  if bash -n "$f" 2>/dev/null; then ok "$(basename "$f")"; else no "$(basename "$f") синтаксис"; fi
done

# ───────── 2. config-хелперы определены ─────────
hdr "config.sh хелперы"
for fn in active_model active_serial active_ip active_ssh_ok adb_dev pick_usb pick_wifi phone_ip write_ip_cache _to; do
  if type "$fn" >/dev/null 2>&1; then ok "$fn() есть"; else no "$fn() НЕ определён"; fi
done

# ───────── 3. _to: таймаут и отсутствие сирот ─────────
hdr "_to (таймаут-хелпер)"
t0=$(date +%s); _to 1 sleep 5; rc=$?; t1=$(date +%s)
if [ "$rc" -ne 0 ] && [ $((t1-t0)) -le 3 ]; then ok "_to 1 sleep 5 прервал за $((t1-t0))с (rc=$rc)"; else no "_to не сработал (rc=$rc, $((t1-t0))с)"; fi
sleep 1
if [ "$(pgrep -c -f 'sleep 5' 2>/dev/null || echo 0)" -eq 0 ]; then ok "сирот sleep не осталось"; else no "остались сироты sleep"; fi

# ───────── 4. write_ip_cache: валидация ─────────
hdr "write_ip_cache (валидация IP)"
BAK=$(cat "$PHONE_IP_CACHE" 2>/dev/null)
write_ip_cache "10.20.30.40" >/dev/null 2>&1
[ "$(cat "$PHONE_IP_CACHE" 2>/dev/null)" = "10.20.30.40" ] && ok "валидный IP записан" || no "валидный IP не записан"
write_ip_cache "garbage; rm -rf" >/dev/null 2>&1
[ "$(cat "$PHONE_IP_CACHE" 2>/dev/null)" = "10.20.30.40" ] && ok "мусорный IP отклонён" || no "мусорный IP прошёл (!)"
[ -n "$BAK" ] && printf '%s' "$BAK" > "$PHONE_IP_CACHE" || rm -f "$PHONE_IP_CACHE"

# ───────── 5. phone-devices.sh формат ─────────
hdr "phone-devices.sh"
DEVOUT=$(bash "$HERE/phone-devices.sh" 2>/dev/null)
if [ -z "$DEVOUT" ]; then
  skip "нет подключённых устройств"
  HAVE_DEV=0
else
  HAVE_DEV=1
  badfmt=0; while IFS= read -r l; do [ "$(printf '%s' "$l" | awk -F'\t' '{print NF}')" -eq 4 ] || badfmt=1; done <<<"$DEVOUT"
  [ "$badfmt" -eq 0 ] && ok "все строки = 4 TAB-поля" || no "формат строк сломан"
  nact=$(printf '%s\n' "$DEVOUT" | awk -F'\t' '$4=="*"' | wc -l | tr -d ' ')
  [ "$nact" -eq 1 ] && ok "ровно один активный (*)" || no "активных помечено: $nact (ожидалось 1)"
fi

# ───────── 6. transport авто-выбор канала ─────────
hdr "phone-transport.sh (авто-выбор канала)"
T=$(_to 20 bash "$HERE/phone-transport.sh" 2>/dev/null); KIND="${T%%|*}"
case "$KIND" in
  usb|wifi-ssh|wifi-adb) ok "канал валиден: $T" ;;
  none) skip "канал none (телефон недоступен)" ;;
  *) no "невалидный вывод transport: '$T'" ;;
esac

# ───────── 7. active_ip формат ─────────
hdr "active_ip"
if [ "$HAVE_DEV" = 1 ]; then
  AIP=$(active_ip)
  if [ -z "$AIP" ]; then skip "active_ip пуст (нет Wi-Fi/кэша)"; \
  elif [[ "$AIP" =~ $IPRE ]]; then ok "active_ip = $AIP (валидный IP)"; \
  else no "active_ip не IP: '$AIP'"; fi
else skip "нет устройств"; fi

# определить, доступен ли SSH у активного (для тестов 8–11)
SSH_OK=$(active_ssh_ok 2>/dev/null)
AIP=$(active_ip 2>/dev/null)

# ───────── 8. Статус диска (df /sdcard) ─────────
hdr "Статус диска"
if [ "$SSH_OK" = yes ] && [ -n "$AIP" ]; then
  DF=$(_to 8 ssh -i "$PHONE_SSH_KEY" -p "$PHONE_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$PHONE_SSH_USER@$AIP" "df -k /sdcard 2>/dev/null | tail -1" 2>/dev/null)
  TOTAL=$(printf '%s' "$DF" | awk '{print $2}')
  if [ -n "$TOTAL" ] && [ "$TOTAL" -gt 0 ] 2>/dev/null; then ok "df /sdcard: total=${TOTAL}KB (>0)"; else no "df не распарсился: '$DF'"; fi
else skip "нет SSH к активному — пропуск df"; fi

# ───────── 9. Стрим с range (HTTP 206) ─────────
hdr "Стрим (rclone serve http, range)"
if [ "$SSH_OK" = yes ] && [ -n "$AIP" ]; then
  RF=$(_to 8 ssh -i "$PHONE_SSH_KEY" -p "$PHONE_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$PHONE_SSH_USER@$AIP" \
        "find /sdcard/DCIM /sdcard/Download -type f -size +3k 2>/dev/null | head -1" 2>/dev/null | tr -d '\r')
  if [ -z "$RF" ]; then skip "не нашёл файл на телефоне для стрима"; else
    DIR=$(dirname "$RF"); BASE=$(basename "$RF")
    PORT=8973
    pkill -f "rclone serve http.*:$PORT" 2>/dev/null
    nohup "$RCLONE" serve http ":sftp,host=$AIP,port=$PHONE_SSH_PORT,user=$PHONE_SSH_USER,key_file=$PHONE_SSH_KEY,shell_type=none:$DIR" \
      --addr "127.0.0.1:$PORT" --read-only >/tmp/test-stream.log 2>&1 & disown
    for i in $(seq 1 40); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.1; done
    ENC=$(/usr/bin/python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$BASE" 2>/dev/null)
    CODE=$(curl -s -o /tmp/test-chunk.bin -w "%{http_code}" -r 0-1023 "http://127.0.0.1:$PORT/$ENC")
    SZ=$(stat -f%z /tmp/test-chunk.bin 2>/dev/null || echo 0)
    if [ "$CODE" = "206" ] && [ "$SZ" -le 2048 ] && [ "$SZ" -gt 0 ]; then ok "range: HTTP 206, $SZ байт (частичный, не весь файл)"; else no "range провал: code=$CODE size=$SZ"; fi
    pkill -f "rclone serve http.*:$PORT" 2>/dev/null; rm -f /tmp/test-chunk.bin
  fi
else skip "нет SSH к активному — пропуск стрима"; fi

# ───────── 10. Upload (мультипоток rclone copy) ─────────
hdr "Upload (rclone copy --transfers)"
if [ "$SSH_OK" = yes ]; then
  TF="/tmp/test-up-$$.txt"; echo "regress $(date +%s)" > "$TF"
  OUT=$(bash "$HERE/phone-upload.sh" "$TF" 2>&1)
  GONE=$(_to 8 ssh -i "$PHONE_SSH_KEY" -p "$PHONE_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$PHONE_SSH_USER@$AIP" \
        "[ -f /sdcard/Download/$(basename "$TF") ] && echo YES && rm -f /sdcard/Download/$(basename "$TF")" 2>/dev/null | tr -d '\r')
  [ "$GONE" = "YES" ] && ok "файл загружен на телефон и подтверждён" || no "upload не подтверждён ($OUT)"
  rm -f "$TF"
else skip "нет SSH к активному — пропуск upload"; fi

# ───────── 11. Download из интернета на телефон ─────────
hdr "Download (rclone copyurl)"
if [ "$SSH_OK" = yes ]; then
  OUT=$(bash "$HERE/phone-download.sh" "https://raw.githubusercontent.com/git/git/master/README.md" 2>&1)
  GONE=$(_to 8 ssh -i "$PHONE_SSH_KEY" -p "$PHONE_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$PHONE_SSH_USER@$AIP" \
        "[ -f /sdcard/Download/README.md ] && echo YES && rm -f /sdcard/Download/README.md" 2>/dev/null | tr -d '\r')
  [ "$GONE" = "YES" ] && ok "URL скачан прямо на телефон" || no "download не подтверждён ($OUT)"
else skip "нет SSH к активному — пропуск download"; fi

# ───────── 12. keepalive: caffeinate-менеджмент + только USB ─────────
hdr "keepalive (caffeinate при USB)"
if [ -n "$(pick_usb)" ]; then
  pkill -f phone-keepalive.sh 2>/dev/null; rmdir /tmp/phone-keepalive.lock 2>/dev/null; pkill -f "caffeinate -ism" 2>/dev/null; sleep 1
  nohup bash "$HERE/phone-keepalive.sh" >/dev/null 2>&1 & disown
  sleep 7
  pgrep -f "caffeinate -ism" >/dev/null && ok "caffeinate поднят при подключённом USB" || no "caffeinate не поднялся"
  pkill -f phone-keepalive.sh 2>/dev/null; rmdir /tmp/phone-keepalive.lock 2>/dev/null; pkill -f "caffeinate -ism" 2>/dev/null
else skip "нет USB-устройства — пропуск keepalive"; fi

# ───────── ИТОГ ─────────
printf "\n──────── ИТОГ: \033[32m%d PASS\033[0m / \033[31m%d FAIL\033[0m / \033[33m%d SKIP\033[0m ────────\n" "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
