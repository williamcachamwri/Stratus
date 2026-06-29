#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

missing=0

if command -v swiftformat >/dev/null 2>&1; then
  swiftformat --lint App Core Tests Package.swift
else
  echo "SwiftFormat is not installed. Install with: brew install swiftformat" >&2
  missing=1
fi

if command -v swiftlint >/dev/null 2>&1; then
  swiftlint lint --strict
else
  echo "SwiftLint is not installed. Install with: brew install swiftlint" >&2
  missing=1
fi

if [[ "$missing" -ne 0 ]]; then
  exit 1
fi
