#!/usr/bin/env bash
# ==============================================================================
# show-minute-of-silence.sh
# Щоденне сповіщення про загальнонаціональну хвилину мовчання о 09:00 для macOS.
# Підтримує swiftDialog (якщо встановлено) з fallback на рідний osascript / System Events.
# Включає фоновий прогрів, мілісекундну синхронізацію та Time Guard.
# ==============================================================================
set -euo pipefail

FORCE=false
if [[ "${1:-}" == "--force" || "${1:-}" == "-f" ]]; then
    FORCE=true
fi

# ── 1. Time Guard: перевірка вікна запуску (08:59:00 - 09:00:55) ──────────────
NOW_EPOCH=$(date +%s)
# Обчислення сьогоднішніх 09:00:00 за локальним часом (BSD date у macOS)
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

# ── 2. Перевірка наявності активного користувача в GUI ────────────────────────
CONSOLE_USER="$(/usr/bin/stat -f %Su /dev/console 2>/dev/null || echo "")"
if [[ -z "$CONSOLE_USER" || "$CONSOLE_USER" == "root" || "$CONSOLE_USER" == "loginwindow" ]]; then
    echo "Minute of Silence: Немає активного GUI-користувача. Пропуск."
    exit 0
fi

TITLE="09:00 — Загальнонаціональна хвилина мовчання"
MESSAGE="Зупинимося на хвилину, щоб вшанувати пам'ять захисників, захисниць та всіх українців, чиї життя забрала війна.

Пам'ятаємо. Дякуємо. Шануємо."

# ── 3. Аудіо: пошук аудіотреку metronome.mp3 ──────────────────────────────────
AUDIO_PATH=""
CANDIDATE_PATHS=(
    "$(dirname "$0")/metronome.mp3"
    "$(dirname "$0")/zvuk-blokadnogo-metronoma.mp3"
    "$(dirname "$0")/99_silent_m.mp3"
    "/Library/Application Support/Corporate/MinuteOfSilence/metronome.mp3"
    "/Library/Application Support/Corporate/MinuteOfSilence/zvuk-blokadnogo-metronoma.mp3"
    "/Library/Application Support/Corporate/MinuteOfSilence/99_silent_m.mp3"
)
for c in "${CANDIDATE_PATHS[@]}"; do
    if [[ -f "$c" ]]; then
        AUDIO_PATH="$c"
        break
    fi
done

if [[ -z "$AUDIO_PATH" ]]; then
    DOWNLOAD_TARGET="/Library/Application Support/Corporate/MinuteOfSilence/metronome.mp3"
    AUDIO_URL="https://raw.githubusercontent.com/girilovsky/National-Minute-Of-Silence/main/windows/metronome.mp3"
    if /usr/bin/curl -sSL --max-time 10 "$AUDIO_URL" -o "$DOWNLOAD_TARGET" 2>/dev/null; then
        AUDIO_PATH="$DOWNLOAD_TARGET"
    fi
fi

# ── 4. Міжпристроєва синхронізація (Pre-warming sleep до 09:00:00) ───────────
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

# ── 5. Фонове відтворення metronome.mp3 через afplay (гучність 25%) ──────────
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

# ── 6. Відображення: swiftDialog (якщо є) або рідний AppleScript ───────────────
DIALOG_BIN="/usr/local/bin/dialog"

if [[ -x "$DIALOG_BIN" ]]; then
    echo "Minute of Silence: Відображення через swiftDialog..."
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
    echo "Minute of Silence: Відображення через osascript / System Events..."
    /usr/bin/osascript <<EOF || true
tell application "System Events"
    activate
    display alert "$TITLE" ¬
        message "$MESSAGE" ¬
        as informational ¬
        buttons {"Зрозуміло"} ¬
        default button "Зрозуміло" ¬
        giving up after 60
end tell
EOF
fi

echo "Minute of Silence: Сповіщення завершено."
exit 0
