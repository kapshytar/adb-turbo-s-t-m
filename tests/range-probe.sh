#!/bin/bash
# range-probe.sh — проверка HTTP/Range-контракта СТРИМ-СЕРВЕРА по URL.
#
# Зачем: ядро стрима существует в трёх независимых реализациях (adb_stream.py,
# ADBFileExplorer/stream_server.py, filedroid/stream_server.dart). Общего кода у них
# быть не может — разные рантаймы. Общим остаётся КОНТРАКТ, и вот он.
# Баг «QuickTime err -11828» (URL без расширения) чинили в Dart-копии, а в Python-копии
# он прожил ещё месяц: этот скрипт ловит такое в любой из них за 2 секунды.
#
# Использование: range-probe.sh "http://127.0.0.1:8970/video.mp4"
#   (сервер должен быть уже запущен и отдавать этот URL)
set -u
[ $# -ge 1 ] || { echo "usage: range-probe.sh URL"; exit 2; }
URL="$1"
PASS=0; FAIL=0
ok(){   printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad(){  printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# h <range> → заголовки ответа (пустой range = обычный GET)
h(){ if [ -n "$1" ]; then curl -sS -D- -o /dev/null -r "$1" "$URL"; else curl -sS -D- -o /dev/null "$URL"; fi; }
code(){ printf '%s' "$1" | awk 'NR==1{print $2}'; }
hdr(){  printf '%s' "$1" | tr -d '\r' | awk -F': ' -v k="$2" 'tolower($1)==tolower(k){print $2; exit}'; }
# blen <range> → сколько байт реально пришло
blen(){ curl -sS -o /tmp/.range-probe.bin -r "$1" "$URL"; stat -f%z /tmp/.range-probe.bin 2>/dev/null || echo 0; }

echo "проверяю $URL"

# 1) обычный GET: 200 + объявленная поддержка range + размер
R=$(h ""); SIZE=$(hdr "$R" Content-Length)
[ "$(code "$R")" = 200 ]                  && ok "GET без Range → 200"        || bad "GET без Range" "код $(code "$R")"
[ "$(hdr "$R" Accept-Ranges)" = bytes ]   && ok "Accept-Ranges: bytes"       || bad "Accept-Ranges" "нет/не bytes"
[ -n "$SIZE" ] && [ "$SIZE" -gt 0 ] 2>/dev/null \
                                          && ok "Content-Length = $SIZE"     || bad "Content-Length" "пустой"

# 2) MIME по расширению — иначе QuickTime не опознаёт контейнер (err -11828)
CT=$(hdr "$R" Content-Type)
case "$CT" in video/*|audio/*) ok "Content-Type = $CT" ;; *) bad "Content-Type" "'$CT' не media" ;; esac
case "${URL##*/}" in *.*) ok "в URL есть имя с расширением" ;; *) bad "URL без расширения" "QuickTime не опознает контейнер" ;; esac

# 3) начальный range — с него плеер читает moov/заголовок
R=$(h "0-1")
[ "$(code "$R")" = 206 ]                            && ok "bytes=0-1 → 206"  || bad "bytes=0-1" "код $(code "$R")"
[ "$(hdr "$R" Content-Range)" = "bytes 0-1/$SIZE" ] && ok "Content-Range 0-1" || bad "Content-Range 0-1" "'$(hdr "$R" Content-Range)'"
[ "$(blen 0-1)" = 2 ]                               && ok "тело 0-1 = 2 байта" || bad "тело 0-1" "$(blen 0-1) байт"

# 4) suffix-range — так плееры достают moov в конце mp4
[ "$(code "$(h -500)")" = 206 ] && ok "bytes=-500 → 206"     || bad "bytes=-500" "код $(code "$(h -500)")"
[ "$(blen -500)" = 500 ]        && ok "тело -500 = 500 байт" || bad "тело -500" "$(blen -500) байт"

# 5) середина файла — обычный seek
if [ -n "$SIZE" ] && [ "$SIZE" -gt 2048 ] 2>/dev/null; then
  M=$((SIZE/2)); E=$((M+99))
  R=$(h "$M-$E")
  [ "$(code "$R")" = 206 ]                              && ok "seek в середину → 206" || bad "seek" "код $(code "$R")"
  [ "$(hdr "$R" Content-Range)" = "bytes $M-$E/$SIZE" ] && ok "Content-Range середины" || bad "Content-Range середины" "'$(hdr "$R" Content-Range)'"
fi

# 6) за EOF → 416 (иначе плеер зациклится на ретраях)
[ "$(code "$(h "$((SIZE + 9999))-")")" = 416 ] && ok "range за EOF → 416" || bad "range за EOF" "код $(code "$(h "$((SIZE + 9999))-")")"

# 7) query-string не должен давать 404 (плееры/прокси дописывают '?...')
Q=$(curl -sS -D- -o /dev/null -r 0-9 "$URL?probe=1" | awk 'NR==1{print $2}')
case "$Q" in 200|206) ok "URL с ?query → $Q" ;; *) bad "URL с ?query" "код $Q (путь сравнивается без urlsplit)" ;; esac

rm -f /tmp/.range-probe.bin
printf '\n──── %d PASS / %d FAIL ────\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
