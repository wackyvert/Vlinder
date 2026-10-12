#!/bin/zsh
# Shoot the Apple TV home screen with Vlinder focused in the top row, so the
# Top Shelf extension's content is what fills the frame.
#
#   scripts/tv-top-shelf-shot.sh out.png [settleSeconds]
#
# Assumes scripts/tv-shot.sh has already built, installed and seeded the app.
# The home-screen order lives in HeadBoard's AppOrder.plist, which is only read
# at boot — hence the shutdown/edit/boot dance rather than a live poke.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-/tmp/tv-top-shelf.png}"
SETTLE="${2:-25}"
[[ "$OUT" = /* ]] || OUT="$PWD/$OUT"
# Same one-simulator-per-agent rule as tv-shot.sh: this script shuts a
# device down and rewrites its HeadBoard state, so pointing it at the
# default would kill another harness's simulator mid-run.
UDID="${TV_UDID:-1C5EB61F-D7FD-43E2-A303-777E41AAFD55}"
BUNDLE=dev.jake.vlinder.tv
ORDER="$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/Library/com.apple.HeadBoard/AppOrder.plist"

xcrun simctl shutdown "$UDID" 2>/dev/null || true

python3 - "$ORDER" "$BUNDLE" <<'PY'
import plistlib, sys
path, bundle = sys.argv[1:3]
with open(path, 'rb') as handle:
    plist = plistlib.load(handle)
folder = plist['HBRootFolderKey']
items = folder['HBFolderItemsKey']
# HeadBoard lays the row out in array order, not by HBAppGridOrderKey — a first
# attempt that only lowered the order key left the icon exactly where it was.
# Both are set: array position is what actually moves it, the order key keeps
# the two consistent.
index = next((n for n, i in enumerate(items) if i['HBAppIdentifierKey'] == bundle), None)
if index is None:
    raise SystemExit(f'{bundle} is not on the home screen; install it first')
mine = items.pop(index)
mine['HBAppGridOrderKey'] = min(i['HBAppGridOrderKey'] for i in items) - 1000
items.insert(0, mine)
folder['HBFolderItemsKey'] = items
with open(path, 'wb') as handle:
    plistlib.dump(plist, handle)
print('home screen: %s moved to the front of the top row' % bundle)
PY

xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1
/bin/sleep "$SETTLE"
mkdir -p "$(dirname "$OUT")"
xcrun simctl io "$UDID" screenshot "$OUT" >/dev/null
sips -z 1080 1920 "$OUT" >/dev/null
echo "shot: $OUT (1920x1080)"
