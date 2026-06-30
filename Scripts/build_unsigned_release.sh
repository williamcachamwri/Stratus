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
swift build -c release --product "${product_name}FileProviderExtension"

executable_path="$(swift build -c release --show-bin-path)/$product_name"
install -m 755 "$executable_path" "$macos_dir/$product_name"

cp Resources/Info.plist "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$contents_dir/Info.plist"

# Package FileProvider extension .appex
extension_product="${product_name}FileProviderExtension"
extension_binary="$(swift build -c release --show-bin-path)/$extension_product"
plug_ins_dir="$contents_dir/PlugIns"
appex_dir="$plug_ins_dir/${extension_product}.appex"
mkdir -p "$appex_dir/Contents/MacOS"
install -m 755 "$extension_binary" "$appex_dir/Contents/MacOS/$extension_product"
cp "$repo_root/FileProviderExtension/Info.plist" "$appex_dir/Contents/"
echo -n "XPC!????" > "$appex_dir/Contents/PkgInfo"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$appex_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$appex_dir/Contents/Info.plist"

# Copy SPM resource bundle
build_products="$(swift build -c release --show-bin-path)"
if [ -d "$build_products/$product_name""_$product_name.bundle" ]; then
  cp -R "$build_products/$product_name""_$product_name.bundle" "$resources_dir/"
fi

# Copy SPM resource files
# Copy shared/ config directory (for SharedConfig lookup)
if [ -d "$repo_root/shared" ]; then
  cp -R "$repo_root/shared" "$resources_dir/"
fi

find Resources -mindepth 1 -maxdepth 1 \
  ! -name Info.plist \
  ! -name Stratus.entitlements \
  ! -name FileProviderExtension.entitlements \
  -exec cp -R {} "$resources_dir/" \;

# Bundle Sparkle framework
frameworks_dir="$contents_dir/Frameworks"
sparkle_source="$(find "$build_products" -path "*/Sparkle.framework" -type d 2>/dev/null | head -1)"
if [ -z "$sparkle_source" ]; then
  sparkle_source="$(find "$repo_root/.build" -path "*/macos-arm64_x86_64/Sparkle.framework" -type d 2>/dev/null | head -1)"
fi
if [ -n "$sparkle_source" ]; then
  mkdir -p "$frameworks_dir"
  cp -R "$sparkle_source" "$frameworks_dir/"
  xattr -rc "$frameworks_dir/Sparkle.framework"
  install_name_tool -add_rpath @executable_path/../Frameworks "$macos_dir/$product_name" 2>/dev/null || true
fi

if command -v codesign >/dev/null 2>&1; then
  if [ -d "$frameworks_dir/Sparkle.framework" ]; then
    codesign --force --sign - "$frameworks_dir/Sparkle.framework" 2>/dev/null || true
  fi
  if [ -d "$appex_dir" ]; then
    codesign --force --sign - "$appex_dir" 2>/dev/null || true
  fi
  codesign --force --sign - \
    --entitlements Resources/Stratus.entitlements \
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
