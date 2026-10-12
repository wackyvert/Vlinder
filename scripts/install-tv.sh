#!/bin/zsh
# Build VlinderTV, sign it with the team in project.yml, and install + launch it
# on a paired Apple TV. Pairing is done once on the TV itself:
# Settings › Remotes and Devices › Remote App and Devices, then Xcode ›
# Devices and Simulators shows the code prompt.
#
#   scripts/install-tv.sh [Bedroom|Living Room|Basement|<udid>]
#
# `xcrun devicectl list devices` names the paired sets.
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="${1:-Bedroom}"
if [[ "$TARGET" =~ ^[0-9A-F-]{36}$ ]]; then DEV="$TARGET"; else
  DEV=$(xcrun devicectl list devices 2>/dev/null | awk -v n="$TARGET" 'index($0,n)==1 {for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-/) {print $i; exit}}')
fi
[[ -n "${DEV:-}" ]] || { echo "no paired Apple TV named '$TARGET'" >&2; xcrun devicectl list devices; exit 1 }

xcodegen generate --quiet
xcodebuild -project Vlinder.xcodeproj -scheme VlinderTV -destination "platform=tvOS,id=$DEV" \
    -allowProvisioningUpdates -quiet build
APP=$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/Vlinder-*/Build/Products/Debug-appletvos/Vlinder.app | head -1)
xcrun devicectl device install app --device "$DEV" "$APP" >/dev/null
xcrun devicectl device process launch --device "$DEV" dev.jake.vlinder.tv >/dev/null
echo "Installed and launched Vlinder on $TARGET ($(date '+%b %d %H:%M'))"
