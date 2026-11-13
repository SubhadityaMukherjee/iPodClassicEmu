#!/bin/bash
# ship.sh — build iPodClassic (Release) and install it on the iPhone, with
# optional TestFlight upload.
#
# Usage:
#   scripts/ship.sh            # build + install on the phone
#   scripts/ship.sh --tf       # install + archive + upload to TestFlight
#                              # (auto-increments the build number)
#
# Team: the Apple Developer Program is enrolled on team 365U99GNTQ (the
# personal team was upgraded in place when the membership was purchased).
set -euo pipefail

cd "$(dirname "$0")/.."
PROJ=iPodClassic.xcodeproj
SCHEME=iPodClassic
TEAM_PAID=365U99GNTQ
LOG=$(mktemp -t ipod_ship)

# Target device: $IPOD_DEVICE_UDID if set, otherwise the first connected
# physical iPhone (devicectl list).
UDID="${IPOD_DEVICE_UDID:-}"
if [ -z "$UDID" ]; then
  UDID=$(xcrun devicectl list devices 2>/dev/null \
    | grep -i "iphone" | grep -vi "simulated\|unavailable" \
    | grep -oE '[0-9A-F]{8}-[0-9A-F0-9]{16}' | head -1)
fi
[ -n "$UDID" ] || { echo "no connected iPhone found (set IPOD_DEVICE_UDID to override)"; exit 1; }

want_tf=false
for arg in "$@"; do
  case "$arg" in
    --tf) want_tf=true ;;
    *) echo "unknown flag: $arg (supported: --tf)"; exit 1 ;;
  esac
done

set_team() {
  sed -i '' "s/DEVELOPMENT_TEAM: [0-9A-Z]*/DEVELOPMENT_TEAM: $1/" project.yml
  xcodegen generate >/dev/null
}

TEAM=$(grep -o 'DEVELOPMENT_TEAM: [0-9A-Z]*' project.yml | awk '{print $2}')
if [ "$TEAM" != "$TEAM_PAID" ]; then set_team "$TEAM_PAID"; TEAM=$TEAM_PAID; fi
echo "==> Building Release (team $TEAM)..."
xcodebuild -project $PROJ -scheme $SCHEME -configuration Release \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build \
  > "$LOG" 2>&1 || { grep -E "error:" "$LOG" | head -4; exit 1; }
echo "==> Build OK"

APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/iPodClassic-*/Build/Products/Release-iphoneos/iPodClassic.app 2>/dev/null | head -1)
[ -n "$APP" ] || { echo "no Release-iphoneos product found"; exit 1; }

echo "==> Installing on phone..."
xcrun devicectl device install app --device "$UDID" "$APP" | grep -E "Installed|error" || true

if [ "$TEAM" = "$TEAM_PAID" ]; then
  echo "Done — installed with the paid team (valid ~1 year)."
else
  echo "Done — installed (non-paid team; expires in 7 days)."
fi

if $want_tf; then
  BUILD=$(grep -o 'CURRENT_PROJECT_VERSION: "[0-9]*"' project.yml | grep -o '[0-9]*')
  NEW=$((BUILD + 1))
  sed -i '' "s/CURRENT_PROJECT_VERSION: \"$BUILD\"/CURRENT_PROJECT_VERSION: \"$NEW\"/" project.yml
  xcodegen generate >/dev/null
  echo "==> Archiving for TestFlight (build $NEW)..."
  mkdir -p build
  xcodebuild archive -project $PROJ -scheme $SCHEME \
    -destination 'generic/platform=iOS' \
    -archivePath build/iPodClassic.xcarchive \
    -allowProvisioningUpdates -quiet > "$LOG" 2>&1 || { grep -E "error:" "$LOG" | head -4; exit 1; }

  cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM_PAID</string>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST

  echo "==> Uploading to App Store Connect..."
  xcodebuild -exportArchive -archivePath build/iPodClassic.xcarchive \
    -exportOptionsPlist build/ExportOptions.plist \
    -exportPath build/export \
    -allowProvisioningUpdates -quiet > "$LOG" 2>&1 || { grep -E "error:" "$LOG" | head -4; exit 1; }
  echo "Uploaded — build $NEW is processing on App Store Connect."
  echo "When it finishes processing, enable it for testing: App Store Connect → TestFlight → iPodClassic."
fi
