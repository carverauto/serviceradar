#!/usr/bin/env bash
set -euo pipefail

OUT_DIR=${KONG_VENDOR_DIR:-packaging/kong/vendor}
FETCH_ENTERPRISE=${KONG_FETCH_ENTERPRISE:-1}
ENTERPRISE_VERSION=${KONG_ENTERPRISE_VERSION:-3.11.0.3}
ENTERPRISE_CHANNEL=${ENTERPRISE_VERSION//./}
FETCH_COMMUNITY=${KONG_FETCH_COMMUNITY:-0}
COMMUNITY_VERSION=${KONG_COMMUNITY_VERSION:-3.7.1}
COMMUNITY_CHANNEL=${COMMUNITY_VERSION//./}

mkdir -p "$OUT_DIR"

download() {
  local label="$1"
  local url="$2"
  local dest="$3"

  if [[ -f "$dest" ]]; then
    echo "[SKIP] $label already present at $dest"
    return
  fi

  echo "[GET ] $label -> $dest"
  curl -fL --retry 3 --retry-delay 2 -o "$dest" "$url"
}

if [[ "$FETCH_ENTERPRISE" != "0" ]]; then
  echo "[INFO] Fetching Kong enterprise artifacts (version ${ENTERPRISE_VERSION}) into $OUT_DIR"
  download "Kong enterprise RPM (el9 x86_64)" \
    "https://packages.konghq.com/public/gateway-${ENTERPRISE_CHANNEL}/rpm/el/9/x86_64/kong-enterprise-edition-${ENTERPRISE_VERSION}.el9.x86_64.rpm" \
    "$OUT_DIR/kong-enterprise-edition-${ENTERPRISE_VERSION}.el9.x86_64.rpm"
  download "Kong enterprise RPM (el9 aarch64)" \
    "https://packages.konghq.com/public/gateway-${ENTERPRISE_CHANNEL}/rpm/el/9/aarch64/kong-enterprise-edition-${ENTERPRISE_VERSION}.el9.aarch64.rpm" \
    "$OUT_DIR/kong-enterprise-edition-${ENTERPRISE_VERSION}.el9.aarch64.rpm"
  download "Kong enterprise DEB (amd64)" \
    "https://packages.konghq.com/public/gateway-${ENTERPRISE_CHANNEL}/deb/debian/pool/bookworm/main/k/ko/kong-enterprise-edition_${ENTERPRISE_VERSION}/kong-enterprise-edition_${ENTERPRISE_VERSION}_amd64.deb" \
    "$OUT_DIR/kong-enterprise-edition_${ENTERPRISE_VERSION}_amd64.deb"
  download "Kong enterprise DEB (arm64)" \
    "https://packages.konghq.com/public/gateway-${ENTERPRISE_CHANNEL}/deb/debian/pool/bookworm/main/k/ko/kong-enterprise-edition_${ENTERPRISE_VERSION}/kong-enterprise-edition_${ENTERPRISE_VERSION}_arm64.deb" \
    "$OUT_DIR/kong-enterprise-edition_${ENTERPRISE_VERSION}_arm64.deb"
else
  echo "[INFO] Skipping enterprise artifact downloads (set KONG_FETCH_ENTERPRISE=1 to enable)"
fi

if [[ "$FETCH_COMMUNITY" != "0" ]]; then
  echo "[INFO] Fetching Kong community artifacts (version ${COMMUNITY_VERSION}) into $OUT_DIR"
  download "Kong community RPM (el9 x86_64)" \
    "https://packages.konghq.com/public/gateway-${COMMUNITY_CHANNEL}/rpm/el/9/x86_64/kong-${COMMUNITY_VERSION}.el9.x86_64.rpm" \
    "$OUT_DIR/kong-${COMMUNITY_VERSION}.el9.x86_64.rpm"
  download "Kong community RPM (el9 aarch64)" \
    "https://packages.konghq.com/public/gateway-${COMMUNITY_CHANNEL}/rpm/el/9/aarch64/kong-${COMMUNITY_VERSION}.el9.aarch64.rpm" \
    "$OUT_DIR/kong-${COMMUNITY_VERSION}.el9.aarch64.rpm"
  download "Kong community DEB (amd64)" \
    "https://packages.konghq.com/public/gateway-${COMMUNITY_CHANNEL}/deb/debian/pool/bookworm/main/k/kong/kong_${COMMUNITY_VERSION}_amd64.deb" \
    "$OUT_DIR/kong_${COMMUNITY_VERSION}_amd64.deb"
  download "Kong community DEB (arm64)" \
    "https://packages.konghq.com/public/gateway-${COMMUNITY_CHANNEL}/deb/debian/pool/bookworm/main/k/kong/kong_${COMMUNITY_VERSION}_arm64.deb" \
    "$OUT_DIR/kong_${COMMUNITY_VERSION}_arm64.deb"
fi

echo "[DONE] Kong artifacts available in $OUT_DIR"
