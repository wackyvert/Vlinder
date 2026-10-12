#!/bin/zsh
# Shoot the Live TV Atrium: build, drive the real app to a known card against
# the real server, render one frame offscreen to a PNG, and report what the
# scene costs at 4K.
#
#   scripts/wall-shot.sh out.png [row] [column] [WxH] [benchSeconds]
#
# Renders through SCNRenderer, not the window, so the frame is exactly the size
# asked for regardless of the sidebar, the toolbar or the display scale.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-/tmp/wall.png}"
ROW="${2:-1}"
COL="${3:-4}"
SIZE="${4:-1600x900}"
BENCH="${5:-2.0}"
SETTLE="${SETTLE:-6}"

[[ "$OUT" = /* ]] || OUT="$PWD/$OUT"

xcodegen generate --quiet
xcodebuild -project Vlinder.xcodeproj -scheme Vlinder \
    -destination 'platform=macOS,arch=arm64' -quiet build

APP=$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/Vlinder-*/Build/Products/Debug/Vlinder.app | head -1)
[[ -d "$APP" ]] || { echo "build product not found" >&2; exit 1 }

pkill -x Vlinder 2>/dev/null || true
rm -f "$OUT"

"$APP/Contents/MacOS/Vlinder" \
    -LiveWallAuto 1 \
    -LiveWallRow "$ROW" \
    -LiveWallColumn "$COL" \
    -LiveWallShot "$OUT" \
    -LiveWallShotSize "$SIZE" \
    -LiveWallBench "$BENCH" \
    -LiveWallSettle "$SETTLE" \
    -LiveWallQuit 1 \
    -AtriumAutoWindow 1600x1000 \
    -AtriumAutoAppearance dark 2>&1 | grep -E "wall-shot|wall-bench|wall-data|wall-epg|wall-focus|gave up" || true

pkill -x Vlinder 2>/dev/null || true

# The app is sandboxed: when it cannot write where we asked, it writes into its
# own container and says so. Bring the file out here.
CONTAINER_DIR="$HOME/Library/Containers/dev.jake.vlinder/Data/tmp"
for NAME in "$(basename "$OUT")" "$(basename "${OUT%.png}-step.png")"; do
    if [[ ! -f "$(dirname "$OUT")/$NAME" && -f "$CONTAINER_DIR/$NAME" ]]; then
        mkdir -p "$(dirname "$OUT")"
        mv "$CONTAINER_DIR/$NAME" "$(dirname "$OUT")/$NAME"
    fi
done

if [[ -f "$OUT" ]]; then
    echo "shot: $OUT ($(sips -g pixelWidth -g pixelHeight "$OUT" 2>/dev/null | awk '/pixel/{printf "%s ", $2}'))"
else
    echo "shot: FAILED — no file at $OUT" >&2
    exit 1
fi
