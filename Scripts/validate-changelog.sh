#!/bin/zsh
set -euo pipefail

change_log_path="${1:-}"
release_version="${2:-}"

if [[ -z "$change_log_path" || -z "$release_version" ]]; then
  echo "Usage: Scripts/validate-changelog.sh FILE VERSION" >&2
  exit 1
fi

if [[ ! -s "$change_log_path" ]]; then
  echo "ChangeLog not found or empty: $change_log_path" >&2
  exit 1
fi

expected_title="# TKMY ${release_version}"
actual_title="$(/usr/bin/head -n 1 "$change_log_path")"
if [[ "$actual_title" != "$expected_title" ]]; then
  echo "ChangeLog must start with: $expected_title" >&2
  exit 1
fi

language_headings=(
  "## English"
  "## 日本語"
  "## Deutsch"
  "## 简体中文"
  "## Français"
  "## 한국어"
  "## Español"
  "## Italiano"
  "## Tiếng Việt"
  "## ไทย"
  "## 繁體中文"
)

previous_line=0
for heading in "${language_headings[@]}"; do
  matches="$(/usr/bin/grep -n -F -x "$heading" "$change_log_path" || true)"
  if [[ -z "$matches" ]]; then
    echo "Missing ChangeLog heading: $heading" >&2
    exit 1
  fi
  if [[ "$matches" == *$'\n'* ]]; then
    echo "Duplicate ChangeLog heading: $heading" >&2
    exit 1
  fi
  line="${matches%%:*}"
  if (( line <= previous_line )); then
    echo "ChangeLog languages are not in the required order." >&2
    exit 1
  fi
  previous_line="$line"
done

echo "Validated ChangeLog: $change_log_path"
