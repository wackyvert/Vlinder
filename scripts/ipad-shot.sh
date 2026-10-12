#!/bin/zsh
# Shoot the iOS build on an iPad simulator (landscape) — the desk-side bar when
# the Mac window cannot be captured (macOS screen-recording permission is a
# TCC grant the harness cannot issue). Same app, same layouts, no permission.
#   scripts/ipad-shot.sh out.png [settle] [-- launch args...]
set -euo pipefail
cd "$(dirname "$0")/.."
zmodload zsh/system 2>/dev/null || true
# iPad Pro 13-inch (M5); override with IPAD_UDID for a second builder.
UDID="${IPAD_UDID:-51836B43-07CB-4C68-8209-EDF67D5225A4}"
LOCK="/tmp/vlinder-ipad-shot-$UDID.lock"; : >>"$LOCK"
zsystem flock -t 900 "$LOCK" || { echo "shot: FAILED — lock timeout" >&2; exit 1 }
OUT="${1:-/tmp/ipad.png}"; shift || true
SETTLE="${1:-12}"; [[ "${1:-}" == "--" ]] || shift || true
[[ "${1:-}" == "--" ]] && shift
[[ "$OUT" = /* ]] || OUT="$PWD/$OUT"
BUNDLE=dev.jake.vlinder

xcodegen generate --quiet
LOG=$(mktemp -t ipad-build)
if ! xcodebuild -project Vlinder.xcodeproj -scheme Vlinder -destination "platform=iOS Simulator,id=$UDID" -quiet build >"$LOG" 2>&1; then
    grep -E "error:" "$LOG" | sed 's|.*/Vlinder/||' | sort -u | head -40 >&2; echo "build: FAILED" >&2; rm -f "$LOG"; exit 1
fi
rm -f "$LOG"
APP=$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/Vlinder-*/Build/Products/Debug-iphonesimulator/Vlinder.app | head -1)
xcrun simctl boot "$UDID" 2>/dev/null || true; xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1
if ! xcrun simctl spawn "$UDID" defaults read "$BUNDLE" vlinder.accounts.fallback >/dev/null 2>&1; then
    python3 - "$UDID" "$BUNDLE" <<'PY'
import plistlib, subprocess, sys
udid, bundle = sys.argv[1:3]
p = plistlib.load(open('/Users/jake/Library/Containers/dev.jake.vlinder/Data/Library/Preferences/dev.jake.vlinder.plist','rb'))
for key in ('vlinder.accounts.fallback','vlinder.settings'):
    subprocess.run(['xcrun','simctl','spawn',udid,'defaults','write',bundle,key,'-data',bytes(p[key]).hex()], check=True)
print("seeded session into the iPad simulator")
PY
fi
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch "$UDID" "$BUNDLE" "$@" >/dev/null
/bin/sleep "$SETTLE"
mkdir -p "$(dirname "$OUT")"
xcrun simctl io "$UDID" screenshot "$OUT" >/dev/null
python3 - "$OUT" <<'PY'
import sys; from PIL import Image
p=sys.argv[1]; im=Image.open(p)
if im.height>im.width: im=im.rotate(-90, expand=True)   # landscape frame for the bar
if im.width>2000: im=im.resize((im.width//2, im.height//2), Image.LANCZOS)
im.save(p); print(f"shot: {p} ({im.width}x{im.height})")
PY
