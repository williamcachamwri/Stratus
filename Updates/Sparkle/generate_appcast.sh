#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

release_dir="${1:-dist/releases}"
mkdir -p "$release_dir"

find_generate_appcast() {
  if [[ -n "${SPARKLE_GENERATE_APPCAST:-}" ]]; then
    printf '%s\n' "$SPARKLE_GENERATE_APPCAST"
    return 0
  fi

  local candidate
  while IFS= read -r candidate; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(find .build -path '*/Sparkle/bin/generate_appcast' -type f 2>/dev/null)

  return 1
}

generate_appcast="$(find_generate_appcast || true)"
if [[ -z "$generate_appcast" ]]; then
  cat >&2 <<'MSG'
Sparkle generate_appcast was not found.
Set SPARKLE_GENERATE_APPCAST=/path/to/generate_appcast or add Sparkle through Swift Package Manager so the tool exists under .build artifacts.
MSG
  exit 1
fi

"$generate_appcast" "$release_dir"

if [[ -f "$release_dir/appcast.xml" ]]; then
  cp "$release_dir/appcast.xml" Updates/Sparkle/appcast.xml
fi
