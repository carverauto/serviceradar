#!/usr/bin/env bash
set -euo pipefail

# Wrapper script for Kong systemd service
# Ensures proper permissions and environment

# Set Kong prefix directory
KONG_PREFIX="/usr/local/kong"
KONG_CONF="/etc/kong/kong.conf"

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
exec /usr/bin/kong "$@" -c "$KONG_CONF"