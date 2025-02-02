#!/bin/bash
# update_configs.sh
# Script to update ServiceRadar component configurations for TLS

set -e

# Default values
CONFIG_DIR="/etc/serviceradar"
CERT_DIR="/etc/serviceradar/certs"

usage() {
    echo "Usage: $0 [-c config_dir] [-d cert_dir]"
    echo "  -c: Configuration directory (default: /etc/serviceradar)"
    echo "  -d: Certificate directory (default: /etc/serviceradar/certs)"
    exit 1
}

while getopts "c:d:h" opt; do
    case $opt in
        c) CONFIG_DIR="$OPTARG" ;;
        d) CERT_DIR="$OPTARG" ;;
        h) usage ;;
        \?) usage ;;
    esac
done

# Function to update JSON config files
update_config() {
    local file="$1"
    local tmp_file="${file}.tmp"

    if [ ! -f "$file" ]; then
        echo "Warning: Config file $file not found, skipping..."
        return
    }

    # Add security configuration if it doesn't exist
    if grep -q "security" "$file"; then
        # Update existing security configuration
        sed -i'.bak' \
            -e 's/"mode":[ ]*"[^"]*"/"mode": "mtls"/' \
            -e 's|"cert_dir":[ ]*"[^"]*"|"cert_dir": "'${CERT_DIR}'"|' \
            "$file"
    else
        # Add new security configuration before the last closing brace
        sed -i'.bak' '$ i\,\n  "security": {\n    "mode": "mtls",\n    "cert_dir": "'${CERT_DIR}'"\n  }' "$file"
    fi
}

# Update configurations for each component
echo "Updating cloud configuration..."
update_config "${CONFIG_DIR}/cloud.json"

echo "Updating poller configuration..."
update_config "${CONFIG_DIR}/poller.json"

echo "Updating agent configuration..."
update_config "${CONFIG_DIR}/agent.json"

echo "
Configuration updates complete! The following files have been updated:
- ${CONFIG_DIR}/cloud.json
- ${CONFIG_DIR}/poller.json
- ${CONFIG_DIR}/agent.json

Backup files have been created with .bak extension.

Please restart the services to apply the new configuration:
- systemctl restart serviceradar-cloud
- systemctl restart serviceradar-poller
- systemctl restart serviceradar-agent
"