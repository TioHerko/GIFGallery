#!/bin/bash
# Build, App Store-sign, and upload the iOS app to TestFlight.
#
# Prerequisites (one-time):
#   1. Your developer Apple ID is signed into Xcode (Settings -> Accounts) —
#      same requirement as sideload.sh. Automatic signing creates the Apple
#      Distribution certificate and App Store profiles on first run.
#   2. An app record exists in App Store Connect (https://appstoreconnect.apple.com
#      -> My Apps -> "+") for bundle ID me.herko.GIFGallery. This cannot be
#      created from the command line.
#
# Your Team ID comes from the environment or signing.local.sh, same as
# sideload.sh:
#   export DEVELOPMENT_TEAM=XXXXXXXXXX
#
# Auth for the upload step, either:
#   - the Apple ID signed into Xcode (default; nothing to configure), or
#   - an App Store Connect API key, for headless use:
#       export ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=<uuid> ASC_KEY_PATH=~/AuthKey_XXXXXXXXXX.p8
#     (create one at App Store Connect -> Users and Access -> Integrations,
#      role "App Manager"; these can also live in signing.local.sh)
#
# Usage:
#   ./testflight.sh                 # archive, sign, upload to TestFlight
#   ./testflight.sh --export-only   # stop after producing build/ipa/GIFGallery.ipa
#
# After the upload, the build appears in App Store Connect -> TestFlight once
# processing finishes (a few minutes; Apple emails you). Internal testers get
# it immediately; external testers need a one-time Beta App Review.
set -euo pipefail

cd "$(dirname "$0")"

# Xcode's IPA-packaging step runs /usr/bin/rsync (openrsync), which spawns its
# local "server" side via `rsync` from PATH. If Homebrew's rsync resolves
# first, the two implementations disagree on flags and the export dies with
# "Copy failed". Pin Apple's tools ahead of everything else.
export PATH="/usr/bin:$PATH"

[ -f signing.local.sh ] && source ./signing.local.sh

TEAM_ID="${DEVELOPMENT_TEAM:-${TEAM_ID:-}}"
if [ -z "$TEAM_ID" ]; then
  echo "error: no Team ID set. Run 'export DEVELOPMENT_TEAM=XXXXXXXXXX'" >&2
  echo "       (or put that line in an untracked signing.local.sh) and retry." >&2
  exit 1
fi

EXPORT_ONLY=0
[ "${1:-}" = "--export-only" ] && EXPORT_ONLY=1

# App Store Connect API key (optional; falls back to the Xcode account).
AUTH_FLAGS=()
if [ -n "${ASC_KEY_ID:-}" ]; then
  : "${ASC_ISSUER_ID:?ASC_KEY_ID is set but ASC_ISSUER_ID is not}"
  : "${ASC_KEY_PATH:?ASC_KEY_ID is set but ASC_KEY_PATH is not}"
  AUTH_FLAGS=(
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
    -authenticationKeyPath "${ASC_KEY_PATH/#\~/$HOME}"
  )
fi

SCHEME="GIFGallery"
PROJECT="GIFGallery.xcodeproj"
BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/GIFGallery.xcarchive"
IPA_DIR="$BUILD_DIR/ipa"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Same scheme as sideload.sh: unique, monotonically increasing CFBundleVersion
# per build. TestFlight rejects an upload that reuses a build number for the
# same marketing version, and the override applies to the app and share
# extension alike (App Store validation requires them to match).
BUILD_VERSION=$(date +%y%m%d.%H%M%S)

# "upload" hands the signed build to App Store Connect from inside
# -exportArchive; "export" just writes the .ipa locally.
DESTINATION="upload"
[ "$EXPORT_ONLY" = 1 ] && DESTINATION="export"

# Generated at build time with the Team ID injected, so no identifier is
# committed. build/ is git-ignored. manageAppVersionAndBuildNumber is off
# because we stamp our own build number above.
EXPORT_PLIST="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>${DESTINATION}</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
    <key>uploadSymbols</key>
    <true/>
    <key>stripSwiftSymbols</key>
    <true/>
</dict>
</plist>
PLIST

echo "── Archiving (build ${BUILD_VERSION}) ──"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  ${AUTH_FLAGS[@]+"${AUTH_FLAGS[@]}"} \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CURRENT_PROJECT_VERSION="$BUILD_VERSION"

if [ "$EXPORT_ONLY" = 1 ]; then
  echo "── Exporting App Store-signed .ipa (no upload) ──"
else
  echo "── Signing and uploading to App Store Connect ──"
fi
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$IPA_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -allowProvisioningUpdates \
  ${AUTH_FLAGS[@]+"${AUTH_FLAGS[@]}"}

if [ "$EXPORT_ONLY" = 1 ]; then
  echo "Exported: $IPA_DIR/GIFGallery.ipa"
else
  echo "Uploaded build ${BUILD_VERSION}. It will appear under TestFlight in"
  echo "App Store Connect once processing finishes (Apple emails you)."
fi
