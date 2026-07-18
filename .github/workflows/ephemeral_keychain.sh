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
# A valid Developer ID .p12 is a few KB. If the decode yields far less, the
# MACOS_CERT_P12_BASE64 secret is empty/truncated/wrong — fail loudly here
# rather than importing nothing and confusing the codesign step later.
DECODED_BYTES=$(wc -c < /tmp/cert.p12 | tr -d ' ')
echo "Decoded .p12 size: ${DECODED_BYTES} bytes"
if [ "$DECODED_BYTES" -lt 1000 ]; then
  echo "::error::Decoded .p12 is only ${DECODED_BYTES} bytes — MACOS_CERT_P12_BASE64 is empty, truncated, or not the base64 of your .p12."
  exit 1
fi
# Watch the output line: "1 identity imported" means cert + private key landed;
# "1 certificate imported" means the .p12 has NO private key (the failure mode
# that makes set-key-partition-list report SecItemCopyMatching not-found).
echo "── security import ──"
security import /tmp/cert.p12 -f pkcs12 -k "$KEYCHAIN" -P "$MACOS_CERT_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/productsign
rm -f /tmp/cert.p12

echo "── Certificates in the keychain ──"
# Unlike find-identity, this lists lone certs too. A cert here with no identity
# above means the key was dropped on import (modern PKCS#12 cipher Apple can't
# read); nothing here means the secret's content never produced a usable p12.
security find-certificate -a "$KEYCHAIN" | grep -E '"labl"|"alis"' || echo "(no certificates)"
echo "── All identities (cert+key pairs) in the keychain ──"
security find-identity "$KEYCHAIN"
echo "── Private keys in the keychain ──"
security find-key "$KEYCHAIN" 2>/dev/null || echo "(no keys / find-key unsupported)"

# The step everyone forgets — without this, codesign blocks on a GUI prompt
# forever. It fails with SecItemCopyMatching when no private key was imported;
# keep it non-fatal so the diagnostics above are visible in the log.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" || \
  echo "::warning::set-key-partition-list failed — no private key in the keychain?"

echo "── Valid codesigning identities ──"
security find-identity -v -p codesigning "$KEYCHAIN"
