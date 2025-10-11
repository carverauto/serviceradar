#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
DIST_DIR="${REPO_ROOT}/dist/sysmonvm"
STAGING_DIR="${DIST_DIR}/package-macos"
OUTPUT_TAR="${DIST_DIR}/serviceradar-sysmonvm-host-macos.tar.gz"
OUTPUT_PKG="${DIST_DIR}/serviceradar-sysmonvm-host-macos.pkg"
SIGNED_PKG="${DIST_DIR}/serviceradar-sysmonvm-host-macos-signed.pkg"

SKIP_BUILD="${SKIP_BUILD:-0}"
SKIP_PKG="${SKIP_PKG:-0}"
PKG_IDENTIFIER="${PKG_IDENTIFIER:-com.serviceradar.sysmonvm.host}"
PKG_DISABLE_TIMESTAMP="${PKG_DISABLE_TIMESTAMP:-0}"
PKG_APP_SIGN_IDENTITY="${PKG_APP_SIGN_IDENTITY:-}"
PKG_TIMESTAMP_URL="${PKG_TIMESTAMP_URL:-http://timestamp.apple.com/ts01}"

default_pkg_version() {
  if command -v git >/dev/null 2>&1 && git -C "${REPO_ROOT}" describe --tags --abbrev=0 >/dev/null 2>&1; then
    local version
    version=$(git -C "${REPO_ROOT}" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')
    if [[ "${version}" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
      echo "${version}"
      return
    fi
  fi

  echo "0.0.0"
}

PKG_VERSION="${PKG_VERSION:-$(default_pkg_version)}"

if [[ ! "${PKG_VERSION}" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "[warn] PKG_VERSION '${PKG_VERSION}' is not in 'major.minor[.patch]' format; falling back to 0.0.0" >&2
  PKG_VERSION="0.0.0"
fi

if [[ "${SKIP_BUILD}" != "1" ]]; then
  make -C "${REPO_ROOT}" sysmonvm-host-build
  make -C "${REPO_ROOT}" sysmonvm-build-checker-darwin
fi

HOSTFREQ_BIN="${DIST_DIR}/mac-host/bin/hostfreq"
CHECKER_BIN="${DIST_DIR}/mac-host/bin/serviceradar-sysmon-vm"
CONFIG_JSON="${DIST_DIR}/sysmon-vm.json"
HOSTFREQ_PLIST="${REPO_ROOT}/cmd/checkers/sysmon-vm/hostmac/com.serviceradar.hostfreq.plist"
CHECKER_PLIST="${REPO_ROOT}/cmd/checkers/sysmon-vm/hostmac/com.serviceradar.sysmonvm.plist"
CONFIG_TEMPLATE="${REPO_ROOT}/cmd/checkers/sysmon-vm/sysmon-vm.json.example"

if [[ ! -f "${CONFIG_JSON}" ]]; then
  if [[ -f "${CONFIG_TEMPLATE}" ]]; then
    mkdir -p "$(dirname "${CONFIG_JSON}")"
    install -m 0644 "${CONFIG_TEMPLATE}" "${CONFIG_JSON}"
  else
    echo "[error] missing config template: ${CONFIG_TEMPLATE}" >&2
    exit 1
  fi
fi

for path in \
  "${HOSTFREQ_BIN}" \
  "${CHECKER_BIN}" \
  "${CONFIG_JSON}" \
  "${HOSTFREQ_PLIST}" \
  "${CHECKER_PLIST}"
do
  if [[ ! -f "${path}" ]]; then
    echo "[error] missing required artifact: ${path}" >&2
    exit 1
  fi
done

if [[ -n "${PKG_NOTARIZE_PROFILE:-}" ]] && [[ -z "${PKG_APP_SIGN_IDENTITY}" ]]; then
  echo "[error] PKG_APP_SIGN_IDENTITY must be set when notarization is requested (binaries require Developer ID Application signature)" >&2
  exit 1
fi

if [[ -n "${PKG_APP_SIGN_IDENTITY}" ]]; then
  if ! command -v codesign >/dev/null 2>&1; then
    echo "[error] codesign not found; cannot sign binaries. Install Xcode command line tools or unset PKG_APP_SIGN_IDENTITY." >&2
    exit 1
  fi

  echo "Signing host binaries with identity '${PKG_APP_SIGN_IDENTITY}'..."

  sign_with_timestamp() {
    local bin="$1"
    local attempt_url="${PKG_TIMESTAMP_URL:-}"
    local fallback_used=0

    while true; do
      local ts_flags=()
      if [[ "${PKG_DISABLE_TIMESTAMP}" == "1" ]]; then
        ts_flags=(--timestamp=none)
      else
        if [[ -n "${attempt_url}" ]]; then
          ts_flags=(--timestamp="${attempt_url}")
        else
          ts_flags=(--timestamp)
        fi
      fi

      local codesign_status=0
      if ! codesign --force "${ts_flags[@]}" --options runtime --sign "${PKG_APP_SIGN_IDENTITY}" "${bin}"; then
        codesign_status=$?
      fi

      if [[ "${PKG_DISABLE_TIMESTAMP}" == "1" ]]; then
        if [[ "${codesign_status}" -ne 0 ]]; then
          echo "[error] codesign failed for ${bin} (exit ${codesign_status}) with timestamping disabled" >&2
          exit 1
        fi
        break
      fi

      if [[ "${codesign_status}" -eq 0 ]]; then
        local describe_output
        describe_output=$(codesign -dvvv "${bin}" 2>&1 || true)
        if [[ "${describe_output}" == *"Timestamp="* ]]; then
          break
        fi
      fi

      if [[ "${fallback_used}" == "1" ]]; then
        cat >&2 <<'EOF'
[error] secure timestamp missing from code signature even after IPv4 retry.
Ensure Apple's timestamping root is trusted:
  curl -L -o /tmp/AppleTimestampCA.cer https://www.apple.com/certificateauthority/AppleTimestampCA.cer
  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /tmp/AppleTimestampCA.cer
Alternatively set PKG_TIMESTAMP_URL to an explicit reachable endpoint or PKG_DISABLE_TIMESTAMP=1 to skip timestamping.
EOF
        exit 1
      fi

      local resolve_url="${attempt_url}"
      if [[ -z "${resolve_url}" ]]; then
        resolve_url="http://timestamp.apple.com/ts01"
      fi

      if [[ -z "${PKG_TIMESTAMP_URL_IP_FALLBACK:-}" ]]; then
        if ! command -v python3 >/dev/null 2>&1; then
          cat >&2 <<'EOF'
[error] python3 not available; cannot compute IPv4 fallback for timestamp server.
Set PKG_TIMESTAMP_URL to an IPv4 URL (for example http://17.32.213.161/ts01) or disable timestamping with PKG_DISABLE_TIMESTAMP=1.
EOF
          exit 1
        fi
        PKG_TIMESTAMP_URL_IP_FALLBACK=$(python3 - "$resolve_url" <<'PY'
import socket, sys, urllib.parse

url = sys.argv[1]
parsed = urllib.parse.urlparse(url)
if not parsed.scheme or not parsed.hostname:
    sys.exit(1)
host = parsed.hostname
# crude check for raw IPv4 to avoid pointless fallback loops
if all(part.isdigit() for part in host.split(".") if part):
    sys.exit(1)
try:
    infos = socket.getaddrinfo(host, parsed.port, socket.AF_INET, socket.SOCK_STREAM)
except socket.gaierror:
    sys.exit(1)
if not infos:
    sys.exit(1)
addr = infos[0][4][0]
port = parsed.port
if port is None:
    port = 443 if parsed.scheme == "https" else 80
path = parsed.path or "/"
query = f"?{parsed.query}" if parsed.query else ""
fragment = f"#{parsed.fragment}" if parsed.fragment else ""
print(f"{parsed.scheme}://{addr}:{port}{path}{query}{fragment}")
PY
)
      fi

      if [[ -z "${PKG_TIMESTAMP_URL_IP_FALLBACK}" ]]; then
        cat >&2 <<'EOF'
[error] unable to resolve an IPv4 address for the timestamp server; cannot recover from missing timestamp.
Provide PKG_TIMESTAMP_URL manually (e.g. http://17.32.213.161/ts01) or run with PKG_DISABLE_TIMESTAMP=1.
EOF
        exit 1
      fi

      echo "[warn] codesign timestamp missing; retrying with IPv4 fallback ${PKG_TIMESTAMP_URL_IP_FALLBACK}" >&2
      attempt_url="${PKG_TIMESTAMP_URL_IP_FALLBACK}"
      fallback_used=1
    done
  }

  for bin in "${HOSTFREQ_BIN}" "${CHECKER_BIN}"; do
    sign_with_timestamp "${bin}"
  done
fi

rm -rf "${STAGING_DIR}"
mkdir -p \
  "${STAGING_DIR}/usr/local/libexec/serviceradar" \
  "${STAGING_DIR}/usr/local/etc/serviceradar" \
  "${STAGING_DIR}/Library/LaunchDaemons"

install -m 0755 "${HOSTFREQ_BIN}" "${STAGING_DIR}/usr/local/libexec/serviceradar/hostfreq"
install -m 0755 "${CHECKER_BIN}" "${STAGING_DIR}/usr/local/libexec/serviceradar/serviceradar-sysmon-vm"
install -m 0644 "${CONFIG_JSON}" "${STAGING_DIR}/usr/local/etc/serviceradar/sysmon-vm.json"
install -m 0644 "${HOSTFREQ_PLIST}" "${STAGING_DIR}/Library/LaunchDaemons/com.serviceradar.hostfreq.plist"
install -m 0644 "${CHECKER_PLIST}" "${STAGING_DIR}/Library/LaunchDaemons/com.serviceradar.sysmonvm.plist"

rm -f "${OUTPUT_TAR}"
tar -czf "${OUTPUT_TAR}" -C "${STAGING_DIR}" usr Library

echo "Wrote macOS host package to ${OUTPUT_TAR}"

if [[ "${SKIP_PKG}" == "1" ]]; then
  exit 0
fi

if ! command -v pkgbuild >/dev/null 2>&1; then
  echo "[error] pkgbuild not found; install Xcode command line tools or set SKIP_PKG=1" >&2
  exit 1
fi

rm -f "${OUTPUT_PKG}" "${SIGNED_PKG}"
pkgbuild \
  --root "${STAGING_DIR}" \
  --identifier "${PKG_IDENTIFIER}" \
  --version "${PKG_VERSION}" \
  --install-location / \
  "${OUTPUT_PKG}"

echo "Wrote unsigned installer package to ${OUTPUT_PKG}"

if [[ -n "${PKG_SIGN_IDENTITY:-}" ]]; then
  if ! command -v productsign >/dev/null 2>&1; then
    echo "[error] productsign not found; cannot sign package. Install Xcode command line tools or unset PKG_SIGN_IDENTITY." >&2
    exit 1
  fi

  if [[ "${PKG_DISABLE_TIMESTAMP}" == "1" ]]; then
    productsign --timestamp=none --sign "${PKG_SIGN_IDENTITY}" "${OUTPUT_PKG}" "${SIGNED_PKG}"
  else
    productsign --timestamp --sign "${PKG_SIGN_IDENTITY}" "${OUTPUT_PKG}" "${SIGNED_PKG}"
  fi
  mv "${SIGNED_PKG}" "${OUTPUT_PKG}"
  echo "Signed installer package with identity '${PKG_SIGN_IDENTITY}'"
fi

if [[ -n "${PKG_NOTARIZE_PROFILE:-}" ]]; then
  if ! command -v xcrun >/dev/null 2>&1; then
    echo "[error] xcrun not found; cannot submit for notarization. Install Xcode command line tools or unset PKG_NOTARIZE_PROFILE." >&2
    exit 1
  fi

  echo "Submitting package for notarization with profile '${PKG_NOTARIZE_PROFILE}' (this may take a while)..."
  xcrun notarytool submit "${OUTPUT_PKG}" --wait --keychain-profile "${PKG_NOTARIZE_PROFILE}"
  xcrun stapler staple "${OUTPUT_PKG}"
  echo "Notarization complete for ${OUTPUT_PKG}"
fi
