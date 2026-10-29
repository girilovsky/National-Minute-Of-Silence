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

# ── 1b. Встановлення swiftDialog (якщо відсутній) ────────────────────────────
DIALOG_BIN="/usr/local/bin/dialog"
if [[ ! -x "$DIALOG_BIN" ]]; then
    echo "INFO: swiftDialog не знайдено. Завантаження офіційного пакета swiftDialog..."
    DIALOG_PKG_URL=$(/usr/bin/curl -sSL --max-time 15 "https://api.github.com/repos/swiftDialog/swiftDialog/releases/latest" 2>/dev/null \
        | /usr/bin/grep -Eo 'https://[^"]+\.pkg' | /usr/bin/head -n 1 || true)
    if [[ -z "$DIALOG_PKG_URL" ]]; then
        DIALOG_PKG_URL="https://github.com/swiftDialog/swiftDialog/releases/download/v3.1.1/dialog-3.1.1-5000.pkg"
    fi
    TMP_DIALOG_PKG="/tmp/swiftDialog-install.pkg"
    if /usr/bin/curl -fL --retry 3 --retry-delay 2 --max-time 60 "$DIALOG_PKG_URL" -o "$TMP_DIALOG_PKG" 2>/dev/null; then
        echo "INFO: Встановлення swiftDialog з $DIALOG_PKG_URL..."
        /usr/sbin/installer -pkg "$TMP_DIALOG_PKG" -target / >/dev/null 2>&1 || true
        rm -f "$TMP_DIALOG_PKG"
        if [[ -x "$DIALOG_BIN" ]]; then
            echo "INFO: swiftDialog успішно встановлено ($("$DIALOG_BIN" --version 2>/dev/null || echo 'OK'))."
        fi
    else
        rm -f "$TMP_DIALOG_PKG" 2>/dev/null || true
        echo "WARN: Не вдалося завантажити swiftDialog, використовуватиметься нативний osascript fallback."
    fi
fi

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

# Захист від повторного запуску в один і той самий день (якщо не --force)
LOCK_FILE="/tmp/minute-of-silence-$(date +%Y-%m-%d).lock"
if [[ "$FORCE" == false ]]; then
    if [[ -f "$LOCK_FILE" ]]; then
        echo "Minute of Silence: Сьогодні сповіщення вже виконувалось ($LOCK_FILE). Пропуск."
        exit 0
    fi
    touch "$LOCK_FILE" 2>/dev/null || true
    chmod 666 "$LOCK_FILE" 2>/dev/null || true
fi

TITLE="09:00 — Загальнонаціональна хвилина мовчання"
MESSAGE="Зупинимося на хвилину, щоб вшанувати пам'ять захисників, захисниць та всіх українців, чиї життя забрала війна.

Пам'ятаємо. Дякуємо. Шануємо."

AUDIO_PATH=""
CANDIDATE_PATHS=(
    "$(dirname "$0")/metronome.mp3"
    "/Library/Application Support/Corporate/MinuteOfSilence/metronome.mp3"
    "/tmp/minute-of-silence-metronome.mp3"
    "$(dirname "$0")/../assets/metronome.mp3"
)
for c in "${CANDIDATE_PATHS[@]}"; do
    if [[ -f "$c" ]]; then
        AUDIO_PATH="$c"
        break
    fi
done

if [[ -z "$AUDIO_PATH" ]]; then
    DOWNLOAD_TARGET="/tmp/minute-of-silence-metronome.mp3"
    AUDIO_URL="https://raw.githubusercontent.com/girilovsky/National-Minute-Of-Silence/main/macos/metronome.mp3"
    if /usr/bin/curl -sSL --max-time 10 "$AUDIO_URL" -o "$DOWNLOAD_TARGET" 2>/dev/null; then
        chmod 666 "$DOWNLOAD_TARGET" 2>/dev/null || true
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

export MOS_AUDIO_PATH="$AUDIO_PATH"
export MOS_DURATION="60"

if ! /usr/bin/osascript -l JavaScript << 'JXA_EOF'
ObjC.import('Cocoa');

var env = $.NSProcessInfo.processInfo.environment;
var audioPath = ObjC.unwrap(env.objectForKey($('MOS_AUDIO_PATH'))) || '';
var totalSeconds = parseInt(ObjC.unwrap(env.objectForKey($('MOS_DURATION'))) || '60', 10);
var defaultVolume = 0.10;

var app = $.NSApplication.sharedApplication;
app.setActivationPolicy($.NSApplicationActivationPolicyAccessory);

var width = 500, height = 340;
var screenFrame = $.NSScreen.mainScreen.visibleFrame;
var x = screenFrame.origin.x + (screenFrame.size.width - width) / 2;
var y = screenFrame.origin.y + (screenFrame.size.height - height) / 2;
var rect = $.NSMakeRect(x, y, width, height);

var styleMask = (1 << 0) | (1 << 1) | (1 << 15);
var win = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(
    rect,
    styleMask,
    $.NSBackingStoreBuffered,
    false
);
win.setTitle($('Хвилина мовчання'));
win.setTitlebarAppearsTransparent(true);
win.setTitleVisibility(1);
win.setOpaque(true);
win.setBackgroundColor($.NSColor.colorWithCalibratedRedGreenBlueAlpha(0.067, 0.071, 0.082, 1.0));
win.setHasShadow(true);
win.setLevel(3);
win.setCollectionBehavior((1 << 0) | (1 << 8));
win.setReleasedWhenClosed(false);

for (var i = 1; i <= 2; i++) {
    var sbtn = win.standardWindowButton(i);
    if (sbtn && !sbtn.isNil()) sbtn.setHidden(true);
}

var root = win.contentView;
root.setWantsLayer(true);

var alignLeft = 0;
var alignCenter = ($.NSRunningApplication.currentApplication.executableArchitecture === 16777228) ? 1 : 2;

function makeColor(r, g, b, a) {
    return $.NSColor.colorWithCalibratedRedGreenBlueAlpha(r / 255.0, g / 255.0, b / 255.0, a);
}

function addBox(bx, by, bw, bh, fillC, borderC, borderW, radius) {
    var box = $.NSBox.alloc.initWithFrame($.NSMakeRect(bx, by, bw, bh));
    box.setBoxType(4);
    box.setBorderType(1);
    box.setTitlePosition(0);
    box.setContentViewMargins($.NSMakeSize(0, 0));
    box.setCornerRadius(radius);
    box.setBorderWidth(borderW);
    if (borderC) box.setBorderColor(borderC);
    if (fillC) box.setFillColor(fillC);
    root.addSubview(box);
    return box;
}

function addLabel(lx, ly, lw, lh, text, fontSize, isBold, color, centered) {
    var tf = $.NSTextField.alloc.initWithFrame($.NSMakeRect(lx, ly, lw, lh));
    tf.setStringValue($(text));
    tf.setEditable(false);
    tf.setSelectable(false);
    tf.setBezeled(false);
    tf.setDrawsBackground(false);
    tf.setTextColor(color);
    tf.setFont(isBold ? $.NSFont.boldSystemFontOfSize(fontSize) : $.NSFont.systemFontOfSize(fontSize));
    if (centered) {
        tf.sizeToFit;
        var sz = tf.frame.size;
        var cx = lx + (lw - sz.width) / 2.0;
        var cy = ly + (lh - sz.height) / 2.0;
        tf.setFrameOrigin($.NSMakePoint(cx, cy));
    }
    root.addSubview(tf);
    return tf;
}

addBox(135, 282, 230, 30, makeColor(26, 28, 34, 1.0), makeColor(45, 48, 57, 1.0), 1.0, 14.0);
addLabel(135, 282, 230, 30, '🕯️ 09:00  •  ХВИЛИНА МОВЧАННЯ', 12.0, true, makeColor(243, 244, 246, 1.0), true);

addLabel(0, 236, width, 30, 'Загальнонаціональна хвилина мовчання', 19.0, true, makeColor(255, 255, 255, 1.0), true);

addLabel(0, 198, width, 22, "Зупинимося на хвилину, щоб вшанувати пам'ять захисників,", 13.5, false, makeColor(156, 163, 175, 1.0), true);
addLabel(0, 176, width, 22, "захисниць та всіх українців, чиї життя забрала війна.", 13.5, false, makeColor(156, 163, 175, 1.0), true);

addBox(105, 118, 290, 36, makeColor(22, 24, 30, 1.0), makeColor(37, 39, 47, 1.0), 1.0, 10.0);
addLabel(105, 118, 290, 36, "Пам'ятаємо.   Дякуємо.   Шануємо.", 13.5, true, makeColor(251, 191, 36, 1.0), true);

var barMaxW = 444.0;
addBox(28, 82, barMaxW, 4, makeColor(30, 32, 38, 1.0), makeColor(30, 32, 38, 1.0), 0.0, 2.0);
var barFill = addBox(28, 82, barMaxW, 4, makeColor(245, 158, 11, 1.0), makeColor(245, 158, 11, 1.0), 0.0, 2.0);

addBox(28, 24, 34, 34, makeColor(26, 28, 34, 1.0), makeColor(45, 48, 57, 1.0), 1.0, 8.0);
var muteLabel = addLabel(28, 24, 34, 34, '🔊', 14.0, false, makeColor(243, 244, 246, 1.0), true);
var cdLabel = addLabel(72, 30, 220, 20, 'Закриється через ' + totalSeconds + ' с', 12.5, false, makeColor(107, 114, 128, 1.0), false);

addBox(352, 24, 120, 36, makeColor(34, 37, 45, 1.0), makeColor(51, 55, 66, 1.0), 1.0, 10.0);
addLabel(352, 24, 120, 36, 'Зрозуміло', 13.0, true, makeColor(243, 244, 246, 1.0), true);

var sound = null;
if (audioPath.length > 0) {
    sound = $.NSSound.alloc.initWithContentsOfFileByReference($(audioPath), true);
    if (sound && !sound.isNil()) {
        sound.setVolume(defaultVolume);
        sound.play;
    }
}

var startTime = Date.now();
var isMuted = false;

ObjC.registerSubclass({
    name: 'MOSWindowController',
    superclass: 'NSObject',
    methods: {
        'onDismiss:': {
            types: ['void', ['id']],
            implementation: function(sender) {
                if (sound && !sound.isNil()) sound.stop;
                app.terminate(null);
            }
        },
        'onMute:': {
            types: ['void', ['id']],
            implementation: function(sender) {
                isMuted = !isMuted;
                muteLabel.setStringValue($(isMuted ? '🔇' : '🔊'));
                if (sound && !sound.isNil()) {
                    sound.setVolume(isMuted ? 0.0 : defaultVolume);
                }
            }
        },
        'onTick:': {
            types: ['void', ['id']],
            implementation: function(timer) {
                if (!win.isVisible) {
                    if (sound && !sound.isNil()) sound.stop;
                    app.terminate(null);
                    return;
                }
                var elapsedSec = (Date.now() - startTime) / 1000.0;
                var remSec = Math.max(0.0, totalSeconds - elapsedSec);
                if (remSec <= 0.0) {
                    if (sound && !sound.isNil()) sound.stop;
                    app.terminate(null);
                    return;
                }
                var curW = Math.max(1.0, barMaxW * (remSec / totalSeconds));
                barFill.setFrameSize($.NSMakeSize(curW, 4));
                cdLabel.setStringValue($('Закриється через ' + Math.ceil(remSec) + ' с'));

                if (!isMuted && sound && !sound.isNil() && remSec <= 2.4) {
                    sound.setVolume(defaultVolume * Math.max(0.0, remSec / 2.4));
                }
                if (remSec <= 0.2) {
                    win.setAlphaValue(Math.max(0.0, remSec / 0.2));
                }
            }
        },
        'windowWillClose:': {
            types: ['void', ['id']],
            implementation: function(notif) {
                if (sound && !sound.isNil()) sound.stop;
                app.terminate(null);
            }
        }
    }
});

var ctrl = $.MOSWindowController.alloc.init;
win.setDelegate(ctrl);

var muteBtn = $.NSButton.alloc.initWithFrame($.NSMakeRect(28, 24, 34, 34));
muteBtn.setTitle($(''));
muteBtn.setBordered(false);
muteBtn.setTransparent(true);
muteBtn.setTarget(ctrl);
muteBtn.setAction('onMute:');
root.addSubview(muteBtn);

var dismissBtn = $.NSButton.alloc.initWithFrame($.NSMakeRect(352, 24, 120, 36));
dismissBtn.setTitle($(''));
dismissBtn.setBordered(false);
dismissBtn.setTransparent(true);
dismissBtn.setTarget(ctrl);
dismissBtn.setAction('onDismiss:');
dismissBtn.setKeyEquivalent($('\r'));
root.addSubview(dismissBtn);

var escBtn = $.NSButton.alloc.initWithFrame($.NSMakeRect(0, 0, 1, 1));
escBtn.setTitle($(''));
escBtn.setBordered(false);
escBtn.setTransparent(true);
escBtn.setTarget(ctrl);
escBtn.setAction('onDismiss:');
escBtn.setKeyEquivalent($('\x1b'));
root.addSubview(escBtn);

$.NSTimer.scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(0.05, ctrl, 'onTick:', null, true);

win.makeKeyAndOrderFront(null);
app.activateIgnoringOtherApps(true);
app.run;
JXA_EOF
then
    AUDIO_PID=""
    if [[ -n "$AUDIO_PATH" && -x /usr/bin/afplay ]]; then
        /usr/bin/afplay -v 0.10 "$AUDIO_PATH" &
        AUDIO_PID=$!
    fi
    /usr/bin/osascript -e 'use framework "Cocoa"' \
        -e 'use scripting additions' \
        -e 'current application'\''s NSApplication'\''s sharedApplication()'\''s setActivationPolicy:(current application'\''s NSApplicationActivationPolicyAccessory)' \
        -e 'current application'\''s NSApplication'\''s sharedApplication()'\''s activateIgnoringOtherApps:true' \
        -e "display alert \"$TITLE\" message \"$MESSAGE\" as informational buttons {\"Зрозуміло\"} default button \"Зрозуміло\" giving up after 60" \
        || true
    if [[ -n "$AUDIO_PID" ]]; then
        kill "$AUDIO_PID" 2>/dev/null || true
    fi
fi

exit 0
EOF

chmod 755 "$SCRIPT_PATH"
chown root:wheel "$SCRIPT_PATH"
echo "INFO: Скрипт розгорнуто в $SCRIPT_PATH"

# Підготовка лог-файлу з правами запису для користувацького LaunchAgent (UID 501/502)
rm -f /var/log/minute-of-silence.log 2>/dev/null || true
touch /tmp/minute-of-silence.log 2>/dev/null || true
chmod 666 /tmp/minute-of-silence.log 2>/dev/null || true

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
    <array>
        <dict>
            <key>Hour</key>
            <integer>8</integer>
            <key>Minute</key>
            <integer>59</integer>
        </dict>
        <dict>
            <key>Hour</key>
            <integer>9</integer>
            <key>Minute</key>
            <integer>0</integer>
        </dict>
    </array>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>/tmp/minute-of-silence.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/minute-of-silence.log</string>
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
