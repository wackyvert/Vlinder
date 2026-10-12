#!/bin/zsh
# Shoot the tvOS build on the Apple TV 4K simulator: build, install, launch with
# the given launch arguments, screenshot, normalise to 1920x1080.
#
#   scripts/tv-shot.sh out.png [settleSeconds] [-- launch args...]
#   scripts/tv-shot.sh Design/reference/tvos/guide.png 14 -- -GuideAuto 1 -GuideFixture 1
#
# The simulator is seeded with the Mac app's own session the first time, so the
# TV build starts signed in against the real server. Serialised on a lock like
# guide-shot.sh: one simulator, one build directory.
set -euo pipefail
cd "$(dirname "$0")/.."
zmodload zsh/system 2>/dev/null || true

OUT="${1:-/tmp/tv.png}"; shift || true
SETTLE="${1:-12}"; [[ "${1:-}" == "--" ]] || shift || true
[[ "${1:-}" == "--" ]] && shift
[[ "$OUT" = /* ]] || OUT="$PWD/$OUT"
# One simulator per agent. Six Apple TV simulators exist; a builder sets
# TV_UDID to its own so two harnesses never terminate each other's app.
#   1C5EB61F-D7FD-43E2-A303-777E41AAFD55  lead
#   64008F6B-C2D8-464B-9DC9-9C69FC616560  home / libraries
#   F732A792-5A54-4CDC-A53A-C92BBA6D531F  live tv
#   0B5372B4-EBF6-4476-803C-A0A2730720FF  player
#   CE9FD9B3-9E7D-4270-B5AA-69535AA4C032  connect / settings / search
#   910BD455-7C75-4A92-A5F2-EBFEDCC92468  top shelf / siri
UDID="${TV_UDID:-1C5EB61F-D7FD-43E2-A303-777E41AAFD55}"
LOCK="/tmp/vlinder-tv-shot-$UDID.lock"; : >>"$LOCK"
zsystem flock -t 900 "$LOCK" || { echo "shot: FAILED — lock timeout" >&2; exit 1 }
BUNDLE=dev.jake.vlinder.tv

xcodegen generate --quiet
LOG=$(mktemp -t tv-build)
if ! xcodebuild -project Vlinder.xcodeproj -scheme VlinderTV \
    -destination "platform=tvOS Simulator,id=$UDID" -quiet build >"$LOG" 2>&1; then
    grep -E "error:" "$LOG" | sed 's|.*/Vlinder/||' | sort -u | head -40 >&2
    echo "build: FAILED" >&2; rm -f "$LOG"; exit 1
fi
rm -f "$LOG"
APP=$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/Vlinder-*/Build/Products/Debug-appletvsimulator/Vlinder.app | head -1)

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1
# Seed the session once from the Mac app's fallback slot. (The app then moves it
# into the simulator keychain, so to sign out for a Connect-screen shot use
# `xcrun simctl keychain $UDID reset` — deleting the defaults key is not enough.)
if ! xcrun simctl spawn "$UDID" defaults read "$BUNDLE" vlinder.accounts.fallback >/dev/null 2>&1; then
    python3 - "$UDID" "$BUNDLE" <<'PY'
import plistlib, subprocess, sys
udid, bundle = sys.argv[1:3]
p = plistlib.load(open('/Users/jake/Library/Containers/dev.jake.vlinder/Data/Library/Preferences/dev.jake.vlinder.plist','rb'))
for key in ('vlinder.accounts.fallback', 'vlinder.settings'):
    subprocess.run(['xcrun','simctl','spawn',udid,'defaults','write',bundle,key,'-data',bytes(p[key]).hex()], check=True)
print("seeded session into the simulator")
PY
fi
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch "$UDID" "$BUNDLE" "$@" >/dev/null
/bin/sleep "$SETTLE"
mkdir -p "$(dirname "$OUT")"
xcrun simctl io "$UDID" screenshot "$OUT" >/dev/null
sips -z 1080 1920 "$OUT" >/dev/null
echo "shot: $OUT (1920x1080) args: $*"
