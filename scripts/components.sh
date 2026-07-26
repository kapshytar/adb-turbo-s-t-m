#!/bin/bash
# components.sh — управление сторонними компонентами (GPLv3), которые НЕ лежат в этом репо.
#
# Зачем: этот репо под MIT, компоненты под GPLv3 — их исходники сюда затаскивать нельзя.
# Но и «лежат где-то рядом на диске» — путаница. Компромисс: репо хранит УКАЗАТЕЛЬ
# (components.conf), а код живёт в наших форках.
#
#   status  — что стоит, на чём стоит, где разошлось с пином, что не запушено
#   sync    — поставить недостающее и перевести на пины (свежая машина = одна команда)
#   pin     — записать в components.conf текущие HEAD'ы (после правки компонента)
#
# ГЛАВНОЕ ПРАВИЛО: правку компонента коммитим В ЕГО ФОРК и пушим в remote `fork`,
# потом здесь `pin`. В этот репо GPL-код не переносим никогда.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
CONF="$REPO/components.conf"
ROOT="${COMPONENTS_ROOT:-$HOME/PhoneAsExtStorage}"

[ -f "$CONF" ] || { echo "нет $CONF"; exit 2; }

g(){ git -C "$1" "${@:2}" 2>/dev/null; }
rows(){ grep -v '^[[:space:]]*#' "$CONF" | grep -v '^[[:space:]]*$'; }

cmd_status(){
  printf '%-18s %-6s %-9s %s\n' КОМПОНЕНТ ТИП КОММИТ СОСТОЯНИЕ
  rows | while IFS='|' read -r name kind path upstream fork branch pin; do
    dir="$ROOT/$path"
    if [ ! -d "$dir/.git" ]; then
      printf '%-18s %-6s %-9s %s\n' "$name" "$kind" "—" "НЕ УСТАНОВЛЕН → components.sh sync"
      continue
    fi
    cur="$(g "$dir" rev-parse --short HEAD)"
    st=""
    [ -n "$(g "$dir" status --porcelain)" ] && st="незакоммиченное; "
    if [ "$kind" = fork ]; then
      [ "$cur" != "$pin" ] && st="${st}pin=$pin ≠ HEAD; "
      # Вопрос «запушено ли» = «лежит ли ЭТОТ коммит на форке хоть где-то».
      # Сравнивать с fork/<текущая ветка> нельзя: локальная ветка бывает старой
      # feature-веткой, тогда счётчик врёт (ловилось на filedroid: 10 «непушенных»,
      # которые на самом деле все лежат в fork/main).
      g "$dir" branch -r --contains HEAD | grep -q 'fork/' || st="${st}НЕ ЗАПУШЕНО в fork; "
    fi
    [ -z "$st" ] && st="ок"
    printf '%-18s %-6s %-9s %s\n' "$name" "$kind" "$cur" "${st%; }"
  done
  echo
  echo "правки компонентов → коммит в его форк (remote 'fork'), потом: components.sh pin"
}

cmd_sync(){
  rows | while IFS='|' read -r name kind path upstream fork branch pin; do
    dir="$ROOT/$path"
    if [ ! -d "$dir/.git" ]; then
      echo "── $name: ставлю в $dir"
      # origin = upstream (чужой оригинал), fork = наш — так же, как в уже стоящих копиях
      git clone --quiet "$upstream" "$dir" || { echo "   клон не удался"; continue; }
      if [ "$kind" = fork ]; then
        g "$dir" remote add fork "$fork"
        g "$dir" fetch --quiet fork
        g "$dir" checkout --quiet -B "$branch" "fork/$branch"
      fi
    fi
    if [ "$kind" = fork ] && [ -n "$pin" ] && [ "$pin" != - ]; then
      cur="$(g "$dir" rev-parse --short HEAD)"
      if [ "$cur" != "$pin" ]; then
        echo "── $name: $cur → pin $pin"
        g "$dir" fetch --quiet fork
        g "$dir" checkout --quiet "$pin" || echo "   коммит $pin не найден — запушен ли он в fork?"
      fi
    fi
    [ "$kind" = patch ] && echo "── $name: своего форка нет — накатить patch/*.patch вручную (см. README)"
  done
  echo "готово."
}

cmd_pin(){
  tmp="$CONF.tmp.$$"; changed=0
  while IFS= read -r line; do
    case "$line" in ''|\#*) printf '%s\n' "$line" >> "$tmp"; continue;; esac
    IFS='|' read -r name kind path upstream fork branch pin <<< "$line"
    if [ "$kind" != fork ]; then printf '%s\n' "$line" >> "$tmp"; continue; fi
    dir="$ROOT/$path"; cur="$(g "$dir" rev-parse --short HEAD)"
    if [ -z "$cur" ]; then printf '%s\n' "$line" >> "$tmp"; continue; fi
    br="$(g "$dir" rev-parse --abbrev-ref HEAD)"
    if [ "$cur" != "$pin" ] || [ "$br" != "$branch" ]; then
      echo "$name: $branch@$pin → $br@$cur"
      g "$dir" branch -r --contains HEAD | grep -q 'fork/' || \
        echo "  ⚠ этого коммита НЕТ на форке — пин будет висеть в воздухе, сперва запушь"
      changed=1
    fi
    printf '%s|%s|%s|%s|%s|%s|%s\n' "$name" "$kind" "$path" "$upstream" "$fork" "$br" "$cur" >> "$tmp"
  done < "$CONF"
  mv "$tmp" "$CONF"
  [ "$changed" = 0 ] && echo "пины уже актуальны." || echo "components.conf обновлён — закоммить его."
}

case "${1:-status}" in
  status) cmd_status ;;
  sync)   cmd_sync ;;
  pin)    cmd_pin ;;
  *) echo "usage: components.sh [status|sync|pin]"; exit 2 ;;
esac
