#!/usr/bin/env bash
set -euo pipefail

PKG_DIR="/usr/share/serviceradar-kong/vendor"
OS="unknown"
ARCH="$(uname -m)"

# Ensure we can find /usr/local binaries (RPM scriptlet PATH omits it by default)
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

detect_os() {
  if command -v dpkg >/dev/null 2>&1 || [ -f /etc/debian_version ]; then
    OS="debian"
  elif command -v rpm >/dev/null 2>&1 || [ -f /etc/redhat-release ]; then
    OS="rpm"
  fi
}

select_vendor_package() {
  # Arguments are suffixes (e.g. ".amd64.deb"); prefer OSS builds and fall back to enterprise bundles.
  local suffix
  local pattern
  local matches
  for prefix in kong kong-enterprise-edition; do
    for suffix in "$@"; do
      pattern="${PKG_DIR}/${prefix}*${suffix}"
      matches=$(compgen -G "$pattern" || true)
      if [ -n "$matches" ]; then
        printf '%s\n' $matches | head -n1
        return 0
      fi
    done
  done
  return 1
}

install_debian() {
  local file=""
  case "$ARCH" in
    x86_64|amd64)
      file=$(select_vendor_package ".amd64.deb" "_amd64.deb") || true
      ;;
    aarch64|arm64)
      file=$(select_vendor_package ".arm64.deb" "_arm64.deb") || true
      ;;
    *)
      echo "Unsupported Debian arch: $ARCH" >&2
      exit 1
      ;;
  esac

  [ -n "$file" ] && [ -f "$file" ] || { echo "Missing bundled kong .deb in $PKG_DIR" >&2; exit 1; }
  echo "Installing Kong from $file (dpkg -i)..."
  dpkg -i "$file" || (apt-get update && apt-get install -f -y && dpkg -i "$file")
}

install_rpm() {
  local file=""
  case "$ARCH" in
    x86_64|amd64)
      file=$(select_vendor_package ".x86_64.rpm" ".amd64.rpm") || true
      ;;
    aarch64|arm64)
      file=$(select_vendor_package ".aarch64.rpm") || true
      ;;
    *)
      echo "Unsupported RHEL arch: $ARCH" >&2
      exit 1
      ;;
  esac

  [ -n "$file" ] && [ -f "$file" ] || { echo "Missing bundled kong .rpm in $PKG_DIR" >&2; exit 1; }
  echo "Installing Kong from $file (rpm -Uvh --nodeps)..."
  if ! rpm -Uvh --nodeps "$file"; then
    if command -v dnf >/dev/null 2>&1; then
      dnf install -y "$file"
    else
      yum install -y "$file"
    fi
  fi
}

main() {
  detect_os
  case "$OS" in
    debian) install_debian ;;
    rpm) install_rpm ;;
    *) echo "Unsupported OS for serviceradar-kong postinstall" >&2; exit 1 ;;
  esac

  # Create kong user and group if they don't exist
  if ! getent group kong >/dev/null 2>&1; then
    groupadd -r kong || true
  fi
  if ! getent passwd kong >/dev/null 2>&1; then
    useradd -r -g kong -d /usr/local/kong -s /sbin/nologin kong || true
  fi

  # Write DB-less config if not present
  mkdir -p /etc/kong || true
  if [ ! -f /etc/kong/kong.conf ]; then
    cat >/etc/kong/kong.conf <<'EOFCONF'
database = off
declarative_config = /etc/kong/kong.yml
proxy_listen = 0.0.0.0:8000, 0.0.0.0:8444 ssl
admin_listen = 127.0.0.1:8001
lua_package_path = ./?.lua;./?/init.lua;/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua;/usr/local/openresty/site/lualib/?.lua;/usr/local/openresty/site/lualib/?/init.lua;
lua_package_cpath = ./?.so;/usr/local/lib/lua/5.1/?.so;/usr/local/openresty/site/lualib/?.so;;
EOFCONF
  fi

  # Attempt to render DB-less config from JWKS using serviceradar-cli if present
  JWKS_URL_DEFAULT="http://localhost:8090/auth/jwks.json"
  SERVICE_URL_DEFAULT="http://localhost:8090"
  ROUTE_PATH_DEFAULT="/api"
  JWKS_URL="${JWKS_URL:-$JWKS_URL_DEFAULT}"
  SERVICE_URL="${KONG_SERVICE_URL:-$SERVICE_URL_DEFAULT}"
  ROUTE_PATH="${KONG_ROUTE_PATH:-$ROUTE_PATH_DEFAULT}"

  SERVICERADAR_CLI_BIN="${SERVICERADAR_CLI:-}"
  if [ -z "$SERVICERADAR_CLI_BIN" ]; then
    for candidate in \
      "$(command -v serviceradar-cli 2>/dev/null || true)" \
      "/usr/local/bin/serviceradar-cli" \
      "/usr/bin/serviceradar-cli"; do
      if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        SERVICERADAR_CLI_BIN="$candidate"
        break
      fi
    done
  fi

  if [ -n "$SERVICERADAR_CLI_BIN" ] && [ -x "$SERVICERADAR_CLI_BIN" ]; then
    echo "Rendering /etc/kong/kong.yml from JWKS ($JWKS_URL) via ${SERVICERADAR_CLI_BIN} ..."
    mkdir -p /etc/kong || true
    if "$SERVICERADAR_CLI_BIN" render-kong --jwks "$JWKS_URL" --service "$SERVICE_URL" --path "$ROUTE_PATH" --out "/etc/kong/kong.yml"; then
      echo "Rendered Kong DB-less config at /etc/kong/kong.yml"
    else
      echo "Warning: Failed to fetch JWKS at $JWKS_URL; leaving /etc/kong/kong.yml untouched." >&2
      [ -f /etc/kong/kong.yml ] || touch /etc/kong/kong.yml
    fi
  else
    echo "Note: serviceradar-cli not found; skipping automatic DB-less config rendering."
    [ -f /etc/kong/kong.yml ] || touch /etc/kong/kong.yml
  fi

  # Enable serviceradar-kong if systemd is present (but don't start it automatically)
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
    # Don't auto-enable or start - let user do it manually
    echo "ServiceRadar Kong service is available. Use:"
    echo "  systemctl enable serviceradar-kong"
    echo "  systemctl start serviceradar-kong"
  fi

  echo "Kong installed (DB-less). Configure /etc/kong/kong.yml as needed."
}

main "$@"
