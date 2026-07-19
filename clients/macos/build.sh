#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

swift build "$@"

APP="build/GIF Lobster.app"
APPEX="$APP/Contents/PlugIns/GIF Lobster Share.appex"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

mkdir -p "$APP/Contents/Resources"
cp .build/debug/GIFGallery "$APP/Contents/MacOS/GIFGallery"
cp Sources/Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

mkdir -p "$APPEX/Contents/MacOS"
cp .build/debug/ShareExtension "$APPEX/Contents/MacOS/ShareExtension"
cp ShareExtension/Info.plist "$APPEX/Contents/Info.plist"

# Shortcuts discovery — must land inside the bundle before signing.
./extract-appintents.sh Debug "$APP"

# The share extension only registers (and can only reach the shared app-group
# credentials) in a signed build. With a Team ID available, development-sign
# both bundles with the full entitlements; otherwise fall back to an ad-hoc
# signature so the appex at least launches, minus credential sharing.
[ -f signing.local.sh ] && source ./signing.local.sh
TEAM_ID="${DEVELOPMENT_TEAM:-}"
IDENTITY=""
if [ -n "$TEAM_ID" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Apple Development" | grep "$TEAM_ID" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)
fi

if [ -n "$IDENTITY" ]; then
  ./make-entitlements.sh "$TEAM_ID" build/entitlements
  codesign --force --sign "$IDENTITY" \
    --entitlements build/entitlements/appex.entitlements "$APPEX"
  codesign --force --sign "$IDENTITY" \
    --entitlements build/entitlements/app.entitlements "$APP"
  echo "Signed (development, team $TEAM_ID): share extension is functional."
else
  # Minimal ad-hoc entitlements: sandbox is mandatory for extensions, but
  # group entitlements would fail validation without a real team signature.
  cat > build/adhoc-appex.entitlements <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
PLIST
  codesign --force --sign - \
    --entitlements build/adhoc-appex.entitlements "$APPEX"
  codesign --force --sign - "$APP"
  echo "Ad-hoc signed: appex loads but can't share credentials with the app."
  echo "For a working share extension set DEVELOPMENT_TEAM (signing.local.sh)."
fi

echo "Built: $APP"
echo "Run:   open \"$APP\""
