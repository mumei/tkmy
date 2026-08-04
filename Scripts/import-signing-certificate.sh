#!/bin/zsh
set -euo pipefail

if [[ -z "${CERTIFICATE_P12_BASE64:-}" || -z "${CERTIFICATE_PASSWORD:-}" ]]; then
  echo "Signing certificate secrets are required." >&2
  exit 1
fi

keychain_path="$RUNNER_TEMP/tkmy-signing.keychain-db"
certificate_path="$RUNNER_TEMP/tkmy-certificate.p12"
keychain_password="$(openssl rand -hex 24)"

print -rn -- "$CERTIFICATE_P12_BASE64" | base64 --decode > "$certificate_path"
security create-keychain -p "$keychain_password" "$keychain_path"
security set-keychain-settings -lut 21600 "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security import "$certificate_path" -P "$CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$keychain_path"
security list-keychains -d user -s "$keychain_path"
security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain_path"
