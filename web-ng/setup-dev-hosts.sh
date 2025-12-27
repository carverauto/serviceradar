#!/bin/bash
# One-time setup for local cluster development
# Adds docker container hostnames to /etc/hosts
#
# Usage: sudo ./setup-dev-hosts.sh

set -e

# Get container IPs
get_container_ip() {
    docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1" 2>/dev/null || echo ""
}

CORE_IP=$(get_container_ip "serviceradar-core-elx-mtls")
POLLER_IP=$(get_container_ip "serviceradar-poller-elx-mtls")
AGENT_IP=$(get_container_ip "serviceradar-agent-elx-mtls")

echo "ServiceRadar Development Host Setup"
echo "===================================="
echo ""
echo "This script adds docker container hostnames to /etc/hosts"
echo "for ERTS cluster connectivity."
echo ""
echo "Container IPs detected:"
echo "  core-elx:    ${CORE_IP:-not running}"
echo "  poller-elx:  ${POLLER_IP:-not running}"
echo "  agent-elx:   ${AGENT_IP:-not running}"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run with sudo"
    echo "Usage: sudo $0"
    exit 1
fi

# Backup hosts file
cp /etc/hosts /etc/hosts.backup.$(date +%Y%m%d%H%M%S)

# Remove any existing serviceradar entries
sed -i '/# ServiceRadar cluster/d' /etc/hosts
sed -i '/core-elx/d' /etc/hosts
sed -i '/poller-elx/d' /etc/hosts
sed -i '/agent-elx/d' /etc/hosts
sed -i '/web-ng/d' /etc/hosts

# Add new entries
echo "" >> /etc/hosts
echo "# ServiceRadar cluster hosts (added by setup-dev-hosts.sh)" >> /etc/hosts

if [ -n "$CORE_IP" ]; then
    echo "$CORE_IP core-elx" >> /etc/hosts
    echo "Added: $CORE_IP core-elx"
fi

if [ -n "$POLLER_IP" ]; then
    echo "$POLLER_IP poller-elx" >> /etc/hosts
    echo "Added: $POLLER_IP poller-elx"
fi

if [ -n "$AGENT_IP" ]; then
    echo "$AGENT_IP agent-elx" >> /etc/hosts
    echo "Added: $AGENT_IP agent-elx"
fi

# Add gateway as web-ng (so docker containers can reach us)
GATEWAY_IP=$(docker network inspect serviceradar_serviceradar-net 2>/dev/null | grep Gateway | head -1 | awk -F'"' '{print $4}')
if [ -n "$GATEWAY_IP" ]; then
    echo "$GATEWAY_IP web-ng" >> /etc/hosts
    echo "Added: $GATEWAY_IP web-ng"
fi

echo ""
echo "Setup complete! Host entries added to /etc/hosts"
echo ""
echo "You can now run: ./dev-cluster.sh"
