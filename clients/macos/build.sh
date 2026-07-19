#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

swift build "$@"

APP="build/GIF Lobster.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

mkdir -p "$APP/Contents/Resources"
cp .build/debug/GIFGallery "$APP/Contents/MacOS/GIFGallery"
cp Sources/Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "Built: $APP"
echo "Run:   open \"$APP\""
