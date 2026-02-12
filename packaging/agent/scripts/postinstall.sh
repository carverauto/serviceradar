#!/bin/sh
set -e

# Create serviceradar group if it doesn't exist
if ! getent group serviceradar >/dev/null; then
    groupadd --system serviceradar
fi

# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin -g serviceradar serviceradar
fi

# Create required directories
mkdir -p /etc/serviceradar
mkdir -p /var/lib/serviceradar
mkdir -p /var/lib/serviceradar/cache


# Create checkers/sweep directory if it doesnt already exist
mkdir -p /etc/serviceradar/checkers/sweep

# Set permissions
if [ -f /etc/serviceradar/agent.json ]; then
    chown serviceradar:serviceradar /etc/serviceradar/agent.json
fi
chown -R serviceradar:serviceradar /etc/serviceradar/checkers
chown -R serviceradar:serviceradar /var/lib/serviceradar
chmod 755 /etc/serviceradar/
chmod 755 /var/lib/serviceradar
chmod 755 /var/lib/serviceradar/cache

# Set required capability for ICMP scanning
if [ -x /usr/local/bin/serviceradar-agent ]; then
    setcap cap_net_raw=+ep /usr/local/bin/serviceradar-agent || {
        echo "Warning: Failed to set cap_net_raw capability on /usr/local/bin/serviceradar-agent"
        echo "ICMP scanning will not work without this capability. Ensure libcap2-bin is installed and run:"
        echo "  sudo setcap cap_net_raw=+ep /usr/local/bin/serviceradar-agent"
    }
fi

# Reload systemd and manage service
systemctl daemon-reload
systemctl enable serviceradar-agent
if [ -f /etc/serviceradar/agent.json ] && \
   [ -f /etc/serviceradar/certs/component.pem ] && \
   [ -f /etc/serviceradar/certs/component-key.pem ] && \
   [ -f /etc/serviceradar/certs/ca-chain.pem ]; then
    systemctl restart serviceradar-agent || {
        echo "Failed to start serviceradar-agent service. Check logs with: journalctl -xeu serviceradar-agent"
        exit 1
    }
else
    echo "Skipping serviceradar-agent start: enrollment assets not found. Run serviceradar-cli enroll, then: systemctl restart serviceradar-agent"
fi

# Set required capability for ICMP scanning
setcap cap_net_raw=+ep /usr/local/bin/serviceradar-agent
