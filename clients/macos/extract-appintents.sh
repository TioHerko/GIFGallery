#!/bin/bash
# Generate the App Intents metadata bundle (Metadata.appintents) inside the
# app — this is what Shortcuts reads to discover the app's intents. Xcode
# runs appintentsmetadataprocessor as a build phase; the hand-rolled SwiftPM
# bundle has to invoke it directly, feeding it the Xcode-style intermediates
# (.swiftconstvalues, SwiftFileList, dependency info) that the swift-build
# backend emits under .build/out. On toolchains whose SwiftPM lacks that
# backend the inputs don't exist; warn and skip — the app still works, it
# just won't surface Shortcuts actions.
#
# Usage: extract-appintents.sh <Debug|Release> <app-bundle-path> [products-dir]
set -euo pipefail

CONFIG="${1:?usage: extract-appintents.sh <Debug|Release> <app-bundle-path> [products-dir]}"
APP="${2:?usage: extract-appintents.sh <Debug|Release> <app-bundle-path> [products-dir]}"
PRODUCTS="${3:-}"

# Must match the platforms line in Package.swift.
DEPLOYMENT_TARGET=15.0

# The build root moves between toolchains (.build/out vs .build/apple), so it
# can't be hardcoded. Prefer the products dir the caller resolved via
# `swift build --show-bin-path` (the .build/<config> symlink isn't created
# for universal --arch builds, like CI's); fall back to that symlink.
if [ -z "$PRODUCTS" ]; then
  LC=$(echo "$CONFIG" | tr '[:upper:]' '[:lower:]')
  LINK=$(readlink ".build/$LC" 2>/dev/null || true)
  case "$LINK" in
    "") PRODUCTS=".build/out/Products/$CONFIG" ;;
    /*) PRODUCTS="$LINK" ;;
    *)  PRODUCTS=".build/$LINK" ;;
  esac
fi
BUILD_ROOT="${PRODUCTS%/Products/*}"
INT_BASE="$BUILD_ROOT/Intermediates.noindex/GIFGallery.build/$CONFIG/GIFGallery-p.build/Objects-normal"
if [ ! -d "$INT_BASE" ]; then
  echo "warning: $INT_BASE not found; skipping App Intents metadata (Shortcuts" >&2
  echo "warning: actions won't appear). Newer toolchains emit it automatically." >&2
  exit 0
fi

ARGS=()
for ARCH_DIR in "$INT_BASE"/*/; do
  ARCH=$(basename "$ARCH_DIR")
  [ -f "$ARCH_DIR/GIFGallery.SwiftFileList" ] || continue
  CONST_LIST="$ARCH_DIR/GIFGallery.SwiftConstValuesFileList"
  find "$ARCH_DIR" -name "*.swiftconstvalues" > "$CONST_LIST"
  ARGS+=(
    --target-triple "$ARCH-apple-macos$DEPLOYMENT_TARGET"
    --dependency-file "$ARCH_DIR/GIFGallery_dependency_info.dat"
    --source-file-list "$ARCH_DIR/GIFGallery.SwiftFileList"
    --swift-const-vals-list "$CONST_LIST"
  )
done

if [ ${#ARGS[@]} -eq 0 ]; then
  echo "warning: no per-arch intermediates under $INT_BASE; skipping App Intents metadata." >&2
  exit 0
fi

EMPTY_LIST=".build/appintents-empty.list"
: > "$EMPTY_LIST"

xcrun appintentsmetadataprocessor \
  --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
  --module-name GIFGallery \
  --sdk-root "$(xcrun --show-sdk-path --sdk macosx)" \
  --xcode-version "$(xcodebuild -version | awk '/Build version/{print $3}')" \
  --platform-family macOS \
  --deployment-target "$DEPLOYMENT_TARGET" \
  --bundle-identifier me.herko.gif.gallery \
  --output "$APP/Contents/Resources" \
  --binary-file "$APP/Contents/MacOS/GIFGallery" \
  --metadata-file-list "$EMPTY_LIST" \
  --static-metadata-file-list "$EMPTY_LIST" \
  --compile-time-extraction --deployment-aware-processing --no-app-shortcuts-localization \
  "${ARGS[@]}"

if [ -d "$APP/Contents/Resources/Metadata.appintents" ]; then
  echo "App Intents metadata written to $APP/Contents/Resources/Metadata.appintents"
else
  echo "warning: appintentsmetadataprocessor produced no metadata." >&2
fi
