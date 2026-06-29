#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ "$(uname -s)" != "Darwin" ]]; then
  cat >&2 <<'MSG'
Stratus .app packaging requires macOS because the app links Apple frameworks.
Run this script on macOS 15+ with Xcode 16.3+.
MSG
  exit 1
fi

version="${1:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
version="${version:-0.1.0}"
app_name="Stratus"
product_name="Stratus"
bundle_id="com.stratus.cloudmanager"
dist_dir="$repo_root/dist"
app_dir="$dist_dir/$app_name.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
release_dir="$dist_dir/releases"
dmg_path=""

rm -rf "$app_dir"
mkdir -p "$macos_dir" "$resources_dir" "$release_dir"

swift build -c release --product "$product_name"

executable_path="$(swift build -c release --show-bin-path)/$product_name"
install -m 755 "$executable_path" "$macos_dir/$product_name"

cp Resources/Info.plist "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$contents_dir/Info.plist"

find Resources -mindepth 1 -maxdepth 1 \
  ! -name Info.plist \
  ! -name Stratus.entitlements \
  ! -name FileProviderExtension.entitlements \
  -exec cp -R {} "$resources_dir/" \;

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - \
    --entitlements Resources/Stratus.entitlements \
    --options runtime \
    "$app_dir"
fi

zip_path="$dist_dir/$app_name-$version.zip"
rm -f "$zip_path"
(
  cd "$dist_dir"
  /usr/bin/ditto -c -k --keepParent "$app_name.app" "$zip_path"
)
cp "$zip_path" "$release_dir/"

if command -v hdiutil >/dev/null 2>&1; then
  dmg_path="$dist_dir/$app_name-$version.dmg"
  rm -f "$dmg_path"
  hdiutil create \
    -volname "$app_name" \
    -srcfolder "$app_dir" \
    -ov \
    -format UDZO \
    "$dmg_path"
  cp "$dmg_path" "$release_dir/"
fi

cat <<MSG
Built unsigned Stratus release artifacts:
- $app_dir
- $zip_path
- ${dmg_path:-DMG skipped}
MSG
