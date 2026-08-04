#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
app_path="$project_root/.build/app/TKMY.app"
assets="$project_root/.build/release-assets"
version="${GITHUB_REF_NAME#v}"
archive="$assets/TKMY-$version.zip"

if [[ -z "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  echo "Sparkle private key is required." >&2
  exit 1
fi

mkdir -p "$assets"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive"
print -rn -- "$SPARKLE_PRIVATE_KEY" | "$project_root/.build/artifacts/sparkle/Sparkle/bin/sign_update" "$archive"
