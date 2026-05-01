#!/usr/bin/env bash
set -euo pipefail

EXAMPLE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$EXAMPLE_DIR/../../../.." && pwd)
OUT_DIR="$EXAMPLE_DIR/dist"
TINYGO_BIN="${TINYGO_BIN:-tinygo}"

if ! command -v "$TINYGO_BIN" >/dev/null 2>&1; then
  TINYGO_ROOT="${TMPDIR:-/tmp}/serviceradar-tinygo-0.40.1"
  TINYGO_TARBALL="$REPO_ROOT/go/tools/wasm-plugin-harness/tinygo0.40.1.linux-amd64.tar.gz"

  if [ ! -x "$TINYGO_ROOT/bin/tinygo" ]; then
    mkdir -p "$TINYGO_ROOT"
    tar -xzf "$TINYGO_TARBALL" -C "$TINYGO_ROOT" --strip-components=1
  fi

  TINYGO_BIN="$TINYGO_ROOT/bin/tinygo"
fi

mkdir -p "$OUT_DIR"

"$TINYGO_BIN" build -tags=tinygo -target=wasi -o "$OUT_DIR/dashboard.wasm" "$EXAMPLE_DIR"

if command -v sha256sum >/dev/null 2>&1; then
  DIGEST=$(sha256sum "$OUT_DIR/dashboard.wasm" | awk '{print $1}')
else
  DIGEST=$(shasum -a 256 "$OUT_DIR/dashboard.wasm" | awk '{print $1}')
fi

cat > "$OUT_DIR/manifest.json" <<JSON
{
  "schema_version": 1,
  "id": "com.serviceradar.examples.network-map",
  "name": "Example Network Map",
  "version": "0.1.0",
  "description": "Minimal dashboard-wasm-v1 map renderer for local development.",
  "vendor": "ServiceRadar",
  "renderer": {
    "kind": "browser_wasm",
    "interface_version": "dashboard-wasm-v1",
    "artifact": "dashboard.wasm",
    "sha256": "$DIGEST",
    "entrypoint": "sr_dashboard_init_json",
    "exports": ["memory", "alloc_bytes", "sr_dashboard_init_json"]
  },
  "data_frames": [
    {
      "id": "sites",
      "query": "in:wifi_sites limit:500",
      "encoding": "json_rows",
      "limit": 500,
      "fields": ["site_code", "name", "region", "longitude", "latitude", "ap_count"],
      "coordinates": {
        "longitude": "longitude",
        "latitude": "latitude"
      }
    }
  ],
  "capabilities": ["srql.execute", "map.deck.render", "popup.open"],
  "settings_schema": {
    "type": "object",
    "properties": {},
    "additionalProperties": false
  }
}
JSON

cp "$EXAMPLE_DIR/sample-frames.json" "$OUT_DIR/sample-frames.json"
cp "$EXAMPLE_DIR/sample-settings.json" "$OUT_DIR/sample-settings.json"

echo "Wrote $OUT_DIR/dashboard.wasm"
echo "Wrote $OUT_DIR/manifest.json"
