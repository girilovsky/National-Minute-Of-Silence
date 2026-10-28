#!/usr/bin/env bash
# ==============================================================================
# [Intune Shell Script] macOS - National Minute of Silence Reminder
# Розгортає щоденне нагадування про загальнонаціональну хвилину мовчання о 09:00 для macOS.
#
# Налаштування Intune:
#   * Name: macOS - National Minute of Silence Reminder
#   * Run script as signed-in user: No (виконується від root для реєстрації LaunchAgent)
#   * Hide script notifications on devices: Yes
#   * Script frequency: Not configured (одноразове встановлення LaunchAgent)
# ==============================================================================
set -euo pipefail

echo "=== [Intune] macOS - National Minute of Silence Reminder ==="

INSTALL_DIR="/Library/Application Support/Corporate/MinuteOfSilence"
SCRIPT_PATH="$INSTALL_DIR/show-minute-of-silence.sh"
PLIST_PATH="/Library/LaunchAgents/com.corp.minute-of-silence.plist"
LABEL="com.corp.minute-of-silence"

# ── 1. Створення директорії встановлення та кешування аудіо ──────────────────
mkdir -p "$INSTALL_DIR"
chmod 755 "$INSTALL_DIR"

AUDIO_DEST="$INSTALL_DIR/metronome.mp3"
AUDIO_URL="https://raw.githubusercontent.com/girilovsky/National-Minute-Of-Silence/main/macos/metronome.mp3"
if [[ ! -s "$AUDIO_DEST" || $(stat -f%z "$AUDIO_DEST" 2>/dev/null || echo 0) -lt 100000 ]]; then
    echo "INFO: Завантаження студійного аудіотреку з GitHub ($AUDIO_URL)..."
    /usr/bin/curl -sSL --max-time 15 "$AUDIO_URL" -o "$AUDIO_DEST" 2>/dev/null || true
    chmod 644 "$AUDIO_DEST" 2>/dev/null || true
fi

# ── 2. Розгортання виконуваного скрипта ────────────────────────────────────────
cat > "$SCRIPT_PATH" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

FORCE=false
if [[ "${1:-}" == "--force" || "${1:-}" == "-f" ]]; then
    FORCE=true
fi

# Time Guard: перевірка вікна запуску (08:59:00 - 09:00:55)
NOW_EPOCH=$(date +%s)
if date -v9H -v0M -v0S +%s >/dev/null 2>&1; then
    TARGET_EPOCH=$(date -v9H -v0M -v0S +%s)
else
    TARGET_EPOCH=$(date -d "$(date +%Y-%m-%d) 09:00:00" +%s 2>/dev/null || echo "$NOW_EPOCH")
fi

if [[ "$FORCE" == false ]]; then
    # Дозволено від 08:59:00 (TARGET - 60s) строго до 09:00:59 (TARGET + 59s)
    # О 09:01:00 і пізніше сповіщення НЕ відображається!
    MIN_ALLOWED=$((TARGET_EPOCH - 60))
    MAX_ALLOWED=$((TARGET_EPOCH + 59))

    if (( NOW_EPOCH < MIN_ALLOWED || NOW_EPOCH > MAX_ALLOWED )); then
        echo "Minute of Silence: Поточний час ($(date +"%H:%M:%S")) за межами вікна. О 09:01 і пізніше сповіщення не відображається. Пропуск."
        exit 0
    fi
fi

CONSOLE_USER="$(/usr/bin/stat -f %Su /dev/console 2>/dev/null || echo "")"
if [[ -z "$CONSOLE_USER" || "$CONSOLE_USER" == "root" || "$CONSOLE_USER" == "loginwindow" ]]; then
    echo "Minute of Silence: Немає активного GUI-користувача. Пропуск."
    exit 0
fi

TITLE="09:00 — Загальнонаціональна хвилина мовчання"
MESSAGE="Зупинимося на хвилину, щоб вшанувати пам'ять захисників, захисниць та всіх українців, чиї життя забрала війна.

Пам'ятаємо. Дякуємо. Шануємо."

AUDIO_PATH=""
CANDIDATE_PATHS=(
    "$(dirname "$0")/metronome.mp3"
    "/Library/Application Support/Corporate/MinuteOfSilence/metronome.mp3"
    "$(dirname "$0")/../assets/metronome.mp3"
)
for c in "${CANDIDATE_PATHS[@]}"; do
    if [[ -f "$c" ]]; then
        AUDIO_PATH="$c"
        break
    fi
done

if [[ -z "$AUDIO_PATH" ]]; then
    DOWNLOAD_TARGET="/Library/Application Support/Corporate/MinuteOfSilence/metronome.mp3"
    AUDIO_URL="https://raw.githubusercontent.com/girilovsky/National-Minute-Of-Silence/main/macos/metronome.mp3"
    if /usr/bin/curl -sSL --max-time 10 "$AUDIO_URL" -o "$DOWNLOAD_TARGET" 2>/dev/null; then
        AUDIO_PATH="$DOWNLOAD_TARGET"
    fi
fi

# Міжпристроєва синхронізація (Pre-warming sleep до 09:00:00)
if [[ "$FORCE" == false ]]; then
    CURRENT_EPOCH=$(date +%s)
    if (( CURRENT_EPOCH >= TARGET_EPOCH + 60 )); then
        echo "Minute of Silence: Час 09:01:00 або пізніше. Хвилина мовчання на сьогодні завершена. Пропуск."
        exit 0
    fi
    if (( CURRENT_EPOCH < TARGET_EPOCH )); then
        WAIT_SEC=$((TARGET_EPOCH - CURRENT_EPOCH))
        echo "Minute of Silence: Фоновий прогрів. Очікування ${WAIT_SEC}с до 09:00:00..."
        sleep "$WAIT_SEC"
    fi
fi

AUDIO_PID=""
if [[ -n "$AUDIO_PATH" && -x /usr/bin/afplay ]]; then
    /usr/bin/afplay -v 0.25 "$AUDIO_PATH" &
    AUDIO_PID=$!
fi

cleanup() {
    if [[ -n "$AUDIO_PID" ]]; then
        kill "$AUDIO_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

DIALOG_BIN="/usr/local/bin/dialog"

if [[ -x "$DIALOG_BIN" ]]; then
    "$DIALOG_BIN" \
        --title "$TITLE" \
        --message "$MESSAGE" \
        --ontop \
        --timer 60 \
        --button1text "Зрозуміло" \
        --position center \
        --icon "none" \
        --infobox "🕯 09:00" \
        || true
else
    /usr/bin/osascript -e 'use framework "Cocoa"' \
        -e 'use scripting additions' \
        -e 'current application'\''s NSApplication'\''s sharedApplication()'\''s setActivationPolicy:(current application'\''s NSApplicationActivationPolicyAccessory)' \
        -e 'current application'\''s NSApplication'\''s sharedApplication()'\''s activateIgnoringOtherApps:true' \
        -e "display alert \"$TITLE\" message \"$MESSAGE\" as informational buttons {\"Зрозуміло\"} default button \"Зрозуміло\" giving up after 60" \
        || true
fi

exit 0
EOF

chmod 755 "$SCRIPT_PATH"
chown root:wheel "$SCRIPT_PATH"
echo "INFO: Скрипт розгорнуто в $SCRIPT_PATH"

# ── 3. Розгортання LaunchAgent у /Library/LaunchAgents ─────────────────────────
cat > "$PLIST_PATH" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.corp.minute-of-silence</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Library/Application Support/Corporate/MinuteOfSilence/show-minute-of-silence.sh</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>8</integer>
        <key>Minute</key>
        <integer>59</integer>
    </dict>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>/var/log/minute-of-silence.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/minute-of-silence.log</string>
</dict>
</plist>
EOF

chmod 644 "$PLIST_PATH"
chown root:wheel "$PLIST_PATH"
echo "INFO: LaunchAgent розгорнуто в $PLIST_PATH"

# ── 4. Активація LaunchAgent для активного консольного користувача ─────────────
CONSOLE_USER="$(/usr/bin/stat -f %Su /dev/console 2>/dev/null || echo "")"
if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" && "$CONSOLE_USER" != "loginwindow" ]]; then
    CONSOLE_UID="$(/usr/bin/id -u "$CONSOLE_USER")"
    echo "INFO: Реєстрація LaunchAgent для користувача $CONSOLE_USER (UID: $CONSOLE_UID)..."
    
    # Вивантаження старого агента, якщо існував
    /bin/launchctl bootout "gui/$CONSOLE_UID/$LABEL" 2>/dev/null || true
    
    # Завантаження нового агента в GUI-сесію
    /bin/launchctl bootstrap "gui/$CONSOLE_UID" "$PLIST_PATH" 2>/dev/null || \
        /bin/launchctl asuser "$CONSOLE_UID" /bin/launchctl load -w "$PLIST_PATH" || true
    echo "INFO: LaunchAgent успішно активовано для gui/$CONSOLE_UID."
else
    echo "INFO: Немає активної GUI-сесії. LaunchAgent активується автоматично при наступному вході користувача."
fi

echo "УСПІШНО: Розгортання нагадування хвилини мовчання для macOS завершено."
exit 0
