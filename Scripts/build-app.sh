#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
build_root="$project_root/.build"
app_root="$build_root/app/TKMY.app"
contents="$app_root/Contents"

cd "$project_root"
swift build -c release --disable-sandbox --scratch-path "$build_root" -Xcc -fmodules-cache-path="$build_root/ModuleCache"

rm -rf "$app_root"
mkdir -p "$contents/MacOS" "$contents/Resources" "$contents/Frameworks"
cp "$build_root/release/TKMY" "$contents/MacOS/TKMY"
cp "$project_root/Resources/Info.plist" "$contents/Info.plist"
cp "$project_root/Resources/AppIcon.icns" "$contents/Resources/AppIcon.icns"
cp "$project_root/Resources/Sparkle-LICENSE.txt" "$contents/Resources/Sparkle-LICENSE.txt"
cp -R "$build_root/release/TKMY_UsagePricing.bundle" "$contents/Resources/"

if [[ -n "${TKMY_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $TKMY_VERSION" "$contents/Info.plist"
fi
if [[ -n "${TKMY_BUILD_NUMBER:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $TKMY_BUILD_NUMBER" "$contents/Info.plist"
fi

if [[ -n "${TKMY_FEED_URL:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :SUFeedURL $TKMY_FEED_URL" "$contents/Info.plist"
fi
if [[ -n "${SPARKLE_PUBLIC_KEY:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_PUBLIC_KEY" "$contents/Info.plist"
fi

sparkle_framework="$build_root/release/Sparkle.framework"
if [[ -d "$sparkle_framework" ]]; then
  cp -R "$sparkle_framework" "$contents/Frameworks/"
fi

# Keep local and CI bundles internally consistent after resources and embedded
# frameworks are copied. Official releases replace this ad-hoc signature with
# a Developer ID signature before notarization.
codesign --force --deep --sign - "$app_root"
codesign --verify --deep --strict "$app_root"

echo "$app_root"
