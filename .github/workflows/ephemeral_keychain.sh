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
# A valid Developer ID identity .p12 is a few KB (cert + private key). A tiny
# decode means MACOS_CERT_P12_BASE64 is empty/truncated, or the .p12 is missing
# the certificate or key — either way `security import` silently imports nothing
# and the codesign step fails later with a confusing "0 valid identities".
DECODED_BYTES=$(wc -c < /tmp/cert.p12 | tr -d ' ')
if [ "$DECODED_BYTES" -lt 2000 ]; then
  echo "::error::Decoded .p12 is only ${DECODED_BYTES} bytes — expected a full cert+key identity (~2.5-4 KB). Check MACOS_CERT_P12_BASE64."
  exit 1
fi

security import /tmp/cert.p12 -f pkcs12 -k "$KEYCHAIN" -P "$MACOS_CERT_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/productsign
rm -f /tmp/cert.p12

# The step everyone forgets — without this, codesign blocks on a GUI prompt forever:
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
