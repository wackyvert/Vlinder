#!/bin/zsh
# Shoot the macOS build's window with the given launch arguments, colour-managed
# to sRGB. Counterpart of tv-shot.sh so critics compare like with like.
#   scripts/mac-shot.sh out.png [settle] [-- launch args...]
set -euo pipefail
cd "$(dirname "$0")/.."
LOCK=/tmp/vlinder-mac-shot.lock; : >>"$LOCK"
zmodload zsh/system 2>/dev/null || true
zsystem flock -t 900 "$LOCK" || { echo "shot: FAILED — lock timeout" >&2; exit 1 }
OUT="${1:-/tmp/mac.png}"; shift || true
SETTLE="${1:-10}"; [[ "${1:-}" == "--" ]] || shift || true
[[ "${1:-}" == "--" ]] && shift
[[ "$OUT" = /* ]] || OUT="$PWD/$OUT"

xcodegen generate --quiet
LOG=$(mktemp -t mac-build)
if ! xcodebuild -project Vlinder.xcodeproj -scheme Vlinder -destination 'platform=macOS,arch=arm64' -quiet build >"$LOG" 2>&1; then
    grep -E "error:" "$LOG" | sed 's|.*/Vlinder/||' | sort -u | head -40 >&2; echo "build: FAILED" >&2; rm -f "$LOG"; exit 1
fi
rm -f "$LOG"
APP=$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/Vlinder-*/Build/Products/Debug/Vlinder.app | head -1)
pkill -x Vlinder 2>/dev/null || true
# Wait for the old instance to actually exit: a second copy launched while the
# first is still dying hands off to it and sits in the run loop with no window.
for _ in $(seq 1 40); do pgrep -x Vlinder >/dev/null || break; /bin/sleep 0.25; done
# -GuideAuto sizes the window; reuse only its window sizing via -GuideShotSize.
"$APP/Contents/MacOS/Vlinder" -ApplePersistenceIgnoreState YES -AtriumAutoAppearance dark -AtriumAutoWindow 1920x1080 "$@" >/dev/null 2>&1 &
/bin/sleep "$SETTLE"
WIN=$(swift - <<'SW' 2>/dev/null
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerName as String] as? String) == "Vlinder" && (w[kCGWindowLayer as String] as? Int) == 0 {
    print(w[kCGWindowNumber as String]!); break
}
SW
)
[[ -n "$WIN" ]] || { echo "shot: FAILED — no Vlinder window" >&2; pkill -x Vlinder; exit 1 }
mkdir -p "$(dirname "$OUT")"
screencapture -x -o -l"$WIN" "$OUT"
pkill -x Vlinder 2>/dev/null || true
python3 - "$OUT" <<'PY'
import io, sys
from PIL import Image, ImageCms
p=sys.argv[1]; src=Image.open(p); im=src.convert("RGB")
if (icc:=src.info.get("icc_profile")):
    im=ImageCms.applyTransform(im, ImageCms.buildTransform(ImageCms.ImageCmsProfile(io.BytesIO(icc)), ImageCms.createProfile("sRGB"), "RGB","RGB", renderingIntent=1))
if im.width>1920: im=im.resize((im.width//2, im.height//2), Image.LANCZOS)
im.save(p); print(f"shot: {p} ({im.width}x{im.height}) args: {sys.argv[1:]}")
PY
