#!/bin/bash
# deployCerts.sh - Deploy TLS certificates for ServiceRadar

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo)"
    exit 1
fi

# Exit on any error
set -e

# Define the list of remote machines
MACHINES=("192.168.2.10" "192.168.2.11" "192.168.2.12")

# Certificate source and destination directories
CERT_SRC="/etc/serviceradar/certs"
CERT_DEST="/etc/serviceradar/certs"

# Verify certificates exist
if [ ! -d "$CERT_SRC" ]; then
    echo "Error: Certificate directory $CERT_SRC does not exist"
    exit 1
fi

# Check required certificate files
required_certs=("ca.crt" "agent.crt" "agent.key" "poller.crt" "poller.key")
for cert in "${required_certs[@]}"; do
    if [ ! -f "$CERT_SRC/$cert" ]; then
        echo "Error: Required certificate file $CERT_SRC/$cert not found"
        exit 1
    fi
done

# Function to deploy certificates
deploy_certs() {
    local MACHINE=$1
    echo "Deploying certificates to $MACHINE..."

    # Create certificate directory
    ssh root@$MACHINE "mkdir -p $CERT_DEST && chmod 700 $CERT_DEST"

    # Copy CA certificate (needed by all nodes)
    echo "Copying CA certificate..."
    scp "$CERT_SRC/ca.crt" root@$MACHINE:"$CERT_DEST/"

    # Copy component-specific certificates based on installed packages
    if ssh root@$MACHINE "dpkg -l | grep -q serviceradar-agent"; then
        echo "Copying agent certificates..."
        scp "$CERT_SRC/agent.key" "$CERT_SRC/agent.crt" root@$MACHINE:"$CERT_DEST/"
    fi

    if ssh root@$MACHINE "dpkg -l | grep -q serviceradar-poller"; then
        echo "Copying poller certificates..."
        scp "$CERT_SRC/poller.key" "$CERT_SRC/poller.crt" root@$MACHINE:"$CERT_DEST/"
    fi

    # Set proper permissions
    echo "Setting permissions..."
    ssh root@$MACHINE "
        chown -R serviceradar:serviceradar $CERT_DEST
        chmod 700 $CERT_DEST
        chmod 600 $CERT_DEST/*.key
        chmod 644 $CERT_DEST/*.crt
    "
}

# Function to update configuration for TLS
update_config() {
    local MACHINE=$1
    echo "Updating TLS configuration on $MACHINE..."

    # Create a temporary config updater script
    cat > /tmp/update_config.sh << 'EOF'
#!/bin/bash
update_json() {
    local file="$1"
    if [ -f "$file" ]; then
        # Backup original config
        cp "$file" "${file}.bak"

        # Add or update security configuration
        if grep -q "security" "$file"; then
            sed -i 's/"mode":[ ]*"[^"]*"/"mode": "mtls"/' "$file"
            sed -i 's|"cert_dir":[ ]*"[^"]*"|"cert_dir": "\/etc\/serviceradar\/certs"|' "$file"
        else
            # Add security config before the last closing brace
            sed -i '$ i\,\n  "security": {\n    "mode": "mtls",\n    "cert_dir": "\/etc\/serviceradar\/certs"\n  }' "$file"
        fi
        echo "Updated configuration in $file"
    else
        echo "Warning: Config file $file not found"
    fi
}

# Update configurations for installed components
for config in "/etc/serviceradar/agent.json" "/etc/serviceradar/poller.json"; do
    if [ -f "$config" ]; then
        echo "Updating $config..."
        update_json "$config"
    fi
done
EOF

    # Copy and execute the config updater script
    scp /tmp/update_config.sh root@$MACHINE:/tmp/
    ssh root@$MACHINE "chmod +x /tmp/update_config.sh && /tmp/update_config.sh"

    # Clean up
    ssh root@$MACHINE "rm /tmp/update_config.sh"
    rm /tmp/update_config.sh
}

# Function to restart services
restart_services() {
    local MACHINE=$1
    echo "Restarting services on $MACHINE..."

    ssh root@$MACHINE "
        if systemctl list-unit-files | grep -q serviceradar-agent; then
            echo 'Restarting agent service...'
            systemctl restart serviceradar-agent
        fi
        if systemctl list-unit-files | grep -q serviceradar-poller; then
            echo 'Restarting poller service...'
            systemctl restart serviceradar-poller
        fi
    "
}

# Main deployment loop
for MACHINE in "${MACHINES[@]}"; do
    echo "=== Deploying certificates to $MACHINE ==="

    # Deploy certificates
    deploy_certs "$MACHINE"

    # Update configuration
    update_config "$MACHINE"

    # Restart services
    restart_services "$MACHINE"

    echo "Certificate deployment to $MACHINE completed."
    echo
done

echo "All certificate deployments completed successfully!"

# Verify deployments
echo "=== Verifying deployments ==="
for MACHINE in "${MACHINES[@]}"; do
    echo "Checking certificates and services on $MACHINE:"
    ssh root@$MACHINE "
        echo 'Certificate files:'
        ls -l $CERT_DEST
        echo
        echo 'Service statuses:'
        systemctl status serviceradar-* --no-pager || true
        echo
        echo 'Latest logs:'
        journalctl -u serviceradar-* --no-pager -n 10
    "
    echo "----------------------------------------"
done