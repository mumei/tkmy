#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
app_path="$project_root/.build/app/TKMY.app"
assets="$project_root/.build/release-assets"

if [[ -z "${DEVELOPER_ID_APPLICATION:-}" || -z "${NOTARY_KEY_BASE64:-}" || -z "${NOTARY_KEY_ID:-}" || -z "${NOTARY_ISSUER_ID:-}" ]]; then
  echo "Developer ID and notarization secrets are required." >&2
  exit 1
fi

notary_key="$RUNNER_TEMP/AuthKey_${NOTARY_KEY_ID}.p8"
archive_path="$RUNNER_TEMP/TKMY-notarization.zip"
result_path="$assets/app-notarization-result.json"
mkdir -p "$assets"
umask 077
print -rn -- "$NOTARY_KEY_BASE64" | base64 --decode > "$notary_key"

codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
ditto -c -k --keepParent "$app_path" "$archive_path"
set +e
xcrun notarytool submit "$archive_path" \
  --key "$notary_key" \
  --key-id "$NOTARY_KEY_ID" \
  --issuer "$NOTARY_ISSUER_ID" \
  --wait \
  --output-format json \
  > "$result_path"
submit_status=$?
set -e

submission_id="$(plutil -extract id raw -o - "$result_path" 2>/dev/null || true)"
notary_status="$(plutil -extract status raw -o - "$result_path" 2>/dev/null || true)"
if [[ "$submit_status" -ne 0 || "$notary_status" != "Accepted" ]]; then
  if [[ -n "$submission_id" ]]; then
    xcrun notarytool log "$submission_id" \
      --key "$notary_key" \
      --key-id "$NOTARY_KEY_ID" \
      --issuer "$NOTARY_ISSUER_ID" \
      "$assets/app-notarization-result-log.json" || true
  fi
  echo "App notarization failed with status: ${notary_status:-unknown}" >&2
  exit 1
fi

xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose=2 "$app_path"

echo "Notarized app: $app_path"
