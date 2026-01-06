#!/bin/bash
# Start web-ng in cluster mode with TLS distribution
#
# Usage: ./dev-cluster.sh
#
# Prerequisites: Run `sudo ./setup-dev-hosts.sh` once to configure hostname resolution
#
# This script:
# 1. Verifies docker cluster containers are running
# 2. Checks hostname resolution
# 3. Configures TLS distribution to match docker cluster
# 4. Starts Phoenix with short names (sname) for cluster compatibility

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=========================================="
echo "ServiceRadar Web-NG Cluster Mode (TLS)"
echo "=========================================="
echo ""

# Check docker containers are running
check_container() {
    local name=$1
    local hostname=$2
    if docker ps --format '{{.Names}}' | grep -q "$name"; then
        local ip=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name" 2>/dev/null)
        echo -e "  ${GREEN}✓${NC} $hostname ($ip)"
        return 0
    else
        echo -e "  ${RED}✗${NC} $hostname (not running)"
        return 1
    fi
}

echo "Docker containers:"
CORE_OK=0; check_container "serviceradar-core-elx-mtls" "core-elx" || CORE_OK=1
GATEWAY_OK=0; check_container "serviceradar-agent-gateway-mtls" "agent-gateway" || GATEWAY_OK=1
AGENT_OK=0; check_container "serviceradar-agent-mtls" "agent" || AGENT_OK=1
echo ""

if [ $CORE_OK -ne 0 ] || [ $GATEWAY_OK -ne 0 ] || [ $AGENT_OK -ne 0 ]; then
    echo -e "${YELLOW}Warning: Some cluster containers are not running${NC}"
    echo "Start them with: docker compose up -d"
    echo ""
fi

# Check hostname resolution
check_host() {
    local hostname=$1
    if getent hosts "$hostname" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} $hostname resolvable"
        return 0
    else
        echo -e "  ${RED}✗${NC} $hostname NOT resolvable"
        return 1
    fi
}

echo "Hostname resolution:"
HOSTS_OK=0
check_host "core-elx" || HOSTS_OK=1
check_host "agent-gateway" || HOSTS_OK=1
check_host "agent" || HOSTS_OK=1
echo ""

if [ $HOSTS_OK -ne 0 ]; then
    echo -e "${RED}Error: Hostnames not resolvable${NC}"
    echo ""
    echo "Run the setup script to add hosts entries:"
    echo "  sudo ./setup-dev-hosts.sh"
    echo ""
    exit 1
fi

# Verify TLS config exists
SSL_DIST_CONF="$SCRIPT_DIR/ssl_dist.dev.conf"
if [ ! -f "$SSL_DIST_CONF" ]; then
    echo -e "${RED}Error: ssl_dist.dev.conf not found${NC}"
    exit 1
fi

# Ensure EPMD is running
epmd -daemon 2>/dev/null || true

# Database configuration (docker postgres on port 5455)
export CNPG_HOST="${CNPG_HOST:-localhost}"
export CNPG_PORT="${CNPG_PORT:-5455}"
export CNPG_DATABASE="${CNPG_DATABASE:-serviceradar}"
export CNPG_USERNAME="${CNPG_USERNAME:-serviceradar}"
export CNPG_PASSWORD="${CNPG_PASSWORD:-serviceradar}"
export CNPG_SSL_MODE="${CNPG_SSL_MODE:-verify-full}"
export CNPG_CERT_DIR="${CNPG_CERT_DIR:-/home/mfreeman/serviceradar/.local-dev-certs}"
export CNPG_TLS_SERVER_NAME="${CNPG_TLS_SERVER_NAME:-cnpg}"

# Cluster configuration
export CLUSTER_ENABLED="true"
export RELEASE_COOKIE="serviceradar_dev_cookie"
export CLUSTER_HOSTS="serviceradar_core@core-elx,serviceradar_agent_gateway@agent-gateway"

# Use "web-ng" as the hostname to match docker CLUSTER_HOSTS expectations
# The docker containers expect serviceradar_web_ng@web-ng
NODE_HOSTNAME="web-ng"
echo "Starting Phoenix with TLS distribution..."
echo "  Node: serviceradar_web_ng@$NODE_HOSTNAME"
echo "  Cookie: serviceradar_dev_cookie"
echo ""

# Start with:
# - Short names (sname) to match docker cluster configuration
# - TLS distribution enabled via -proto_dist inet_tls
# - Explicit hostname to match what docker containers expect
exec elixir \
    --sname "serviceradar_web_ng@$NODE_HOSTNAME" \
    --cookie serviceradar_dev_cookie \
    --erl "-proto_dist inet_tls -ssl_dist_optfile $SSL_DIST_CONF" \
    -S mix phx.server
