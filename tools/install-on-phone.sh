#!/bin/bash
# Build BPTracker for a device and install it without launching.
# Usage: tools/install-on-phone.sh [device name]   (default NotaMiPro; see `xcrun devicectl list devices`)
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DEVICE="${1:-NotaMiPro}"

xcodebuild -project BPTracker.xcodeproj -scheme BPTracker \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates -quiet build

APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/BPTracker-*/Build/Products/Debug-iphoneos/BPTracker.app | head -1)
xcrun devicectl device install app --device "$DEVICE" "$APP"
