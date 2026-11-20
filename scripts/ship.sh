#!/bin/bash
# ship.sh — build iPodClassic (Release) and ship it: install on the iPhone
# AND upload to TestFlight. TestFlight is the DEFAULT because dev-signed
# installs die whenever Apple invalidates their Xcode-managed provisioning
# profile (the 2026-11-20 overnight "app no longer available" incident);
# TestFlight builds carry App Store profiles and are immune to that churn.
#
# Usage:
#   scripts/ship.sh            # phone install + TestFlight upload (default)
#   scripts/ship.sh --dev      # phone install only (QA; no TF upload)
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

want_dev=false
for arg in "$@"; do
  case "$arg" in
    --dev) want_dev=true ;;
    --tf) echo "note: TestFlight is now the default; --tf is a no-op" ;;
    *) echo "unknown flag: $arg (supported: --dev)"; exit 1 ;;
  esac
done

set_team() {
  sed -i '' "s/DEVELOPMENT_TEAM: [0-9A-Z]*/DEVELOPMENT_TEAM: $1/" project.yml
  xcodegen generate >/dev/null
}

TEAM=$(grep -o 'DEVELOPMENT_TEAM: [0-9A-Z]*' project.yml | awk '{print $2}')
if [ "$TEAM" != "$TEAM_PAID" ]; then set_team "$TEAM_PAID"; TEAM=$TEAM_PAID; fi

if ! $want_dev; then
  # Bump the build number BEFORE building so the phone install and the
  # TestFlight archive are the same build.
  BUILD=$(grep -o 'CURRENT_PROJECT_VERSION: "[0-9]*"' project.yml | grep -o '[0-9]*')
  NEW=$((BUILD + 1))
  sed -i '' "s/CURRENT_PROJECT_VERSION: \"$BUILD\"/CURRENT_PROJECT_VERSION: \"$NEW\"/" project.yml
  xcodegen generate >/dev/null
  echo "==> TestFlight build $NEW"
fi

echo "==> Building Release (team $TEAM)..."
xcodebuild -project $PROJ -scheme $SCHEME -configuration Release \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build \
  > "$LOG" 2>&1 || { grep -E "error:" "$LOG" | head -4; exit 1; }
echo "==> Build OK"

APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/iPodClassic-*/Build/Products/Release-iphoneos/iPodClassic.app 2>/dev/null | head -1)
[ -n "$APP" ] || { echo "no Release-iphoneos product found"; exit 1; }

echo "==> Installing on phone..."
xcrun devicectl device install app --device "$UDID" "$APP" | grep -E "Installed|error" || true

# VERIFY what actually got embedded — never just assert validity. A
# dev-signed install dies the day its provisioning profile or any bound
# certificate expires (or is invalidated server-side — Xcode-managed
# "iOS Team Provisioning Profile" instances get regenerated, and old
# installs stop launching). Effective lifetime = min(profile, certs).
echo "==> Verifying provisioning..."
EMBED="$APP/embedded.mobileprovision"
if security cms -D -i "$EMBED" > /tmp/ship_prov.plist 2>/dev/null; then
  PNAME=$(plutil -extract Name raw /tmp/ship_prov.plist)
  PUUID=$(plutil -extract UUID raw /tmp/ship_prov.plist)
  PEXP=$(plutil -extract ExpirationDate raw /tmp/ship_prov.plist)
  echo "    profile: $PNAME ($PUUID) expires $PEXP"
  MIN_DATE=$(python3 - << 'PY'
import plistlib, subprocess, tempfile, os, datetime
pl = plistlib.loads(open('/tmp/ship_prov.plist','rb').read())
best = pl.get('ExpirationDate')
if isinstance(best, str):
    best = datetime.datetime.fromisoformat(best.replace('Z', '+00:00'))
if best.tzinfo is None:  # plistlib returns naive datetimes in UTC
    best = best.replace(tzinfo=datetime.timezone.utc)
for c in pl.get('DeveloperCertificates', []):
    der = c if isinstance(c, bytes) else c.data
    with tempfile.NamedTemporaryFile(suffix='.der', delete=False) as f:
        f.write(der); p = f.name
    end = subprocess.run(['openssl', 'x509', '-in', p, '-noout', '-enddate'],
                         capture_output=True, text=True).stdout.strip().split('=')[1]
    e = datetime.datetime.strptime(end, '%b %d %H:%M:%S %Y %Z').replace(tzinfo=datetime.timezone.utc)
    os.unlink(p)
    if e < best:
        best = e
print(best.strftime('%Y-%m-%d'))
PY
)
  THRESH=$(date -v+30d +%s)
  ACTUAL=$(date -j -f "%Y-%m-%d" "$MIN_DATE" "+%s")
  if [ "$ACTUAL" -lt "$THRESH" ]; then
    echo "    WARNING: this install dies by $MIN_DATE (within 30 days)."
    echo "    Rebuild with -allowProvisioningUpdates (fresh profile) or ship --tf for stable installs."
  else
    echo "    OK — dev-signed install valid until $MIN_DATE (profile ∩ signing certs)."
  fi
else
  echo "    WARNING: could not decode embedded.mobileprovision — check signing manually."
fi

if $want_dev; then
  echo "Done — dev install on the phone (QA only; expires with its provisioning profile)."
  exit 0
fi

echo "==> Archiving for TestFlight..."
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
echo "Uploaded — TestFlight is processing the build."
echo "When it finishes processing, enable it for testing: App Store Connect → TestFlight → iPodClassic."
