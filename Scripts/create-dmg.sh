#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
app_path="${1:-}"
dmg_path="${2:-}"
volume_name="${3:-TKMY}"
signing_identity="${TKMY_CODE_SIGN_IDENTITY:-${DEVELOPER_ID_APPLICATION:-}}"

if [[ -z "$app_path" || -z "$dmg_path" ]]; then
  echo "Usage: Scripts/create-dmg.sh APP_PATH DMG_PATH [VOLUME_NAME]" >&2
  exit 1
fi
if [[ ! -d "$app_path" ]]; then
  echo "App not found: $app_path" >&2
  exit 1
fi

if [[ -z "$signing_identity" ]]; then
  signing_identity="$(
    /usr/bin/security find-identity -v -p codesigning \
      | /usr/bin/awk '/"Developer ID Application:/ { print $2; exit }'
  )"
fi
if [[ -z "$signing_identity" ]]; then
  echo "Developer ID Application identity not found." >&2
  exit 1
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"

staging_dir="$(/usr/bin/mktemp -d /private/tmp/tkmy-dmg.XXXXXX)"
working_dir="$(/usr/bin/mktemp -d /private/tmp/tkmy-dmg-work.XXXXXX)"
mount_dir="$working_dir/mount"
read_write_dmg="$working_dir/TKMY-rw.dmg"
mounted=false

cleanup() {
  if [[ "$mounted" == true ]]; then
    /usr/bin/hdiutil detach "$mount_dir" -quiet || true
  fi
  /bin/rm -rf "$staging_dir" "$working_dir"
}
trap cleanup EXIT

/usr/bin/ditto "$app_path" "$staging_dir/TKMY.app"
/bin/ln -s /Applications "$staging_dir/Applications"
/bin/mkdir -p "$staging_dir/.background"
/usr/bin/xcrun swift \
  "$project_root/Scripts/create-dmg-background.swift" \
  "$staging_dir/.background/background.png"

/bin/mkdir -p "${dmg_path:h}"
/bin/rm -f "$dmg_path"

/usr/bin/hdiutil create \
  -volname "$volume_name" \
  -srcfolder "$staging_dir" \
  -format UDRW \
  -ov \
  "$read_write_dmg"

/bin/mkdir -p "$mount_dir"
/usr/bin/hdiutil attach \
  -readwrite \
  -noverify \
  -noautoopen \
  -mountpoint "$mount_dir" \
  "$read_write_dmg"
mounted=true

/usr/bin/osascript - "$mount_dir" <<'APPLESCRIPT'
on run argv
  set mountPath to item 1 of argv
  set targetFolder to POSIX file mountPath as alias

  tell application "Finder"
    open targetFolder
    set targetWindow to container window of targetFolder
    set current view of targetWindow to icon view
    set toolbar visible of targetWindow to false
    set statusbar visible of targetWindow to false
    set bounds of targetWindow to {100, 100, 820, 560}

    set viewOptions to icon view options of targetWindow
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.png" of targetFolder

    set position of item "TKMY.app" of targetFolder to {180, 250}
    set position of item "Applications" of targetFolder to {540, 250}

    update targetFolder without registering applications
    delay 2
    close targetWindow
  end tell
end run
APPLESCRIPT

/bin/sync
/usr/bin/hdiutil detach "$mount_dir"
mounted=false

/usr/bin/hdiutil convert \
  "$read_write_dmg" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  -o "$dmg_path"

sign_args=(--force --sign "$signing_identity")
if [[ "$signing_identity" != "-" ]]; then
  sign_args+=(--timestamp)
fi
/usr/bin/codesign "${sign_args[@]}" "$dmg_path"
/usr/bin/codesign --verify --verbose=2 "$dmg_path"
/usr/bin/hdiutil verify "$dmg_path"

echo "Signed disk image: $dmg_path"
