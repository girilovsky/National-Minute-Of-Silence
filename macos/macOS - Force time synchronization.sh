#!/usr/bin/env bash
# ==============================================================================
# [Intune Script] macOS - Force time synchronization.sh
# Примусово налаштовує регулярну синхронізацію системного часу macOS через NTP.
# ==============================================================================
# Конфігурація в Microsoft Intune:
#   - Run script as signed-in user: No (Run as root)
#   - Hide script notifications on devices: Yes
#   - Frequency: Once (реєструє постійний LaunchDaemon)
# ==============================================================================
set -euo pipefail

echo "=== [Intune] macOS - Force time synchronization ==="

if [[ $EUID -ne 0 ]]; then
    echo "ПОМИЛКА: Цей скрипт повинен виконуватися з правами root." >&2
    exit 1
fi

TIME_SERVER="time.apple.com"
PLIST_PATH="/Library/LaunchDaemons/com.corp.time-sync.plist"
LABEL="com.corp.time-sync"

# 1. Увімкнення Network Time в системі
echo "1. Увімкнення системного Network Time..."
/usr/sbin/systemsetup -setusingnetworktime on 2>/dev/null || true
/usr/sbin/systemsetup -setnetworktimeserver "$TIME_SERVER" 2>/dev/null || true

# 2. Створення системного LaunchDaemon для регулярної синхронізації
echo "2. Налаштування регулярного системного LaunchDaemon ($LABEL)..."
cat > "$PLIST_PATH" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.corp.time-sync</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/sntp</string>
        <string>-sS</string>
        <string>time.apple.com</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>14400</integer>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>8</integer>
        <key>Minute</key>
        <integer>30</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>/var/log/corporate-time-sync.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/corporate-time-sync.log</string>
</dict>
</plist>
EOF

chmod 644 "$PLIST_PATH"
chown root:wheel "$PLIST_PATH"

# 3. Активація LaunchDaemon в системному домені
echo "3. Активація LaunchDaemon..."
/bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
/bin/launchctl bootstrap system "$PLIST_PATH" 2>/dev/null || \
    /bin/launchctl load -w "$PLIST_PATH" 2>/dev/null || true

# 4. Примусова негайна синхронізація через sntp
echo "4. Примусова негайна синхронізація через sntp..."
if [[ -x /usr/bin/sntp ]]; then
    /usr/bin/sntp -sS "$TIME_SERVER" 2>&1 || true
fi

# 5. Оновлення системного демона timed
echo "5. Оновлення системного демона timed..."
/usr/bin/killall timed 2>/dev/null || true

echo "Поточний системний час: $(date "+%Y-%m-%d %H:%M:%S %Z")"
echo "УСПІШНО: Регулярну синхронізацію часу macOS налаштовано (кожні 4 години та о 08:30)."
exit 0
