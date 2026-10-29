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

# ── 5. Відображення Bento Dark-Glass вікна (Cocoa + WKWebView + NSSound, гучність 10%) ─
export MOS_AUDIO_PATH="$AUDIO_PATH"
export MOS_DURATION="60"

echo "Minute of Silence: Відображення нативного Bento Dark-Glass вікна (Cocoa + WebKit)..."
if ! /usr/bin/osascript -l JavaScript << 'JXA_EOF'
ObjC.import('Cocoa');
ObjC.import('WebKit');

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

// Titled + FullSizeContentView gives native macOS rounded corners, shadow, and key-window focus
var styleMask = (1 << 0) | (1 << 15);
var win = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(
    rect,
    styleMask,
    $.NSBackingStoreBuffered,
    false
);
win.setTitle($('Хвилина мовчання'));
win.setTitlebarAppearsTransparent(true);
win.setTitleVisibility(1); // NSWindowTitleHidden
win.setOpaque(false);
win.setBackgroundColor($.NSColor.colorWithCalibratedRedGreenBlueAlpha(0.067, 0.071, 0.082, 1.0));
win.setHasShadow(true);
win.setLevel(3); // NSFloatingWindowLevel (TopMost)
win.setCollectionBehavior((1 << 0) | (1 << 8)); // CanJoinAllSpaces | FullScreenAuxiliary
win.setMovableByWindowBackground(true);

for (var i = 0; i <= 2; i++) {
    var btn = win.standardWindowButton(i);
    if (btn && !btn.isNil()) btn.setHidden(true);
}

var html = [
'<!DOCTYPE html><html><head><meta charset="utf-8"><style>',
'* { box-sizing: border-box; margin: 0; padding: 0; user-select: none; -webkit-user-select: none; }',
'html, body { width: 100%; height: 100%; overflow: hidden; background: #111215; font-family: -apple-system, BlinkMacSystemFont, "Inter", "Segoe UI", sans-serif; color: #FFFFFF; }',
'.card { width: 100%; height: 100%; border: 1.2px solid #25272F; border-radius: 12px; padding: 24px 28px 20px 28px; display: flex; flex-direction: column; justify-content: space-between; background: #111215; }',
'.top-bar { display: flex; justify-content: center; margin-bottom: 12px; }',
'.pill-badge { background: #1A1C22; border: 1px solid #2D3039; border-radius: 14px; padding: 6px 14px; display: inline-flex; align-items: center; gap: 8px; }',
'.pill-time { color: #F3F4F6; font-size: 13px; font-weight: 700; }',
'.pill-label { color: #9CA3AF; font-size: 11.5px; font-weight: 600; letter-spacing: 0.3px; }',
'.title { color: #FFFFFF; font-size: 19px; font-weight: 700; text-align: center; margin-bottom: 10px; }',
'.body-wrap { display: flex; flex-direction: column; align-items: center; justify-content: center; padding: 0 10px; margin-bottom: 12px; flex: 1; }',
'.desc { color: #9CA3AF; font-size: 13.5px; line-height: 20px; text-align: center; margin-bottom: 14px; }',
'.motto-box { background: #16181E; border-radius: 10px; padding: 7px 14px; color: #FBBF24; font-size: 13.5px; font-weight: 600; text-align: center; white-space: pre; }',
'.progress-track { width: 100%; height: 3px; background: #1E2026; border-radius: 1.5px; overflow: hidden; margin-bottom: 16px; }',
'.progress-bar { height: 100%; width: 100%; background: #F59E0B; border-radius: 1.5px; transition: width 0.04s linear; }',
'.footer { display: flex; align-items: center; justify-content: space-between; }',
'.footer-left { display: flex; align-items: center; gap: 6px; }',
'.icon-btn { width: 28px; height: 28px; border-radius: 6px; border: none; background: transparent; color: #9CA3AF; font-size: 14px; cursor: pointer; display: flex; align-items: center; justify-content: center; }',
'.icon-btn:hover { background: #22252D; color: #FFFFFF; }',
'.countdown { color: #6B7280; font-size: 12.5px; }',
'.dismiss-btn { background: #22252D; color: #F3F4F6; border: 1px solid #333742; border-radius: 10px; padding: 8px 18px; font-size: 13px; font-weight: 600; cursor: pointer; outline: none; }',
'.dismiss-btn:hover { background: #2F333E; border-color: #4B5263; }',
'</style></head><body>',
'<div class="card">',
'  <div class="top-bar">',
'    <div class="pill-badge">',
'      <svg width="13" height="13" viewBox="0 0 13 13"><path fill="#F59E0B" d="M6.5,1 C6.5,1 3,5.5 3,8.5 C3,10.4 4.6,12 6.5,12 C8.4,12 10,10.4 10,8.5 C10,5.5 6.5,1 6.5,1 Z"/></svg>',
'      <span class="pill-time">09:00</span>',
'      <span class="pill-label">• &nbsp;ХВИЛИНА МОВЧАННЯ</span>',
'    </div>',
'  </div>',
'  <div class="title">Загальнонаціональна хвилина мовчання</div>',
'  <div class="body-wrap">',
'    <div class="desc">Зупинимося на хвилину, щоб вшанувати пам\x27ять захисників, захисниць та всіх українців, чиї життя забрала війна.</div>',
'    <div class="motto-box">Пам\x27ятаємо.  Дякуємо.  Шануємо.</div>',
'  </div>',
'  <div class="progress-track"><div id="bar" class="progress-bar"></div></div>',
'  <div class="footer">',
'    <div class="footer-left">',
'      <button id="muteBtn" class="icon-btn" title="Вимкнути / увімкнути звук">🔊</button>',
'      <span id="cd" class="countdown">Закриється через ' + totalSeconds + ' с</span>',
'    </div>',
'    <button id="dismissBtn" class="dismiss-btn">Зрозуміло</button>',
'  </div>',
'</div>',
'<script>',
'var total = ' + totalSeconds + ';',
'var start = performance.now();',
'var muted = false;',
'var bar = document.getElementById("bar");',
'var cd = document.getElementById("cd");',
'var muteBtn = document.getElementById("muteBtn");',
'var dismissBtn = document.getElementById("dismissBtn");',
'muteBtn.addEventListener("click", function() {',
'  muted = !muted;',
'  muteBtn.textContent = muted ? "🔇" : "🔊";',
'  document.title = muted ? "MUTE" : "UNMUTE";',
'});',
'dismissBtn.addEventListener("click", function() { document.title = "CLOSE"; });',
'window.addEventListener("keydown", function(e) {',
'  if (e.key === "Escape" || e.key === "Enter" || e.key === " ") { document.title = "CLOSE"; }',
'});',
'setInterval(function() {',
'  var elapsed = (performance.now() - start) / 1000;',
'  var rem = Math.max(0, total - elapsed);',
'  bar.style.width = ((rem / total) * 100) + "%";',
'  cd.textContent = "Закриється через " + Math.ceil(rem) + " с";',
'  if (rem <= 0) { document.title = "CLOSE"; }',
'}, 40);',
'</script></body></html>'
].join('\n');

var config = $.WKWebViewConfiguration.alloc.init;
var webView = $.WKWebView.alloc.initWithFrameConfiguration($.NSMakeRect(0, 0, width, height), config);
webView.setValueForKey($.NSNumber.numberWithBool(false), $('drawsBackground'));
win.setContentView(webView);
webView.loadHTMLStringBaseURL($(html), $.NSURL.URLWithString($('https://local.corp')));

var sound = null;
if (audioPath.length > 0) {
    sound = $.NSSound.alloc.initWithContentsOfFileByReference($(audioPath), true);
    if (sound && !sound.isNil()) {
        sound.setVolume(defaultVolume);
        sound.play;
    }
}

win.makeKeyAndOrderFront(null);
app.activateIgnoringOtherApps(true);

var startTime = Date.now();
var isMuted = false;
var lastAction = '';

while (true) {
    $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.04));
    if (!win.isVisible) break;
    var elapsedSec = (Date.now() - startTime) / 1000.0;
    var remSec = totalSeconds - elapsedSec;
    var titleCmd = ObjC.unwrap(webView.title) || '';

    if (titleCmd === 'CLOSE' || remSec <= 0) {
        break;
    }
    if (titleCmd !== lastAction) {
        if (titleCmd === 'MUTE') {
            isMuted = true;
            if (sound && !sound.isNil()) sound.setVolume(0.0);
        } else if (titleCmd === 'UNMUTE') {
            isMuted = false;
            if (sound && !sound.isNil()) sound.setVolume(defaultVolume);
        }
        lastAction = titleCmd;
    }
    if (!isMuted && sound && !sound.isNil() && remSec <= 2.4 && remSec > 0) {
        sound.setVolume(defaultVolume * Math.max(0.0, remSec / 2.4));
    }
    if (remSec <= 0.2 && remSec > 0) {
        win.setAlphaValue(Math.max(0.0, remSec / 0.2));
    }
}

if (sound && !sound.isNil()) {
    sound.stop;
}
win.close;
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
