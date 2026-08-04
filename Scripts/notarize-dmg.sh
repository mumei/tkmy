#!/bin/zsh
set -euo pipefail

dmg_path="${1:-}"
result_path="${2:-}"

if [[ -z "$dmg_path" || -z "$result_path" ]]; then
  echo "Usage: Scripts/notarize-dmg.sh DMG_PATH RESULT_PATH" >&2
  exit 1
fi
if [[ ! -f "$dmg_path" ]]; then
  echo "Disk image not found: $dmg_path" >&2
  exit 1
fi
if [[ -z "${NOTARY_KEY_ID:-}" || -z "${NOTARY_ISSUER_ID:-}" ]]; then
  echo "Notarization key ID and issuer ID are required." >&2
  exit 1
fi

notary_key="${APPLE_API_PRIVATE_KEY_PATH:-$RUNNER_TEMP/AuthKey_${NOTARY_KEY_ID}.p8}"
if [[ ! -f "$notary_key" ]]; then
  if [[ -z "${NOTARY_KEY_BASE64:-}" ]]; then
    echo "Notarization private key is required." >&2
    exit 1
  fi
  umask 077
  print -rn -- "$NOTARY_KEY_BASE64" | /usr/bin/base64 --decode > "$notary_key"
fi

set +e
/usr/bin/xcrun notarytool submit "$dmg_path" \
  --key "$notary_key" \
  --key-id "$NOTARY_KEY_ID" \
  --issuer "$NOTARY_ISSUER_ID" \
  --wait \
  --output-format json \
  > "$result_path"
submit_status=$?
set -e

submission_id="$(/usr/bin/plutil -extract id raw -o - "$result_path" 2>/dev/null || true)"
notary_status="$(/usr/bin/plutil -extract status raw -o - "$result_path" 2>/dev/null || true)"

if [[ "$submit_status" -ne 0 || "$notary_status" != "Accepted" ]]; then
  if [[ -n "$submission_id" ]]; then
    /usr/bin/xcrun notarytool log "$submission_id" \
      --key "$notary_key" \
      --key-id "$NOTARY_KEY_ID" \
      --issuer "$NOTARY_ISSUER_ID" \
      "${result_path:r}-log.json" || true
  fi
  echo "Disk image notarization failed with status: ${notary_status:-unknown}" >&2
  exit 1
fi

/usr/bin/xcrun stapler staple "$dmg_path"
/usr/bin/xcrun stapler validate "$dmg_path"
/usr/bin/codesign --verify --verbose=2 "$dmg_path"
/usr/bin/hdiutil verify "$dmg_path"
/usr/sbin/spctl \
  --assess \
  --type open \
  --context context:primary-signature \
  --verbose=4 \
  "$dmg_path"
/usr/bin/shasum -a 256 "$dmg_path" > "$dmg_path.sha256"

echo "Notarized disk image: $dmg_path"
