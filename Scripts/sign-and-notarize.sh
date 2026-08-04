#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
app_path="$project_root/.build/app/TKMY.app"

if [[ -z "${DEVELOPER_ID_APPLICATION:-}" || -z "${NOTARY_KEY_BASE64:-}" || -z "${NOTARY_KEY_ID:-}" || -z "${NOTARY_ISSUER_ID:-}" ]]; then
  echo "Developer ID and notarization secrets are required." >&2
  exit 1
fi

notary_key="$RUNNER_TEMP/AuthKey_${NOTARY_KEY_ID}.p8"
archive_path="$RUNNER_TEMP/TKMY-notarization.zip"
print -rn -- "$NOTARY_KEY_BASE64" | base64 --decode > "$notary_key"

codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
ditto -c -k --keepParent "$app_path" "$archive_path"
xcrun notarytool submit "$archive_path" --key "$notary_key" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose=2 "$app_path"
