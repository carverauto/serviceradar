#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="packaging/kong/vendor"
mkdir -p "$OUT_DIR"

echo "[INFO] Downloading Kong Enterprise 3.11.0.3 artifacts to $OUT_DIR"

download() {
  local url="$1"; local out="$2";
  if [[ -f "$out" ]]; then
    echo "[SKIP] $out exists"
    return 0
  fi
  echo "[GET ] $url"
  curl -fL --retry 3 --retry-delay 2 -o "$out" "$url"
}

# RPMs (EL9)
download "https://packages.konghq.com/public/gateway-311/rpm/el/9/x86_64/kong-enterprise-edition-3.11.0.3.el9.x86_64.rpm" \
         "$OUT_DIR/kong-enterprise-edition-3.11.0.3.el9.x86_64.rpm"
download "https://packages.konghq.com/public/gateway-311/rpm/el/9/aarch64/kong-enterprise-edition-3.11.0.3.el9.aarch64.rpm" \
         "$OUT_DIR/kong-enterprise-edition-3.11.0.3.el9.aarch64.rpm"

# DEBs (Debian bookworm)
download "https://packages.konghq.com/public/gateway-311/deb/debian/pool/bookworm/main/k/ko/kong-enterprise-edition_3.11.0.3/kong-enterprise-edition_3.11.0.3_amd64.deb" \
         "$OUT_DIR/kong-enterprise-edition_3.11.0.3_amd64.deb"
download "https://packages.konghq.com/public/gateway-311/deb/debian/pool/bookworm/main/k/ko/kong-enterprise-edition_3.11.0.3/kong-enterprise-edition_3.11.0.3_arm64.deb" \
         "$OUT_DIR/kong-enterprise-edition_3.11.0.3_arm64.deb"

echo "[DONE] Kong artifacts ready in $OUT_DIR"

