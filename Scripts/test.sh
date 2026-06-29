#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ "$(uname -s)" != "Darwin" ]]; then
  cat >&2 <<'MSG'
Stratus tests require macOS because StratusCore imports Apple frameworks such as Security, LocalAuthentication, Network, and FileProvider.
Run this on macOS 15+ with Xcode 16.3+.
MSG
  exit 1
fi

swift test --parallel
