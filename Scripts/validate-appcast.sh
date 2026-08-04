#!/bin/zsh
set -euo pipefail

appcast_path="${1:-}"
release_version="${2:-}"
release_repository="${3:-mumei/tkmy}"

if [[ -z "$appcast_path" || -z "$release_version" ]]; then
  echo "Usage: Scripts/validate-appcast.sh FILE VERSION [OWNER/REPOSITORY]" >&2
  exit 1
fi
if [[ ! -s "$appcast_path" ]]; then
  echo "Appcast not found or empty: $appcast_path" >&2
  exit 1
fi

archive_url="https://github.com/$release_repository/releases/download/v$release_version/TKMY-$release_version.zip"
required_values=(
  "sparkle:edSignature="
  "<sparkle:shortVersionString>$release_version</sparkle:shortVersionString>"
  "$archive_url"
)

for value in "${required_values[@]}"; do
  if ! /usr/bin/grep -Fq "$value" "$appcast_path"; then
    echo "Appcast is missing required value: $value" >&2
    exit 1
  fi
done

if /usr/bin/grep -Fq "example.invalid" "$appcast_path"; then
  echo "Appcast contains a placeholder URL." >&2
  exit 1
fi

echo "Validated appcast: $appcast_path"
