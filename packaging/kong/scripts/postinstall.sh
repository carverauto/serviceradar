#!/usr/bin/env bash
set -euo pipefail

PKG_DIR="/usr/share/serviceradar-kong/vendor"
OS="unknown"
ARCH="$(uname -m)"

detect_os() {
  if command -v dpkg >/dev/null 2>&1 || [ -f /etc/debian_version ]; then
    OS="debian"
  elif command -v rpm >/dev/null 2>&1 || [ -f /etc/redhat-release ]; then
    OS="rpm"
  fi
}

install_debian() {
  # Prefer OSS package if present, fall back to enterprise filename
  case "$ARCH" in
    x86_64|amd64)
      FILE_OSS=$(ls "$PKG_DIR"/kong_*_amd64.deb 2>/dev/null | head -n1 || true)
      FILE_ENT="$PKG_DIR/kong-enterprise-edition_3.11.0.3_amd64.deb"
      ;;
    aarch64|arm64)
      FILE_OSS=$(ls "$PKG_DIR"/kong_*_arm64.deb 2>/dev/null | head -n1 || true)
      FILE_ENT="$PKG_DIR/kong-enterprise-edition_3.11.0.3_arm64.deb"
      ;;
    *)
      echo "Unsupported Debian arch: $ARCH" >&2
      exit 1
      ;;
  esac
  FILE="${FILE_OSS:-$FILE_ENT}"
  [ -n "$FILE" ] && [ -f "$FILE" ] || { echo "Missing bundled kong .deb in $PKG_DIR" >&2; exit 1; }
  echo "Installing Kong from $FILE (dpkg -i)..."
  dpkg -i "$FILE" || (apt-get update && apt-get install -f -y && dpkg -i "$FILE")
}

install_rpm() {
  case "$ARCH" in
    x86_64)
      FILE_OSS=$(ls "$PKG_DIR"/kong-*.x86_64.rpm 2>/dev/null | head -n1 || true)
      FILE_ENT="$PKG_DIR/kong-enterprise-edition-3.11.0.3.el9.x86_64.rpm"
      ;;
    aarch64|arm64)
      FILE_OSS=$(ls "$PKG_DIR"/kong-*.aarch64.rpm 2>/dev/null | head -n1 || true)
      FILE_ENT="$PKG_DIR/kong-enterprise-edition-3.11.0.3.el9.aarch64.rpm"
      ;;
    *)
      echo "Unsupported RHEL arch: $ARCH" >&2
      exit 1
      ;;
  esac
  FILE="${FILE_OSS:-$FILE_ENT}"
  [ -n "$FILE" ] && [ -f "$FILE" ] || { echo "Missing bundled kong .rpm in $PKG_DIR" >&2; exit 1; }
  echo "Installing Kong from $FILE (rpm -Uvh --nodeps)..."
  rpm -Uvh --nodeps "$FILE" || yum install -y "$FILE"
}

main() {
  detect_os
  case "$OS" in
    debian) install_debian ;;
    rpm) install_rpm ;;
    *) echo "Unsupported OS for serviceradar-kong postinstall" >&2; exit 1 ;;
  esac

  # Write DB-less config if not present
  mkdir -p /etc/kong || true
  if [ ! -f /etc/kong/kong.conf ]; then
    cat >/etc/kong/kong.conf <<'EOF'
database = off
declarative_config = /etc/kong/kong.yml
proxy_listen = 0.0.0.0:8000, 0.0.0.0:8443 ssl
admin_listen = 127.0.0.1:8001
EOF
  fi

  # Attempt to render DB-less config from JWKS using serviceradar-cli if present
  JWKS_URL_DEFAULT="http://localhost:8090/auth/jwks.json"
  SERVICE_URL_DEFAULT="http://localhost:8090"
  ROUTE_PATH_DEFAULT="/api"
  JWKS_URL="${JWKS_URL:-$JWKS_URL_DEFAULT}"
  SERVICE_URL="${KONG_SERVICE_URL:-$SERVICE_URL_DEFAULT}"
  ROUTE_PATH="${KONG_ROUTE_PATH:-$ROUTE_PATH_DEFAULT}"

  if command -v serviceradar-cli >/dev/null 2>&1; then
    echo "Rendering /etc/kong/kong.yml from JWKS ($JWKS_URL) via serviceradar-cli ..."
    mkdir -p /etc/kong || true
    if serviceradar-cli render-kong --jwks "$JWKS_URL" --service "$SERVICE_URL" --path "$ROUTE_PATH" --out "/etc/kong/kong.yml"; then
      echo "Rendered Kong DB-less config at /etc/kong/kong.yml"
    else
      echo "Warning: Failed to fetch JWKS at $JWKS_URL; leaving /etc/kong/kong.yml untouched." >&2
      [ -f /etc/kong/kong.yml ] || touch /etc/kong/kong.yml
    fi
  else
    echo "Note: serviceradar-cli not found; skipping automatic DB-less config rendering."
    [ -f /etc/kong/kong.yml ] || touch /etc/kong/kong.yml
  fi

  # Enable and start Kong if systemd is present
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable kong || true
    systemctl restart kong || true
  fi

  echo "Kong installed (DB-less). Configure /etc/kong/kong.yml as needed."
}

main "$@"
