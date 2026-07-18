#!/bin/bash

KEYCHAIN=build.keychain

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"       # no auto-lock mid-build
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')

echo "$MACOS_CERT_P12_BASE64" | base64 --decode > /tmp/cert.p12
security import /tmp/cert.p12 -k "$KEYCHAIN" -P "$MACOS_CERT_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/productsign
rm -f /tmp/cert.p12

# The step everyone forgets — without this, codesign blocks on a GUI prompt forever:
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN"