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
# Fresh CFBundleVersion per build: LaunchServices treats an unchanged version
# as the same registration, and the Shortcuts indexer then skips re-scanning
# the app's App Intents metadata.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%y%m%d.%H%M%S)" "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

mkdir -p "$APPEX/Contents/MacOS"
cp .build/debug/ShareExtension "$APPEX/Contents/MacOS/ShareExtension"
cp ShareExtension/Info.plist "$APPEX/Contents/Info.plist"

# Dock tile plug-in: draws the raw icon so the Dock can't squircle it.
DOCKTILE="$APP/Contents/PlugIns/GIF Lobster Dock.docktileplugin"
mkdir -p "$DOCKTILE/Contents/MacOS" "$DOCKTILE/Contents/Resources"
cp .build/debug/libDockTilePlugin.dylib "$DOCKTILE/Contents/MacOS/DockTilePlugin"
cp DockTilePlugin/Info.plist "$DOCKTILE/Contents/Info.plist"
cp DockTilePlugin/DockIcon.png "$DOCKTILE/Contents/Resources/DockIcon.png"

# Shortcuts discovery — must land inside the bundle before signing.
./extract-appintents.sh Debug "$APP"

# The share extension only registers (and can only reach the shared app-group
# credentials) in a signed build. With a Team ID available, development-sign
# both bundles with the full entitlements; otherwise fall back to an ad-hoc
# signature so the appex at least launches, minus credential sharing.
[ -f signing.local.sh ] && source ./signing.local.sh
TEAM_ID="${DEVELOPMENT_TEAM:-}"
IDENTITY="${SIGNING_IDENTITY:-}"
if [ -n "$TEAM_ID" ] && [ -z "$IDENTITY" ]; then
  # Prefer Developer ID: an "Apple Development" signature only runs with an
  # embedded provisioning profile (Gatekeeper blocks it as "malware" without
  # one), and this bundle has no profile. A locally built Developer ID app is
  # never quarantined, so it runs without notarization.
  # Match the team via the certificate's OU (the display name carries the
  # personal cert ID instead) and sign by SHA-1 hash — duplicate cert copies
  # make names ambiguous to codesign.
  ALL_CERTS=$(security find-certificate -a -Z -p 2>/dev/null)
  for KIND in "Developer ID Application" "Apple Development"; do
    while read -r HASH; do
      if printf '%s\n' "$ALL_CERTS" \
        | awk -v h="$HASH" '/^SHA-1 hash:/{keep=($3==h)} /-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/{if(keep)print}' \
        | openssl x509 -noout -subject 2>/dev/null | grep -q "OU *= *$TEAM_ID"; then
        IDENTITY="$HASH"
        break
      fi
    done < <(security find-identity -v -p codesigning 2>/dev/null \
      | grep "$KIND" | sed -E 's/^ *[0-9]+\) ([0-9A-F]+) .*/\1/')
    [ -n "$IDENTITY" ] && break
  done
fi

if [ -n "$IDENTITY" ]; then
  ./make-entitlements.sh "$TEAM_ID" build/entitlements
  codesign --force --sign "$IDENTITY" "$DOCKTILE"
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
  codesign --force --sign - "$DOCKTILE"
  codesign --force --sign - \
    --entitlements build/adhoc-appex.entitlements "$APPEX"
  codesign --force --sign - "$APP"
  echo "Ad-hoc signed: appex loads but can't share credentials with the app."
  echo "For a working share extension set DEVELOPMENT_TEAM (signing.local.sh)."
fi

echo "Built: $APP"
echo "Run:   open \"$APP\""
