#!/bin/bash
# Build, development-sign, and (optionally) install the iOS app for sideloading
# onto a registered device (your own iPad).
#
# Prerequisites (one-time):
#   1. Your developer Apple ID is signed into Xcode (Settings -> Accounts).
#   2. The target device is connected, unlocked, and has trusted this Mac.
#
# Your Apple Developer Team ID is read from the environment, not hard-coded, so
# it stays out of the repo. Provide it one of two ways:
#   export DEVELOPMENT_TEAM=XXXXXXXXXX          # in your shell, or
#   echo 'export DEVELOPMENT_TEAM=XXXXXXXXXX' > signing.local.sh   # untracked
# Find it at https://developer.apple.com/account -> Membership.
#
# Usage:
#   ./sideload.sh                           # archive + export a development-signed .ipa
#   ./sideload.sh <udid> [<udid> ...]       # also install it onto each device
#
# Register every target device (connect, unlock, trust) BEFORE running so the
# automatic development profile includes them all in one export.
set -euo pipefail

cd "$(dirname "$0")"

# Xcode's IPA-packaging step runs /usr/bin/rsync (openrsync), which spawns its
# local "server" side via `rsync` from PATH. If Homebrew's rsync resolves
# first, the two implementations disagree on flags and the export dies with
# "Copy failed". Pin Apple's tools ahead of everything else.
export PATH="/usr/bin:$PATH"

# Optional: a git-ignored file next to this script that exports DEVELOPMENT_TEAM.
[ -f signing.local.sh ] && source ./signing.local.sh

TEAM_ID="${DEVELOPMENT_TEAM:-${TEAM_ID:-}}"
if [ -z "$TEAM_ID" ]; then
  echo "error: no Team ID set. Run 'export DEVELOPMENT_TEAM=XXXXXXXXXX'" >&2
  echo "       (or put that line in an untracked signing.local.sh) and retry." >&2
  exit 1
fi

SCHEME="GIFGallery"
PROJECT="GIFGallery.xcodeproj"
BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/GIFGallery.xcarchive"
IPA_DIR="$BUILD_DIR/ipa"
DEVICE_UDIDS=("$@")

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Generate the export options at build time with the Team ID injected, so no
# identifier is committed. build/ is git-ignored.
EXPORT_PLIST="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>development</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>stripSwiftSymbols</key>
    <true/>
</dict>
</plist>
PLIST

# Fresh CFBundleVersion per build (applies to the app and the share extension
# alike): iOS only re-scans an app's App Intents metadata when the bundle
# version changes, so reinstalling with a fixed version leaves Shortcuts
# showing the previously indexed (possibly empty) action list.
BUILD_VERSION=$(date +%y%m%d.%H%M%S)

# -allowProvisioningUpdates lets xcodebuild create/download the Apple Development
# cert and a development provisioning profile automatically via your Xcode account.
echo "── Archiving ──"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CURRENT_PROJECT_VERSION="$BUILD_VERSION"

echo "── Exporting development-signed .ipa ──"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$IPA_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -allowProvisioningUpdates

IPA="$IPA_DIR/GIFGallery.ipa"
echo "Exported: $IPA"

if [ "${#DEVICE_UDIDS[@]}" -eq 0 ]; then
  echo "No device UDIDs passed; skipping install."
  echo "To install: xcrun devicectl device install app --device <udid> \"$IPA\""
  exit 0
fi

# Install onto each device. Keep going if one fails (e.g. locked/disconnected)
# so the others still get the app; report a non-zero exit if any failed.
FAILED=()
for UDID in "${DEVICE_UDIDS[@]}"; do
  echo "── Installing onto $UDID ──"
  if xcrun devicectl device install app --device "$UDID" "$IPA"; then
    echo "Installed on $UDID."
  else
    echo "::warning::Install failed on $UDID (locked, disconnected, or not in the profile?)."
    FAILED+=("$UDID")
  fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "Failed to install on: ${FAILED[*]}"
  exit 1
fi
echo "All installs succeeded. Launch it from each device's Home Screen."
