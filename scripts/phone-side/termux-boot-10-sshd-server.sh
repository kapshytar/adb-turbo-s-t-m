#!/data/data/com.termux/files/usr/bin/sh
# Сервер-режим: sshd при загрузке + САМОВОССТАНОВЛЕНИЕ + wake-lock (телефон на зарядке в шкафу).
termux-wake-lock
sshd
(
  while true; do
    pgrep -x sshd >/dev/null || sshd      # упал → поднять
    termux-wake-lock                       # держать связь живой (на зарядке не жалко)
    sleep 30
  done
) >/dev/null 2>&1 &
