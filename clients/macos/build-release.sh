#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

swift build "$@" -c release

APP="build/GIF Gallery.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

mkdir -p "$APP/Contents/Resources"
cp .build/apple/Products/Release/GIFGallery "$APP/Contents/MacOS/GIFGallery"
cp Sources/Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

