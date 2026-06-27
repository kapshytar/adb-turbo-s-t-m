#!/data/data/com.termux/files/usr/bin/sh
[ -f ~/.sshd-watchdog.pid ] && kill -0 $(cat ~/.sshd-watchdog.pid) 2>/dev/null && exit 0
echo $$ > ~/.sshd-watchdog.pid
termux-wake-lock
while true; do
  pgrep -x sshd >/dev/null || sshd
  termux-wake-lock
  sleep 30
done
