# adbfs LaunchAgent — автомонтирование телефона

Монтирует внутреннюю память Android-телефона (`/storage/emulated/0`) в `~/Phone`
через `adbfs` при входе в систему / подключении USB.

## Файлы

| Файл | Назначение |
|------|-----------|
| `com.kapshytar.adbfs-phone.plist` | LaunchAgent (UserAgent, не Daemon) |
| `adbfs-launchd-run.sh` | Обёртка: ждёт USB, запускает adbfs в foreground |
| `install.sh` | Установка агента |
| `uninstall.sh` | Снятие агента и отмонтирование |

## Установка

```bash
cd /Users/v/PhoneAsExtStorage/adbfs-rootless/launchd
chmod +x install.sh uninstall.sh
./install.sh
```

## Удаление

```bash
./uninstall.sh
```

## Ручные команды (без скриптов)

```bash
# Установить
cp com.kapshytar.adbfs-phone.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.kapshytar.adbfs-phone.plist

# Снять
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.kapshytar.adbfs-phone.plist
rm ~/Library/LaunchAgents/com.kapshytar.adbfs-phone.plist

# Статус
launchctl list com.kapshytar.adbfs-phone

# Логи
tail -f /tmp/adbfs-phone.out.log
tail -f /tmp/adbfs-phone.err.log
```

## Как это работает

1. `RunAtLoad true` — агент стартует сразу при логине.
2. Обёртка `adbfs-launchd-run.sh` ждёт до 30 секунд появления USB-устройства.
3. Если телефон не найден — **выходит с кодом 0** → launchd видит `SuccessfulExit`
   и **не перезапускает** агент (не молотит CPU).
4. Если телефон найден — запускает `adbfs -f` через `exec` (foreground).
   launchd следит за процессом и перезапустит при аварийном падении (exit != 0).

## Грабли

### Телефон должен быть подключён по USB
Монтирование работает только через физический USB (не по Wi-Fi ADB).
Убедитесь, что на телефоне включена отладка по USB и телефон разблокирован.

### После sleep/wake остаётся stale mount
macOS может оставить зависший маунт после сна. Симптомы: Finder показывает том,
но файлы недоступны или `ls ~/Phone` зависает.

**Лечение:**
```bash
# Вариант 1 — через uninstall/install
./uninstall.sh && sleep 2 && ./install.sh

# Вариант 2 — вручную
diskutil unmount force ~/Phone
launchctl kickstart -k gui/$(id -u)/com.kapshytar.adbfs-phone
```

### Агент запустился, но телефон не монтируется
```bash
# Смотрим логи
cat /tmp/adbfs-phone.err.log

# Проверяем adb видит устройство
/Users/v/Library/Android/sdk/platform-tools/adb devices

# Перезапустить агент вручную
launchctl kickstart -k gui/$(id -u)/com.kapshytar.adbfs-phone
```

### Проверить, загружен ли агент
```bash
launchctl list com.kapshytar.adbfs-phone
# PID в первой колонке — процесс живёт
# "-" — не запущен (телефон не был подключён при старте)
```

### T2 / SIP
На Intel Mac с T2 SIP не мешает FUSE-маунтам в user-пространстве.
Если macFUSE не установлен — установите с https://osxfuse.github.io/
