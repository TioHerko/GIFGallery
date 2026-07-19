#!/bin/bash
# Generate the final entitlement plists for the app and the share extension.
#
# The app group must be prefixed with the Apple Team ID, which is
# deliberately never committed to the repo — so this script writes the full
# entitlement plists (into a git-ignored directory) at signing time.
#
# Usage: make-entitlements.sh <TEAM_ID> <output-dir>
set -euo pipefail

TEAM_ID="${1:?usage: make-entitlements.sh <TEAM_ID> <output-dir>}"
OUT="${2:?usage: make-entitlements.sh <TEAM_ID> <output-dir>}"
mkdir -p "$OUT"

# Must match SharedStore.configure()/KeychainStore in GIFKit, which rebuild
# this same string from the code signature's Team ID at runtime.
GROUP="${TEAM_ID}.me.herko.gif.shared"

# The app group backs the shared UserDefaults suite only. It is NOT usable
# as a keychain access group: without a provisioning profile, secd ignores
# the application-groups entitlement for keychain purposes and grants no
# access groups at all (the token lives in the login keychain instead — see
# GIFKit's KeychainStore).
cat > "$OUT/app.entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>${GROUP}</string>
    </array>
</dict>
</plist>
PLIST

# App extensions must be sandboxed; network.client lets the upload reach the
# server from inside the sandbox.
cat > "$OUT/appex.entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>${GROUP}</string>
    </array>
</dict>
</plist>
PLIST

echo "Wrote $OUT/app.entitlements and $OUT/appex.entitlements (group: $GROUP)"
