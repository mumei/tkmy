#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
app_path="$project_root/.build/app/TKMY.app"
assets="$project_root/.build/release-assets"
version="${RELEASE_VERSION:-${GITHUB_REF_NAME#v}}"
archive="$assets/TKMY-$version.zip"

mkdir -p "$assets"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive"
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  print -rn -- "$SPARKLE_PRIVATE_KEY" | "$project_root/.build/artifacts/sparkle/Sparkle/bin/sign_update" "$archive"
else
  echo "SPARKLE_PRIVATE_KEY is not configured; the ZIP will be published without a Sparkle EdDSA signature."
fi
/usr/bin/shasum -a 256 "$archive" > "$archive.sha256"
