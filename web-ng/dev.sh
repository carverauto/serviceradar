#!/bin/bash
# Start web-ng in standalone mode (no cluster, uses docker database)
#
# Usage: ./dev.sh
#
# This starts Phoenix without cluster connectivity, but with the
# docker database configuration for local development.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=========================================="
echo "ServiceRadar Web-NG (Standalone Mode)"
echo "=========================================="

# Database configuration (docker postgres on port 5455)
export CNPG_HOST="${CNPG_HOST:-localhost}"
export CNPG_PORT="${CNPG_PORT:-5455}"
export CNPG_DATABASE="${CNPG_DATABASE:-serviceradar}"
export CNPG_USERNAME="${CNPG_USERNAME:-serviceradar}"
export CNPG_PASSWORD="${CNPG_PASSWORD:-serviceradar}"
export CNPG_SSL_MODE="${CNPG_SSL_MODE:-verify-full}"
export CNPG_CERT_DIR="${CNPG_CERT_DIR:-/home/mfreeman/serviceradar/.local-dev-certs}"
export CNPG_TLS_SERVER_NAME="${CNPG_TLS_SERVER_NAME:-cnpg}"

echo "Database: $CNPG_HOST:$CNPG_PORT/$CNPG_DATABASE"
echo "SSL Mode: $CNPG_SSL_MODE"
echo "=========================================="
echo ""

# Check database connectivity
echo -n "Checking database connectivity... "
if timeout 2 nc -zv $CNPG_HOST $CNPG_PORT 2>/dev/null; then
    echo "OK"
else
    echo "FAILED"
    echo ""
    echo "Error: Cannot connect to database at $CNPG_HOST:$CNPG_PORT"
    echo "Make sure docker compose is running: docker compose up -d"
    exit 1
fi
echo ""

exec mix phx.server
