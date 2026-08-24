#!/bin/zsh
# Build Vlinder for macOS and install it to /Applications, replacing any
# previous copy, then launch it. Keeps Spotlight/Dock pointing at one
# canonical, current app instead of a DerivedData path.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet
xcodebuild -project Vlinder.xcodeproj -scheme Vlinder \
    -destination 'platform=macOS,arch=arm64' -quiet build

APP=$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/Vlinder-*/Build/Products/Debug/Vlinder.app | head -1)
[[ -d "$APP" ]] || { echo "build product not found" >&2; exit 1 }

pkill -x Vlinder 2>/dev/null || true
sleep 1
ditto "$APP" /Applications/Vlinder.app
open /Applications/Vlinder.app
echo "Installed and launched /Applications/Vlinder.app ($(date '+%b %d %H:%M'))"
