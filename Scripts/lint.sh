#!/usr/bin/env sh
set -eu

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH= cd -- "$script_dir/.." && pwd)"
cd "$repo_root"

require_tools="${STRATUS_REQUIRE_LINT_TOOLS:-0}"
missing=0

if command -v swiftformat >/dev/null 2>&1; then
  swiftformat --lint App Core Features DesignSystem Tests Package.swift
else
  echo "SwiftFormat is not installed. Install with: brew install swiftformat" >&2
  missing=1
fi

if command -v swiftlint >/dev/null 2>&1; then
  swiftlint lint
else
  echo "SwiftLint is not installed. Install with: brew install swiftlint" >&2
  missing=1
fi

if [ "$missing" -ne 0 ] && [ "$require_tools" = "1" ]; then
  exit 1
fi
