#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

release_dir="${1:-dist/releases}"
exec Updates/Sparkle/generate_appcast.sh "$release_dir"
