#!/bin/sh
# Copyright 2025 Carver Automation Corporation.

set -e

echo "Starting ServiceRadar Web entrypoint..."

# Load configuration from api.env if it exists (check generated config first)
if [ -f /etc/serviceradar/config/api.env ]; then
    echo "Loading API configuration from /etc/serviceradar/config/api.env (generated)..."
    set -a
    . /etc/serviceradar/config/api.env
    set +a
elif [ -f /etc/serviceradar/api.env ]; then
    echo "Loading API configuration from /etc/serviceradar/api.env..."
    set -a
    . /etc/serviceradar/api.env
    set +a
fi

# Load web.json configuration if it exists
if [ -f /etc/serviceradar/web.json ]; then
    echo "Loading web configuration from /etc/serviceradar/web.json..."
    # Parse JSON and export as environment variables
    if command -v jq >/dev/null 2>&1; then
        export WEB_PORT=$(jq -r '.port // 3000' /etc/serviceradar/web.json)
        export WEB_HOST=$(jq -r '.host // "0.0.0.0"' /etc/serviceradar/web.json)
        export WEB_API_URL=$(jq -r '.api_url // "http://localhost:8090"' /etc/serviceradar/web.json)
    fi
fi

# Set internal API URL for server-side calls (container-to-container)
if [ -z "$NEXT_INTERNAL_API_URL" ]; then
    export NEXT_INTERNAL_API_URL="http://core:8090"
    echo "Setting NEXT_INTERNAL_API_URL=$NEXT_INTERNAL_API_URL"
fi

# Set public API URL for client-side calls (browser to API via nginx)
# Always use web.json config value if available, otherwise use existing env var or fallback
if [ -n "$WEB_API_URL" ]; then
    export NEXT_PUBLIC_API_URL="$WEB_API_URL"
    echo "Setting NEXT_PUBLIC_API_URL=$NEXT_PUBLIC_API_URL (from web.json)"
elif [ -z "$NEXT_PUBLIC_API_URL" ]; then
    export NEXT_PUBLIC_API_URL="http://localhost"
    echo "Setting NEXT_PUBLIC_API_URL=$NEXT_PUBLIC_API_URL (fallback)"
fi

# Load API key from generated file if not already set from api.env
if [ -z "$API_KEY" ] && [ -f /etc/serviceradar/certs/api-key ]; then
    export API_KEY=$(cat /etc/serviceradar/certs/api-key)
    echo "Loaded API key from /etc/serviceradar/certs/api-key"
elif [ -z "$API_KEY" ]; then
    echo "Warning: API_KEY not set - authentication may fail"
fi

# Load JWT secret from generated file if not already set from api.env
if [ -z "$JWT_SECRET" ] && [ -f /etc/serviceradar/certs/jwt-secret ]; then
    export JWT_SECRET=$(cat /etc/serviceradar/certs/jwt-secret)
    echo "Loaded JWT secret from /etc/serviceradar/certs/jwt-secret"
elif [ -z "$JWT_SECRET" ]; then
    echo "Warning: JWT_SECRET not set - authentication may fail"
fi

# Set auth enabled
if [ -z "$AUTH_ENABLED" ]; then
    export AUTH_ENABLED="true"
fi

# Set Node environment
export NODE_ENV="${NODE_ENV:-production}"

# Set hostname and port
export HOSTNAME="${WEB_HOST:-0.0.0.0}"
export PORT="${WEB_PORT:-3000}"

echo "Configuration:"
echo "  NODE_ENV=$NODE_ENV"
echo "  HOSTNAME=$HOSTNAME"
echo "  PORT=$PORT"
echo "  NEXT_INTERNAL_API_URL=$NEXT_INTERNAL_API_URL"
echo "  NEXT_PUBLIC_API_URL=$NEXT_PUBLIC_API_URL"
echo "  AUTH_ENABLED=$AUTH_ENABLED"
echo "  API_KEY=[REDACTED]"
echo "  JWT_SECRET=[REDACTED]"

# Start the Next.js application
echo "Starting Next.js application..."
exec "$@"
