#!/usr/bin/env bash
set -euo pipefail

# Wrapper script for Kong systemd service
# Ensures proper permissions and environment

# Set Kong prefix directory
KONG_PREFIX="/usr/local/kong"
KONG_CONF="/etc/kong/kong.conf"

export LUA_PATH="/usr/local/openresty/site/lualib"

# Find Kong binary - check common locations
KONG_BIN=""
for path in /usr/bin/kong /usr/local/bin/kong /opt/kong/bin/kong; do
  if [ -x "$path" ]; then
    KONG_BIN="$path"
    break
  fi
done

if [ -z "$KONG_BIN" ]; then
  echo "Error: Kong binary not found. Make sure Kong is installed." >&2
  exit 1
fi

# Create prefix directory if it doesn't exist
mkdir -p "$KONG_PREFIX" || true

# Ensure kong user owns the prefix directory
if getent passwd kong >/dev/null 2>&1; then
  chown -R kong:kong "$KONG_PREFIX" || true
  chown -R kong:kong /etc/kong || true
fi

# Export necessary environment variables
export KONG_PREFIX="$KONG_PREFIX"

# Execute the Kong command passed as arguments
exec "$KONG_BIN" "$@" -c "$KONG_CONF"
