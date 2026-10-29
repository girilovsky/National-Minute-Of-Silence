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

# ── 3. Аудіо: пошук аудіотреку metronome.mp3 ──────────────────────────────────
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

# ── 5. Відображення Bento Dark-Glass вікна (100% нативний Cocoa AppKit, гучність 10%) ─
export MOS_AUDIO_PATH="$AUDIO_PATH"
export MOS_DURATION="60"

echo "Minute of Silence: Відображення нативного Bento Dark-Glass вікна (Cocoa AppKit)..."
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

// Titled + Closable + FullSizeContentView
var styleMask = (1 << 0) | (1 << 1) | (1 << 15);
var win = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(
    rect,
    styleMask,
    $.NSBackingStoreBuffered,
    false
);
win.setTitle($('Хвилина мовчання'));
win.setTitlebarAppearsTransparent(true);
win.setTitleVisibility(1); // NSWindowTitleHidden
win.setOpaque(true);
win.setBackgroundColor($.NSColor.colorWithCalibratedRedGreenBlueAlpha(0.067, 0.071, 0.082, 1.0));
win.setHasShadow(true);
win.setLevel(3); // NSFloatingWindowLevel
win.setCollectionBehavior((1 << 0) | (1 << 8));
win.setReleasedWhenClosed(false);

// Ховаємо лише кнопки згортання та розгортання, залишаючи червону кнопку закриття як додатковий контрол
for (var i = 1; i <= 2; i++) {
    var sbtn = win.standardWindowButton(i);
    if (sbtn && !sbtn.isNil()) sbtn.setHidden(true);
}

var root = win.contentView;
root.setWantsLayer(true);

function makeColor(r, g, b, a) {
    return $.NSColor.colorWithCalibratedRedGreenBlueAlpha(r / 255.0, g / 255.0, b / 255.0, a);
}

function addBox(bx, by, bw, bh, fillC, borderC, borderW, radius) {
    var box = $.NSBox.alloc.initWithFrame($.NSMakeRect(bx, by, bw, bh));
    box.setBoxType(4); // NSBoxCustom
    box.setBorderType(1); // NSLineBorder
    box.setTitlePosition(0); // NSNoTitle
    box.setContentViewMargins($.NSMakeSize(0, 0));
    box.setCornerRadius(radius);
    box.setBorderWidth(borderW);
    if (borderC) box.setBorderColor(borderC);
    if (fillC) box.setFillColor(fillC);
    root.addSubview(box);
    return box;
}

function addLabel(lx, ly, lw, lh, text, fontSize, isBold, color, align) {
    var tf = $.NSTextField.alloc.initWithFrame($.NSMakeRect(lx, ly, lw, lh));
    tf.setStringValue($(text));
    tf.setEditable(false);
    tf.setSelectable(false);
    tf.setBezeled(false);
    tf.setDrawsBackground(false);
    tf.setTextColor(color);
    tf.setFont(isBold ? $.NSFont.boldSystemFontOfSize(fontSize) : $.NSFont.systemFontOfSize(fontSize));
    tf.setAlignment(align); // 0 = Left, 1 = Center
    root.addSubview(tf);
    return tf;
}

// 1. Верхній бейдж (09:00 • ХВИЛИНА МОВЧАННЯ)
addBox(135, 282, 230, 30, makeColor(26, 28, 34, 1.0), makeColor(45, 48, 57, 1.0), 1.0, 14.0);
addLabel(135, 287, 230, 20, '🕯️ 09:00  •  ХВИЛИНА МОВЧАННЯ', 12.0, true, makeColor(243, 244, 246, 1.0), 1);

// 2. Заголовок
addLabel(20, 238, 460, 28, 'Загальнонаціональна хвилина мовчання', 19.0, true, makeColor(255, 255, 255, 1.0), 1);

// 3. Опис
addLabel(
    36, 172, 428, 48,
    "Зупинимося на хвилину, щоб вшанувати пам'ять захисників,\nзахисниць та всіх українців, чиї життя забрала війна.",
    13.5, false, makeColor(156, 163, 175, 1.0), 1
);

// 4. Плашка гасла
addBox(105, 118, 290, 36, makeColor(22, 24, 30, 1.0), makeColor(37, 39, 47, 1.0), 1.0, 10.0);
addLabel(105, 125, 290, 22, "Пам'ятаємо.   Дякуємо.   Шануємо.", 13.5, true, makeColor(251, 191, 36, 1.0), 1);

// 5. Прогрес-бар (трек + заповнення)
var barMaxW = 444.0;
addBox(28, 82, barMaxW, 4, makeColor(30, 32, 38, 1.0), makeColor(30, 32, 38, 1.0), 0.0, 2.0);
var barFill = addBox(28, 82, barMaxW, 4, makeColor(245, 158, 11, 1.0), makeColor(245, 158, 11, 1.0), 0.0, 2.0);

// 6. Футер: кнопка звуку, таймер зворотного відліку, кнопка "Зрозуміло"
addBox(28, 24, 34, 34, makeColor(26, 28, 34, 1.0), makeColor(45, 48, 57, 1.0), 1.0, 8.0);
var muteLabel = addLabel(28, 30, 34, 22, '🔊', 14.0, false, makeColor(243, 244, 246, 1.0), 1);
var cdLabel = addLabel(72, 30, 220, 20, 'Закриється через ' + totalSeconds + ' с', 12.5, false, makeColor(107, 114, 128, 1.0), 0);

addBox(352, 24, 120, 36, makeColor(34, 37, 45, 1.0), makeColor(51, 55, 66, 1.0), 1.0, 10.0);
addLabel(352, 31, 120, 22, 'Зрозуміло', 13.0, true, makeColor(243, 244, 246, 1.0), 1);

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
    echo "Minute of Silence: Fallback на нативний osascript alert..."
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

echo "Minute of Silence: Сповіщення завершено."
exit 0
