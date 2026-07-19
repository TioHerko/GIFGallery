#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

swift build "$@" -c release

# The products directory moves between toolchains (.build/apple/... on older
# ones, .build/out/... on newer); ask SwiftPM instead of hardcoding it.
BIN=$(swift build "$@" -c release --show-bin-path)

APP="build/GIF Lobster.app"
APPEX="$APP/Contents/PlugIns/GIF Lobster Share.appex"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

mkdir -p "$APP/Contents/Resources"
cp "$BIN/GIFGallery" "$APP/Contents/MacOS/GIFGallery"
cp Sources/Info.plist "$APP/Contents/Info.plist"
# Fresh CFBundleVersion per build — see build.sh; without it Shortcuts keeps
# serving the previously indexed (possibly empty) App Intents metadata.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%y%m%d.%H%M%S)" "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Share extension bundle; CI signs it (with its own entitlements) before
# signing the app.
mkdir -p "$APPEX/Contents/MacOS"
cp "$BIN/ShareExtension" "$APPEX/Contents/MacOS/ShareExtension"
cp ShareExtension/Info.plist "$APPEX/Contents/Info.plist"

# Dock tile plug-in: draws the raw icon so the Dock can't squircle it.
DOCKTILE="$APP/Contents/PlugIns/GIF Lobster Dock.docktileplugin"
mkdir -p "$DOCKTILE/Contents/MacOS" "$DOCKTILE/Contents/Resources"
cp "$BIN/libDockTilePlugin.dylib" "$DOCKTILE/Contents/MacOS/DockTilePlugin"
cp DockTilePlugin/Info.plist "$DOCKTILE/Contents/Info.plist"
cp DockTilePlugin/DockIcon.png "$DOCKTILE/Contents/Resources/DockIcon.png"

# Shortcuts discovery — must land inside the bundle before CI signs it.
./extract-appintents.sh Release "$APP"
