#!/bin/zsh
# Shoot the Live TV guide: build, drive the real app to the pinned fixture,
# capture the real composited window, and normalise it to the reference's own
# frame so it can be diffed against Design/reference/live-tv-guide.png.
#
#   scripts/guide-shot.sh [out.png] [WxH] [settleSeconds]
#
# Deterministic by construction: the fixture pins the lineup and the clock, so
# two shots taken a week apart are comparable. The window is captured rather
# than rendered offscreen because an ImageRenderer pass never materialises the
# grid's lazy stacks — it would photograph an empty guide and call it a layout.
set -euo pipefail
cd "$(dirname "$0")/.."

# One shot at a time. The build directory is shared and the app is killed by
# name, so concurrent runs would sabotage each other; queue instead of racing.
# zsh's own flock, not util-linux's — there is no flock(1) on macOS, and the
# missing binary made this exit instead of serialising.
LOCK=/tmp/vlinder-guide-shot.lock
: >>"$LOCK"
zmodload zsh/system 2>/dev/null || true
if ! zsystem flock -t 900 "$LOCK" 2>/dev/null; then
    echo "shot: FAILED — timed out waiting for another shot to finish" >&2
    exit 1
fi

# --live shoots real server data instead of the pinned fixture: useful for
# eyeballing the real EPG, useless for a round-to-round comparison, since the
# lineup and the clock both move under you.
FIXTURE_ARGS=(-GuideFixture 1)
LABEL=fixture
if [[ "${1:-}" == "--live" ]]; then FIXTURE_ARGS=(); LABEL=live; shift; fi

OUT="${1:-/tmp/guide.png}"
SIZE="${2:-1657x852}"
SETTLE="${3:-6}"
[[ "$OUT" = /* ]] || OUT="$PWD/$OUT"
W="${SIZE%x*}"; H="${SIZE#*x}"

xcodegen generate --quiet
# One build, and only the errors themselves: xcodebuild's failure dump is tens
# of kilobytes of frontend invocation nobody can read.
LOG=$(mktemp -t guide-build)
if ! xcodebuild -project Vlinder.xcodeproj -scheme Vlinder \
    -destination 'platform=macOS,arch=arm64' -quiet build >"$LOG" 2>&1; then
    grep -E "error:" "$LOG" | sort -u | head -40 >&2
    echo "build: FAILED" >&2
    rm -f "$LOG"; exit 1
fi
rm -f "$LOG"

APP=$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/Vlinder-*/Build/Products/Debug/Vlinder.app | head -1)
[[ -d "$APP" ]] || { echo "build product not found" >&2; exit 1 }

pkill -x Vlinder 2>/dev/null || true
for _ in $(seq 1 40); do pgrep -x Vlinder >/dev/null || break; /bin/sleep 0.25; done
rm -f "$OUT"; mkdir -p "$(dirname "$OUT")"

DIAG=$(mktemp -t guide-diag)
"$APP/Contents/MacOS/Vlinder" -ApplePersistenceIgnoreState YES \
    -GuideAuto 1 "${FIXTURE_ARGS[@]}" \
    -GuideShotSize "$SIZE" -GuideSettle "$SETTLE" \
    -AtriumAutoAppearance dark 2>"$DIAG" &
APP_PID=$!

# Wait for the app to name the window it wants photographed.
WIN=""
for _ in $(seq 1 $(( (SETTLE + 40) * 4 ))); do
    WIN=$(grep -m1 -o 'guide-window: [0-9]*' "$DIAG" 2>/dev/null | cut -d' ' -f2 || true)
    [[ -n "$WIN" ]] && break
    /bin/sleep 0.25
done

finish() {
    kill "$APP_PID" 2>/dev/null || true
    pkill -x Vlinder 2>/dev/null || true
}

if [[ -z "$WIN" ]]; then
    echo "shot: FAILED — app never named a window" >&2
    grep -E "guide-|error|Fatal|Crash" "$DIAG" | head -20 >&2 || true
    finish; rm -f "$DIAG"; exit 1
fi

CHROME=$(grep -m1 -o 'chrome=[0-9]*' "$DIAG" | cut -d= -f2)
: "${CHROME:=0}"

# By window id, not by screen region: a region grab photographs whatever is on
# top, which yields a screenshot of some other app and a confident verdict on it.
RAW=$(mktemp -t guide-raw).png
screencapture -x -o -l"$WIN" "$RAW"
finish

[[ -s "$RAW" ]] || { echo "shot: FAILED — window $WIN captured nothing" >&2; rm -f "$DIAG" "$RAW"; exit 1; }

# Normalise to 1x and cut the titlebar, so the frame is the guide pane alone at
# exactly the reference's bounds.
python3 - "$RAW" "$OUT" "$W" "$H" "$CHROME" <<'PY_CROP'
import io
import sys
from PIL import Image, ImageCms
raw, out, w, h, chrome = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
src = Image.open(raw)
# screencapture embeds the *display's* profile (here a DELL P2722H), while the
# reference PNG is plain sRGB. Left unmanaged the two frames are not comparable:
# the transform barely moves dark neutrals — which is why the greys matched and
# hid this — but moves saturated primaries a long way. The favourite star read
# #3950CE raw and is exactly #2A55D2 once managed.
icc = src.info.get("icc_profile")
im = src.convert("RGB")
if icc:
    transform = ImageCms.buildTransform(
        ImageCms.ImageCmsProfile(io.BytesIO(icc)),
        ImageCms.createProfile("sRGB"),
        "RGB", "RGB", renderingIntent=1)
    im = ImageCms.applyTransform(im, transform)
    print("colour: managed from the display profile to sRGB")
else:
    print("colour: no embedded profile, left as-is")
scale = im.width / (w if w else im.width)
if scale != 1:
    im = im.resize((round(im.width / scale), round(im.height / scale)), Image.LANCZOS)
# Content sits below the chrome; take the bottom h rows.
top = max(0, im.height - h)
im.crop((0, top, min(w, im.width), min(top + h, im.height))).save(out)
print(f"crop: chrome={chrome} -> {im.width}x{im.height} => {w}x{h}")
PY_CROP

grep -E "guide-flags|guide-fixture|guide-content" "$DIAG" | sort -u >&2 || true
rm -f "$DIAG" "$RAW"

[[ -f "$OUT" ]] || { echo "shot: FAILED — no file at $OUT" >&2; exit 1; }
echo "shot: $OUT [$LABEL] ($(sips -g pixelWidth -g pixelHeight "$OUT" | awk '/pixel/{printf "%s ", $2}'))"
