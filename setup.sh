#!/usr/bin/env bash
# setup.sh — интерактивный визард "Phone as External Storage"
# Стек: macFUSE + adbfs (FUSE-маунт) и/или rclone+sftp (no-copy стрим через Termux sshd)
# Идемпотентно — безопасно перезапускать на любом этапе.
# Требования: macOS Intel или Apple Silicon (Homebrew), bash 3.2+
set -uo pipefail

# ────────────────────────────────────────────────────────────
#  Цвета / декор
# ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
ok()   { echo -e "  ${GREEN}[✓]${RESET} $*"; }
fail() { echo -e "  ${RED}[✗]${RESET} $*"; }
info() { echo -e "  ${CYAN}[i]${RESET} $*"; }
warn() { echo -e "  ${YELLOW}[!]${RESET} $*"; }
step() { echo -e "\n${BOLD}${CYAN}══ $* ${RESET}"; }
ask()  { echo -e -n "  ${BOLD}${YELLOW}?${RESET} $* "; }

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$REPO_DIR/scripts"

# Конфиг-файл (сохраняется между запусками)
CONFIG="$HOME/.phone_stream_config"
PHONE_USER=""
SSH_KEY="$HOME/.ssh/id_ed25519_phone"

load_config() {
  [ -f "$CONFIG" ] && . "$CONFIG"
}
save_config() {
  cat > "$CONFIG" <<EOF
PHONE_USER="$PHONE_USER"
SSH_KEY="$SSH_KEY"
EOF
}

# ────────────────────────────────────────────────────────────
#  ШАГ 0: Приветствие
# ────────────────────────────────────────────────────────────
print_header() {
  echo -e "${BOLD}"
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║      Phone as External Storage — Setup Wizard            ║"
  echo "║  git clone → ./setup.sh → телефон как диск Finder        ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo -e "${RESET}"
  echo "  Этот визард проведёт через все шаги настройки."
  echo "  Безопасно перезапускать — уже сделанные шаги пропускаются."
  echo ""
  echo "  Стек rclone+Termux (Stream Mode):"
  echo "    macOS ← rclone/sftp ← adb forward ← Termux sshd ← Android"
  echo ""
  echo "  Стек adbfs (FUSE Mode, для Finder-тегов/EXIF):"
  echo "    macOS ← macFUSE ← adbfs ← ADB ← Android"
  echo ""
  ask "Нажми Enter чтобы начать..."
  read -r _
}

# ────────────────────────────────────────────────────────────
#  ШАГ 1: Homebrew
# ────────────────────────────────────────────────────────────
check_brew() {
  step "Шаг 1/9 — Homebrew"
  if command -v brew >/dev/null 2>&1; then
    ok "Homebrew найден: $(brew --prefix)"
    return 0
  fi
  fail "Homebrew не найден."
  info "Homebrew нужен для установки зависимостей (macFUSE, adb)."
  info "Установи вручную: https://brew.sh"
  echo ""
  echo '    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  echo ""
  ask "После установки Homebrew нажми Enter для продолжения..."
  read -r _
  if ! command -v brew >/dev/null 2>&1; then
    fail "Homebrew всё ещё не найден. Прерываю."; exit 1
  fi
  ok "Homebrew установлен."
}

# ────────────────────────────────────────────────────────────
#  ШАГ 2: macFUSE
# ────────────────────────────────────────────────────────────
install_macfuse() {
  step "Шаг 2/9 — macFUSE (kernel extension для FUSE-маунта)"
  if [ -d "/Library/Filesystems/macfuse.fs" ]; then
    ok "macFUSE уже установлен (/Library/Filesystems/macfuse.fs)"
    return 0
  fi
  warn "macFUSE не найден. Это kernel extension — потребует одобрения и ПЕРЕЗАГРУЗКИ."
  echo ""
  echo "  Шаги после установки:"
  echo "  1. macOS откроет уведомление о блокировке kext"
  echo "  2. Зайди: System Settings → Privacy & Security → прокрути вниз"
  echo "  3. Найди «System software from developer Benjamin Fleischer»"
  echo "  4. Нажми «Allow» → введи пароль"
  echo "  5. ПЕРЕЗАГРУЗИ Mac (без этого mount не работает)"
  echo "  6. После перезагрузки снова запусти ./setup.sh"
  echo ""
  ask "Установить macFUSE сейчас? [y/N] "
  read -r ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    brew install --cask macfuse
    echo ""
    warn "macFUSE установлен. Теперь:"
    warn "  1. Зайди System Settings → Privacy & Security → Allow (macFUSE kext)"
    warn "  2. ПЕРЕЗАГРУЗИ Mac"
    warn "  3. Запусти ./setup.sh снова"
    exit 0
  else
    warn "Пропускаем macFUSE. FUSE-маунт (adbfs) работать не будет."
    warn "rclone Stream Mode всё равно доступен без macFUSE."
  fi
}

# ────────────────────────────────────────────────────────────
#  ШАГ 3: rclone (официальный бинарь — brew-версия не умеет mount)
# ────────────────────────────────────────────────────────────
install_rclone() {
  step "Шаг 3/9 — rclone (официальный бинарь)"

  # Проверяем что rclone умеет mount (brew-сборка не умеет)
  for _rc_check in /usr/local/bin/rclone /opt/homebrew/bin/rclone; do
    if [ -x "$_rc_check" ] && "$_rc_check" mount --help >/dev/null 2>&1; then
      ok "rclone найден: $_rc_check — поддерживает mount"
      return 0
    fi
  done

  if command -v rclone >/dev/null 2>&1; then
    RCLONE_PATH="$(command -v rclone)"
    if "$RCLONE_PATH" mount --help >/dev/null 2>&1; then
      ok "rclone найден ($RCLONE_PATH) — поддерживает mount"
      return 0
    else
      warn "rclone найден ($RCLONE_PATH), но НЕ поддерживает mount (вероятно brew-сборка)."
      warn "Нужен официальный бинарь."
    fi
  fi

  # Определяем архитектуру и целевую папку для бинаря
  ARCH="$(uname -m)"
  if [ "$ARCH" = "arm64" ]; then
    RCLONE_ARCH="osx-arm64"
    info "Определена архитектура: Apple Silicon (arm64)"
  else
    RCLONE_ARCH="osx-amd64"
    info "Определена архитектура: Intel (amd64)"
  fi

  # Целевая папка: /usr/local/bin если существует, иначе $(dirname $(which brew)) или /opt/homebrew/bin
  if [ -d "/usr/local/bin" ]; then
    INSTALL_DIR="/usr/local/bin"
  else
    BREW_BIN="$(dirname "$(which brew 2>/dev/null)" 2>/dev/null || true)"
    INSTALL_DIR="${BREW_BIN:-/opt/homebrew/bin}"
  fi
  RCLONE_DEST="$INSTALL_DIR/rclone"

  info "Устанавливаем официальный rclone ($RCLONE_ARCH) → $RCLONE_DEST ..."
  TMPDIR_RC="$(mktemp -d)"
  RCLONE_ZIP="$TMPDIR_RC/rclone.zip"

  curl -fsSL "https://downloads.rclone.org/rclone-current-${RCLONE_ARCH}.zip" -o "$RCLONE_ZIP" || {
    fail "Не удалось скачать rclone. Проверь интернет."
    exit 1
  }
  unzip -q "$RCLONE_ZIP" -d "$TMPDIR_RC"
  RCLONE_BIN=$(find "$TMPDIR_RC" -name "rclone" -type f | head -1)
  if [ -z "$RCLONE_BIN" ]; then
    fail "rclone бинарь не найден в архиве."; exit 1
  fi

  sudo install -m 755 "$RCLONE_BIN" "$RCLONE_DEST"
  # Снять quarantine (иначе macOS заблокирует)
  sudo xattr -d com.apple.quarantine "$RCLONE_DEST" 2>/dev/null || true
  rm -rf "$TMPDIR_RC"

  if "$RCLONE_DEST" mount --help >/dev/null 2>&1; then
    ok "rclone установлен: $("$RCLONE_DEST" --version | head -1)"
  else
    fail "rclone установлен, но mount не работает. Странно."; exit 1
  fi
}

# ────────────────────────────────────────────────────────────
#  ШАГ 4: ADB
# ────────────────────────────────────────────────────────────
check_adb() {
  step "Шаг 4/9 — ADB (Android Debug Bridge)"

  # Приоритет: Android SDK, потом brew
  ADB_CANDIDATES=(
    "$HOME/Library/Android/sdk/platform-tools/adb"
    "/usr/local/bin/adb"
    "$(command -v adb 2>/dev/null || true)"
  )
  ADB_BIN=""
  for c in "${ADB_CANDIDATES[@]}"; do
    if [ -x "$c" ]; then ADB_BIN="$c"; break; fi
  done

  if [ -n "$ADB_BIN" ]; then
    ok "adb найден: $ADB_BIN ($("$ADB_BIN" version | head -1))"
    return 0
  fi

  warn "adb не найден."
  ask "Установить через Homebrew (android-platform-tools)? [y/N] "
  read -r ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    brew install --cask android-platform-tools
    ADB_BIN="$(command -v adb 2>/dev/null || true)"
    if [ -n "$ADB_BIN" ]; then
      ok "adb установлен: $ADB_BIN"
    else
      fail "adb не найден после установки. Проверь PATH."; exit 1
    fi
  else
    fail "adb обязателен. Установи вручную: brew install --cask android-platform-tools"; exit 1
  fi
}

# ────────────────────────────────────────────────────────────
#  Утилита: найти ADB
# ────────────────────────────────────────────────────────────
find_adb() {
  for c in \
    "$HOME/Library/Android/sdk/platform-tools/adb" \
    "/usr/local/bin/adb" \
    "$(command -v adb 2>/dev/null || true)"; do
    if [ -x "$c" ]; then echo "$c"; return; fi
  done
  echo "adb"
}

# ────────────────────────────────────────────────────────────
#  ШАГ 5: Телефон — USB/Wi-Fi ADB + Termux
# ────────────────────────────────────────────────────────────
setup_phone_adb() {
  step "Шаг 5/9 — Подключение телефона (ADB)"
  ADB="$(find_adb)"

  echo "  На телефоне нужно (один раз):"
  echo "  1. Настройки → О телефоне → нажать «Номер сборки» 7 раз"
  echo "     (разблокирует Developer Options / Параметры разработчика)"
  echo "  2. Настройки → Параметры разработчика → USB-отладка → ВКЛ"
  echo "  3. Подключи телефон по USB, разреши отладку на экране телефона"
  echo ""
  echo "  Для Wi-Fi ADB (без провода):"
  echo "  Настройки → Параметры разработчика → Беспроводная отладка → ВКЛ"
  echo "  (Samsung Knox блокирует старый метод adb tcpip 5555 — только Wireless Debugging)"
  echo ""
  ask "Нажми Enter когда телефон готов..."
  read -r _

  local tries=0
  while true; do
    # Проверяем USB-устройства
    DEV=$("$ADB" devices 2>/dev/null | awk '/\tdevice$/{print $1}' | grep -v '_adb-tls' | grep -v ':' | head -1)

    if [ -z "$DEV" ]; then
      # Пробуем Wi-Fi mDNS
      EP=$("$ADB" mdns services 2>/dev/null | awk '/_adb-tls-connect._tcp/{print $NF; exit}')
      if [ -n "$EP" ]; then
        "$ADB" connect "$EP" >/dev/null 2>&1 || true
        DEV=$("$ADB" devices 2>/dev/null | awk '/\tdevice$/{print $1}' | grep -E '_adb-tls|:' | head -1)
      fi
    fi

    if [ -n "$DEV" ]; then
      ok "Телефон найден: $DEV"
      PHONE_SERIAL="$DEV"
      break
    fi

    tries=$((tries+1))
    if [ $tries -ge 3 ]; then
      fail "Телефон не найден после нескольких попыток."
      echo ""
      echo "  Проверь:"
      echo "  - USB-кабель подключён"
      echo "  - На экране телефона появился запрос «Разрешить отладку» — нажми OK"
      echo "  - Или включи Беспроводную отладку в Параметрах разработчика"
      echo ""
      ask "Нажми Enter чтобы попробовать снова, или Ctrl+C для выхода..."
      read -r _
      tries=0
    else
      warn "Телефон не найден, жду 3 секунды..."
      sleep 3
    fi
  done
}

# ────────────────────────────────────────────────────────────
#  ШАГ 6: Termux + sshd на телефоне
# ────────────────────────────────────────────────────────────
setup_termux() {
  step "Шаг 6/9 — Termux + sshd на телефоне"
  ADB="$(find_adb)"
  local PHONE_SER="${PHONE_SERIAL:-}"
  [ -z "$PHONE_SER" ] && PHONE_SER=$("$ADB" devices 2>/dev/null | awk '/\tdevice$/{print $1}' | head -1)

  # Проверяем наличие Termux
  if "$ADB" -s "$PHONE_SER" shell "pm list packages 2>/dev/null" 2>/dev/null | grep -q "com.termux"; then
    ok "Termux установлен на телефоне"
  else
    warn "Termux не найден на телефоне."
    echo ""
    echo "  Termux нельзя поставить автоматически — нужен F-Droid (не Play Store):"
    echo ""
    echo "  1. На телефоне скачай F-Droid: https://f-droid.org"
    echo "  2. Установи F-Droid, открой, найди Termux → установи"
    echo "  3. Открой Termux, подожди инициализации"
    echo ""
    ask "Нажми Enter когда Termux установлен и открыт..."
    read -r _
  fi

  echo ""
  info "Теперь нужно настроить Termux вручную. Набери эти команды в Termux на телефоне:"
  echo ""
  echo "  ┌─────────────────────────────────────────────────────────┐"
  echo "  │  pkg update -y && pkg install -y openssh                │"
  echo "  │  termux-setup-storage    # разреши доступ к файлам!     │"
  echo "  │  sshd                    # запустить SSH-сервер         │"
  echo "  │  passwd                  # задать пароль (для 1й копии ключа) │"
  echo "  └─────────────────────────────────────────────────────────┘"
  echo ""
  warn "ВАЖНО: когда выполнишь termux-setup-storage — телефон попросит разрешение."
  warn "Нажми «Allow» / «Разрешить». Без этого /sdcard будет недоступен!"
  echo ""
  ask "Нажми Enter когда выполнил все команды в Termux..."
  read -r _

  # Проверяем что sshd отвечает через adb forward
  info "Проверяю sshd через adb forward..."
  "$ADB" -s "$PHONE_SER" forward tcp:8022 tcp:8022 >/dev/null 2>&1
  sleep 1

  local tries=0
  while ! nc -z -G 3 127.0.0.1 8022 2>/dev/null; do
    tries=$((tries+1))
    if [ $tries -ge 5 ]; then
      fail "sshd на порту 8022 не отвечает."
      echo ""
      echo "  Убедись что в Termux выполнено: sshd"
      echo "  Можешь проверить в Termux: pgrep sshd && echo OK"
      echo ""
      ask "Нажми Enter чтобы попробовать снова..."
      read -r _
      "$ADB" -s "$PHONE_SER" forward tcp:8022 tcp:8022 >/dev/null 2>&1
      tries=0
    else
      sleep 2
    fi
  done
  ok "sshd на телефоне отвечает на порту 8022"
}

# ────────────────────────────────────────────────────────────
#  ШАГ 7: SSH-ключ + rclone remote
# ────────────────────────────────────────────────────────────
setup_phone_ssh() {
  step "Шаг 7/9 — SSH-ключ и rclone remote"
  ADB="$(find_adb)"
  local PHONE_SER="${PHONE_SERIAL:-}"
  [ -z "$PHONE_SER" ] && PHONE_SER=$("$ADB" devices 2>/dev/null | awk '/\tdevice$/{print $1}' | head -1)

  # Генерируем ключ если нет
  if [ ! -f "$SSH_KEY" ]; then
    info "Генерирую SSH-ключ $SSH_KEY ..."
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "phone-stream"
    ok "Ключ создан: $SSH_KEY"
  else
    ok "SSH-ключ уже существует: $SSH_KEY"
  fi

  # Определяем пользователя телефона
  if [ -z "$PHONE_USER" ]; then
    info "Узнаю имя пользователя на телефоне через SSH..."
    "$ADB" -s "$PHONE_SER" forward tcp:8022 tcp:8022 >/dev/null 2>&1
    # Пробуем через ssh с паролем
    echo ""
    info "Нужен SSH с паролем (один раз) чтобы залить ключ."
    ask "Имя пользователя Termux (обычно что-то вроде u0_a520, или нажми Enter для автоопределения): "
    read -r input_user
    if [ -n "$input_user" ]; then
      PHONE_USER="$input_user"
    else
      # Пытаемся получить через заданный пароль
      echo ""
      info "Пытаюсь определить пользователя через ssh whoami..."
      info "Введи пароль Termux когда спросят:"
      PHONE_USER=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -p 8022 \
        "$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -p 8022 127.0.0.1 whoami 2>/dev/null)" \
        127.0.0.1 whoami 2>/dev/null || true)
      # Если не получилось — спросим снова
      if [ -z "$PHONE_USER" ]; then
        info "Введи пароль Termux:"
        PHONE_USER=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -p 8022 127.0.0.1 whoami 2>/dev/null || true)
      fi
      [ -z "$PHONE_USER" ] && PHONE_USER="u0_a"
    fi
    save_config
    ok "Пользователь: $PHONE_USER"
  else
    ok "Пользователь (из кэша): $PHONE_USER"
  fi

  # Проверяем есть ли уже беспарольный доступ
  info "Проверяю беспарольный SSH-доступ..."
  "$ADB" -s "$PHONE_SER" forward tcp:8022 tcp:8022 >/dev/null 2>&1
  if ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 \
       -i "$SSH_KEY" -p 8022 127.0.0.1 echo OK 2>/dev/null | grep -q OK; then
    ok "Беспарольный SSH уже работает"
  else
    info "Заливаю публичный ключ на телефон..."
    echo ""
    echo "  Способ 1 (рекомендован): ssh-copy-id"
    echo "  Введи пароль Termux когда попросят:"
    echo ""
    if ssh-copy-id -i "$SSH_KEY.pub" -p 8022 \
         -o StrictHostKeyChecking=no \
         -o ConnectTimeout=10 \
         127.0.0.1 2>/dev/null; then
      ok "Ключ скопирован через ssh-copy-id"
    else
      warn "ssh-copy-id не сработал. Пробую вручную..."
      PUBKEY=$(cat "$SSH_KEY.pub")
      ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p 8022 127.0.0.1 \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$PUBKEY' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" 2>/dev/null && \
        ok "Ключ добавлен вручную" || \
        { fail "Не удалось залить ключ. Добавь вручную в Termux:"; \
          echo "    echo '$(cat "$SSH_KEY.pub")' >> ~/.ssh/authorized_keys"; \
          echo "    chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"; \
          ask "Нажми Enter когда добавил ключ вручную..."; read -r _; }
    fi

    # Финальная проверка
    "$ADB" -s "$PHONE_SER" forward tcp:8022 tcp:8022 >/dev/null 2>&1
    if ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 \
         -i "$SSH_KEY" -p 8022 127.0.0.1 echo OK 2>/dev/null | grep -q OK; then
      ok "Беспарольный SSH работает"
    else
      fail "SSH всё ещё требует пароль. Проверь права ~/.ssh на телефоне."
      echo "    В Termux: chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"
      ask "Нажми Enter после исправления..."
      read -r _
    fi
  fi
}

# ────────────────────────────────────────────────────────────
#  ШАГ 8: rclone remote "phone"
# ────────────────────────────────────────────────────────────
setup_rclone_remote() {
  step "Шаг 8/9 — rclone remote «phone»"
  RCLONE=/usr/local/bin/rclone

  if ! [ -x "$RCLONE" ]; then
    RCLONE="$(command -v rclone 2>/dev/null || true)"
    [ -z "$RCLONE" ] && { fail "rclone не найден. Сначала выполни шаг 3."; exit 1; }
  fi

  if "$RCLONE" listremotes 2>/dev/null | grep -q "^phone:"; then
    ok "rclone remote «phone» уже существует"
    # Проверяем параметры
    local cur_host cur_port cur_key
    cur_host=$("$RCLONE" config show phone 2>/dev/null | awk '/host/{print $3}')
    cur_port=$("$RCLONE" config show phone 2>/dev/null | awk '/port/{print $3}')
    cur_key=$("$RCLONE" config show phone 2>/dev/null | awk '/key_file/{print $3}')
    info "  host=$cur_host port=$cur_port key_file=$cur_key"
    ask "Пересоздать remote с текущими настройками? [y/N] "
    read -r ans
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then return 0; fi
  fi

  [ -z "$PHONE_USER" ] && { load_config; }
  [ -z "$PHONE_USER" ] && {
    ask "Имя пользователя Termux (whoami в Termux): "
    read -r PHONE_USER
    save_config
  }

  info "Создаю rclone remote «phone» (sftp, localhost:8022)..."
  "$RCLONE" config create phone sftp \
    host 127.0.0.1 \
    port 8022 \
    user "$PHONE_USER" \
    key_file "$SSH_KEY" \
    known_hosts_file /dev/null \
    >/dev/null 2>&1

  ok "rclone remote «phone» создан"
  info "  sftp://127.0.0.1:8022 user=$PHONE_USER key=$SSH_KEY"
}

# ────────────────────────────────────────────────────────────
#  ШАГ 9: Desktop-лаунчеры
# ────────────────────────────────────────────────────────────
install_launchers() {
  step "Шаг 9/9 — Desktop-лаунчеры"

  DESKTOP="$HOME/Desktop"
  UP_CMD="$SCRIPTS/phone-stream-up.sh"
  DOWN_CMD="$SCRIPTS/phone-stream-down.sh"

  # Убеждаемся что скрипты исполняемы
  chmod +x "$SCRIPTS"/*.sh 2>/dev/null || true
  chmod +x "$SCRIPTS/launchd"/*.sh 2>/dev/null || true

  MOUNT_LAUNCHER="$DESKTOP/Mount Phone Stream.command"
  UMOUNT_LAUNCHER="$DESKTOP/Unmount Phone Stream.command"

  cat > "$MOUNT_LAUNCHER" <<LAUNCHER
#!/bin/bash
# Mount Phone Stream — двойной клик в Finder запустит маунт
"$UP_CMD"
open "$HOME/PhoneStream"
LAUNCHER
  chmod +x "$MOUNT_LAUNCHER"
  ok "Лаунчер создан: ~/Desktop/Mount Phone Stream.command"

  cat > "$UMOUNT_LAUNCHER" <<LAUNCHER
#!/bin/bash
# Unmount Phone Stream — двойной клик размонтирует
"$DOWN_CMD"
LAUNCHER
  chmod +x "$UMOUNT_LAUNCHER"
  ok "Лаунчер создан: ~/Desktop/Unmount Phone Stream.command"

  info "Чтобы разрешить запуск .command-файлов:"
  info "System Settings → Privacy & Security → разреши или Ctrl+Click → Open"
}

# ────────────────────────────────────────────────────────────
#  ОПЦИОНАЛЬНО: Тёмный режим (экран не горит)
# ────────────────────────────────────────────────────────────
setup_dark_mode() {
  step "Бонус: Тёмный режим (телефон-сервер без горящего экрана)"
  echo ""
  echo "  Тёмный режим = телефон работает как сервер, экран НЕ горит:"
  echo "  - adb shell settings put global stay_on_while_plugged_in 0"
  echo "  - В Termux: termux-wake-lock (partial) держит CPU без экрана"
  echo ""
  ask "Включить тёмный режим прямо сейчас? [y/N] "
  read -r ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    ADB="$(find_adb)"
    PHONE_SER="${PHONE_SERIAL:-}"
    [ -z "$PHONE_SER" ] && PHONE_SER=$("$ADB" devices 2>/dev/null | awk '/\tdevice$/{print $1}' | head -1)
    if [ -n "$PHONE_SER" ]; then
      "$ADB" -s "$PHONE_SER" shell settings put global stay_on_while_plugged_in 0
      ok "Экран не будет гореть при зарядке."
      info "termux-wake-lock уже встроен в termux-boot-10-sshd-server.sh (адаптивный)."
    else
      warn "Телефон не подключён, пропускаем."
    fi
  fi
}

# ────────────────────────────────────────────────────────────
#  ОПЦИОНАЛЬНО: Сервер-режим (Termux:Boot + автозапуск sshd)
# ────────────────────────────────────────────────────────────
optional_server_mode() {
  step "Бонус: Сервер-режим (sshd автостарт при загрузке телефона)"
  echo ""
  echo "  Сервер-режим = телефон поднимает sshd при каждой загрузке."
  echo "  Нужен Termux:Boot из F-Droid."
  echo ""
  echo "  Шаги (вручную на телефоне):"
  echo "  1. Установи Termux:Boot из F-Droid"
  echo "  2. Открой Termux:Boot хотя бы раз (активирует автозапуск)"
  echo "  3. В Termux:"
  echo "     mkdir -p ~/.termux/boot"
  echo "     cat > ~/.termux/boot/10-sshd-server.sh <<'EOF'"
  cat "$SCRIPTS/termux-boot-10-sshd-server.sh"
  echo "EOF"
  echo "     chmod +x ~/.termux/boot/10-sshd-server.sh"
  echo ""
  echo "  Скрипт: адаптивный wake-lock — полная мощность только при активном SSH-подключении."
  echo "  При простое телефон дремлет."
  echo ""
  info "Файл boot-скрипта: $SCRIPTS/termux-boot-10-sshd-server.sh"
}

# ────────────────────────────────────────────────────────────
#  ОПЦИОНАЛЬНО: launchd auto-mount (adbfs стек)
# ────────────────────────────────────────────────────────────
optional_launchd() {
  step "Бонус: launchd авто-маунт при USB-подключении (adbfs стек)"
  echo ""
  echo "  Регистрирует com.kapshytar.adbfs-phone — автоматически монтирует"
  echo "  ~/Phone при появлении USB-устройства Android."
  echo ""
  echo "  ТРЕБУЕТ: macFUSE + собранный adbfs (GPLv3, upstream)"
  echo "  Инструкция по сборке adbfs: см. README.md → Installation → Step 3"
  echo ""

  if [ ! -d "/Library/Filesystems/macfuse.fs" ]; then
    warn "macFUSE не установлен. launchd авто-маунт недоступен."
    return 0
  fi

  ask "Настроить launchd авто-маунт? [y/N] "
  read -r ans
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then return 0; fi

  ask "Путь к бинарю adbfs (Enter = поиск автоматически): "
  read -r adbfs_path
  if [ -z "$adbfs_path" ]; then
    for c in \
      "$(command -v adbfs 2>/dev/null || true)" \
      "$HOME/PhoneAsExtStorage/adbfs-rootless/adbfs"; do
      if [ -x "$c" ]; then adbfs_path="$c"; break; fi
    done
  fi
  if [ -z "$adbfs_path" ] || [ ! -x "$adbfs_path" ]; then
    fail "adbfs не найден по пути: ${adbfs_path:-<не указан>}"
    info "Собери adbfs из upstream + patch/adbfs-root-env.patch, затем запусти setup.sh снова."
    return 1
  fi

  ADB_DIR="$(dirname "$(find_adb)")"

  # Подставляем пути в шаблоны
  LAUNCHD_DIR="$SCRIPTS/launchd"
  INSTALLED_LAUNCHD="$HOME/.phone-stream-launchd"
  mkdir -p "$INSTALLED_LAUNCHD"

  sed \
    -e "s|__HOME__|$HOME|g" \
    -e "s|__ADB_DIR__|$ADB_DIR|g" \
    -e "s|__ADBFS_BIN__|$adbfs_path|g" \
    "$LAUNCHD_DIR/adbfs-launchd-run.sh" > "$INSTALLED_LAUNCHD/adbfs-launchd-run.sh"
  chmod +x "$INSTALLED_LAUNCHD/adbfs-launchd-run.sh"

  sed \
    -e "s|__HOME__|$HOME|g" \
    -e "s|__ADB_DIR__|$ADB_DIR|g" \
    -e "s|__LAUNCHD_RUN_SH__|$INSTALLED_LAUNCHD/adbfs-launchd-run.sh|g" \
    "$LAUNCHD_DIR/com.kapshytar.adbfs-phone.plist" \
    > "$INSTALLED_LAUNCHD/com.kapshytar.adbfs-phone.plist"

  cp "$LAUNCHD_DIR/install.sh" "$INSTALLED_LAUNCHD/install.sh"
  cp "$LAUNCHD_DIR/uninstall.sh" "$INSTALLED_LAUNCHD/uninstall.sh"
  chmod +x "$INSTALLED_LAUNCHD/install.sh" "$INSTALLED_LAUNCHD/uninstall.sh"

  # Подменяем PLIST_SRC в install.sh на наш файл
  PLIST_DST="$HOME/Library/LaunchAgents/com.kapshytar.adbfs-phone.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  cp "$INSTALLED_LAUNCHD/com.kapshytar.adbfs-phone.plist" "$PLIST_DST"

  UID_VAL="$(id -u)"
  if launchctl list "com.kapshytar.adbfs-phone" &>/dev/null 2>&1; then
    launchctl bootout "gui/$UID_VAL/com.kapshytar.adbfs-phone" 2>/dev/null || true
    sleep 1
  fi
  launchctl bootstrap "gui/$UID_VAL" "$PLIST_DST"
  ok "LaunchAgent установлен: com.kapshytar.adbfs-phone"
  info "Логи: tail -f /tmp/adbfs-phone.out.log"
  info "Статус: launchctl list com.kapshytar.adbfs-phone"
  info "Удалить: $INSTALLED_LAUNCHD/uninstall.sh"
}

# ────────────────────────────────────────────────────────────
#  Финальный экран
# ────────────────────────────────────────────────────────────
print_summary() {
  echo ""
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗"
  echo "║                    Готово!                               ║"
  echo -e "╚══════════════════════════════════════════════════════════╝${RESET}"
  echo ""
  echo "  Как пользоваться:"
  echo ""
  echo "  Смонтировать (no-copy стрим через Termux sshd):"
  echo "    $SCRIPTS/phone-stream-up.sh"
  echo "    — или двойной клик «Mount Phone Stream» на рабочем столе"
  echo ""
  echo "  Размонтировать:"
  echo "    $SCRIPTS/phone-stream-down.sh"
  echo ""
  echo "  Точка монтирования: ~/PhoneStream"
  echo "  Логи rclone: tail -f /tmp/rclone_mount.log"
  echo ""
  if [ -d "/Library/Filesystems/macfuse.fs" ]; then
    echo "  Альтернатива — FUSE-маунт (нужен adbfs binary):"
    echo "    $SCRIPTS/mount-phone.sh   → ~/Phone в Finder"
    echo "    $SCRIPTS/unmount-phone.sh"
    echo ""
  fi
  echo "  Тёмный режим (экран не горит, телефон-сервер):"
  echo "    adb shell settings put global stay_on_while_plugged_in 0"
  echo ""
  echo "  Если что-то не работает:"
  echo "    tail -4 /tmp/rclone_mount.log"
  echo "    adb devices"
  echo "    nc -zv 127.0.0.1 8022"
  echo ""
}

# ────────────────────────────────────────────────────────────
#  MAIN
# ────────────────────────────────────────────────────────────
main() {
  load_config
  PHONE_SERIAL=""

  print_header
  check_brew
  install_macfuse
  install_rclone
  check_adb
  setup_phone_adb
  setup_termux
  setup_phone_ssh
  setup_rclone_remote
  install_launchers

  echo ""
  echo -e "${BOLD}Опциональные шаги:${RESET}"
  setup_dark_mode
  optional_server_mode
  optional_launchd

  print_summary
}

main "$@"
