#!/bin/bash
# Build an ephemeral keychain, import the Developer ID Application signing
# cert, and make it usable for non-interactive codesigning in CI.
set -euo pipefail

KEYCHAIN=build.keychain

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"       # no auto-lock mid-build
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')

echo "$MACOS_CERT_P12_BASE64" | base64 --decode > /tmp/cert.p12
# -f pkcs12 makes the format explicit; with set -e a bad password now fails the
# job here (the real error) instead of silently leaving an empty keychain.
security import /tmp/cert.p12 -f pkcs12 -k "$KEYCHAIN" -P "$MACOS_CERT_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/productsign
rm -f /tmp/cert.p12

# The step everyone forgets — without this, codesign blocks on a GUI prompt forever:
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN"

# Diagnostics. `-v` lists only identities valid for codesigning; the plain call
# lists ALL of them, including invalid ones with the reason. If the identity
# appears in the plain list but not the `-v` list, the cert chain is incomplete
# (missing Developer ID intermediate). If it appears in neither, the import
# itself didn't bring in a usable key+cert pair.
echo "── Valid codesigning identities ──"
security find-identity -v -p codesigning "$KEYCHAIN"
echo "── All identities (including invalid) ──"
security find-identity "$KEYCHAIN"
