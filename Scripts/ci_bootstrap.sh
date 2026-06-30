#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ "$(uname -s)" != "Darwin" ]]; then
  cat >&2 <<'MSG'
Stratus targets macOS frameworks such as SwiftUI, AppKit, Security, LocalAuthentication, Network, and FileProvider.
Use macOS 15+ with Xcode 16.3+ for build, test, lint, and release jobs.
MSG
  exit 1
fi

require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "Missing required command: $name" >&2
    exit 1
  fi
}

require_command swift
require_command xcodebuild
require_command xcrun
require_command plutil

printf 'Swift: '
swift --version | head -n 1
printf 'Xcode: '
xcodebuild -version | tr '\n' ' '
printf '\nSDK: '
xcrun --sdk macosx --show-sdk-version

swift_version="$(swift --version | head -n 1)"
if [[ "$swift_version" != *"Swift version 6"* ]]; then
  echo "Swift 6 is required. Current: $swift_version" >&2
  exit 1
fi

xcode_version="$(xcodebuild -version | awk '/Xcode/{print $2}')"
major="${xcode_version%%.*}"
minor="${xcode_version#*.}"
minor="${minor%%.*}"
if ! [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]]; then
  echo "Could not parse Xcode version: $xcode_version" >&2
  exit 1
fi
if (( major < 16 || (major == 16 && minor < 3) )); then
  echo "Xcode 16.3 or newer is required. Current: $xcode_version" >&2
  exit 1
fi

plutil -lint App/Resources/Info.plist >/dev/null
plutil -lint App/Resources/Stratus.entitlements >/dev/null
plutil -lint App/Resources/FileProviderExtension.entitlements >/dev/null

echo "Bootstrap checks passed."
