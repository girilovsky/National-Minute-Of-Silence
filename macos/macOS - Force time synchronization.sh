#!/usr/bin/env bash
# ==============================================================================
# [Intune Script] macOS - Force time synchronization.sh
# Примусово вмикає та синхронізує системний час macOS через NTP.
# ==============================================================================
# Конфігурація в Microsoft Intune:
#   - Run script as signed-in user: No (Run as root)
#   - Hide script notifications on devices: Yes
#   - Frequency: Every day / Once
# ==============================================================================
set -euo pipefail

echo "=== [Intune] macOS - Force time synchronization ==="

# 1. Перевірка привілеїв root
if [[ $EUID -ne 0 ]]; then
    echo "ПОМИЛКА: Цей скрипт повинен виконуватися з правами root." >&2
    exit 1
fi

# 2. Увімкнення синхронізації через Network Time (NTP)
echo "1. Увімкнення Network Time..."
/usr/sbin/systemsetup -setusingnetworktime on 2>/dev/null || true

# 3. Встановлення надійного сервера часу
echo "2. Налаштування NTP серверів..."
TIME_SERVER="time.apple.com"
/usr/sbin/systemsetup -setnetworktimeserver "$TIME_SERVER" 2>/dev/null || true

# 4. Примусова синхронізація через sntp (якщо доступна)
echo "3. Примусова синхронізація через sntp..."
if [[ -x /usr/bin/sntp ]]; then
    /usr/bin/sntp -sS "$TIME_SERVER" 2>&1 || true
fi

# 5. Перезапуск системного демона timed для негайного оновлення
echo "4. Оновлення системного демона timed..."
/usr/bin/killall timed 2>/dev/null || true

# 6. Перевірка поточного часу
echo "5. Поточний системний час:"
date "+%Y-%m-%d %H:%M:%S %Z"

echo "УСПІШНО: Синхронізацію часу macOS налаштовано."
exit 0
