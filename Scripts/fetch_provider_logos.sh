#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES_JSON="$ROOT_DIR/App/Resources/ProviderLogoSources.json"
ASSET_DIR="$ROOT_DIR/App/Resources/Assets.xcassets"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: missing required command: $1" >&2
    exit 1
  fi
}

require curl
require python3

mkdir -p "$ASSET_DIR"
if [[ ! -f "$ASSET_DIR/Contents.json" ]]; then
  cat > "$ASSET_DIR/Contents.json" <<'JSON'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
fi

python3 - <<'PY' "$SOURCES_JSON" | while IFS=$'\t' read -r asset_name url provider_id slug; do
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)
for item in payload["sources"]:
    print("\t".join([item["assetName"], item["url"], item["providerID"], item["slug"]]))
PY
  imageset="$ASSET_DIR/${asset_name}.imageset"
  svg_path="$imageset/${asset_name}.svg"
  mkdir -p "$imageset"
  echo "Downloading $provider_id logo ($slug)"
  curl --fail --location --retry 3 --retry-delay 1 --connect-timeout 10 --output "$svg_path" "$url"
  if ! grep -q '<svg' "$svg_path"; then
    echo "error: downloaded file is not SVG: $svg_path" >&2
    exit 1
  fi
  cat > "$imageset/Contents.json" <<JSON
{
  "images" : [
    {
      "filename" : "${asset_name}.svg",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "preserves-vector-representation" : true
  }
}
JSON
done

echo "Provider logos are ready in $ASSET_DIR"
