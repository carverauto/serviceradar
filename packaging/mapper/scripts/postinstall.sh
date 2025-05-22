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

# Set permissions
chown -R serviceradar:serviceradar /etc/serviceradar
chmod -R 755 /etc/serviceradar

# Set required capability for ICMP scanning
if [ -x /usr/local/bin/serviceradar-mapper ]; then
    setcap cap_net_raw=+ep /usr/local/bin/serviceradar-mapper || {
        echo "Warning: Failed to set cap_net_raw capability on /usr/local/bin/serviceradar-mapper"
        echo "ICMP scanning will not work without this capability. Ensure libcap2-bin is installed and run:"
        echo "  sudo setcap cap_net_raw=+ep /usr/local/bin/serviceradar-mapper"
    }
fi

# Reload systemd and manage service
systemctl daemon-reload
systemctl enable serviceradar-mapper
systemctl start serviceradar-mapper || {
    echo "Failed to start serviceradar-mapper service. Check logs with: journalctl -xeu serviceradar-mapper"
    exit 1
}