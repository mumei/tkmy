#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
app_path="$project_root/.build/app/TKMY.app"
assets="$project_root/.build/release-assets"
version="${RELEASE_VERSION:-${GITHUB_REF_NAME:-}}"
version="${version#v}"
archive="$assets/TKMY-$version.zip"
appcast_workspace="$project_root/.build/appcast-input"
release_repository="${GITHUB_REPOSITORY:-mumei/tkmy}"
release_notes="$project_root/changeLog/$version.md"
generate_appcast="$project_root/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"

if [[ -z "$version" ]]; then
  echo "RELEASE_VERSION or GITHUB_REF_NAME is required." >&2
  exit 1
fi
if [[ -z "${SPARKLE_PRIVATE_KEY:-}" && -z "${SPARKLE_ACCOUNT:-}" ]]; then
  echo "SPARKLE_PRIVATE_KEY is required (or SPARKLE_ACCOUNT for local Keychain signing)." >&2
  exit 1
fi
if [[ ! -x "$generate_appcast" ]]; then
  echo "Sparkle generate_appcast was not found: $generate_appcast" >&2
  exit 1
fi
if [[ ! -s "$release_notes" ]]; then
  echo "Release notes were not found: $release_notes" >&2
  exit 1
fi

mkdir -p "$assets"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive"

rm -rf "$appcast_workspace"
mkdir -p "$appcast_workspace"
cp "$archive" "$appcast_workspace/"
cp "$release_notes" "$appcast_workspace/TKMY-$version.md"

appcast_arguments=(
  --download-url-prefix "https://github.com/$release_repository/releases/download/v$version/"
  --link "https://github.com/$release_repository"
  --embed-release-notes
  --maximum-versions 1
  --maximum-deltas 0
  -o "$appcast_workspace/appcast.xml"
  "$appcast_workspace"
)

if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  print -rn -- "$SPARKLE_PRIVATE_KEY" | "$generate_appcast" --ed-key-file - "${appcast_arguments[@]}"
else
  "$generate_appcast" --account "$SPARKLE_ACCOUNT" "${appcast_arguments[@]}"
fi

cp "$appcast_workspace/appcast.xml" "$assets/appcast.xml"
/usr/bin/shasum -a 256 "$archive" > "$archive.sha256"
