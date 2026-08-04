#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
app_path="$project_root/.build/app/TKMY.app"
assets="$project_root/.build/release-assets"
revision="${GITHUB_SHA:-local}"
short_revision="${revision[1,7]}"
archive="$assets/TKMY-$short_revision-adhoc.zip"
checksum="$archive.sha256"

if [[ ! -x "$app_path/Contents/MacOS/TKMY" ]]; then
  echo "TKMY.app is missing. Run Scripts/build-app.sh first." >&2
  exit 1
fi

rm -rf "$assets"
mkdir -p "$assets"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive"

cd "$assets"
shasum -a 256 "${archive:t}" > "${checksum:t}"
shasum -a 256 -c "${checksum:t}"

echo "$archive"
echo "$checksum"
