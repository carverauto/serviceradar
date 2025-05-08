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

# Ensure certificate directory permissions
if [ -d "/etc/serviceradar/certs" ]; then
    chown -R serviceradar:serviceradar /etc/serviceradar/certs
    chmod -R 640 /etc/serviceradar/certs/*.pem
fi

# Set permissions
chown -R serviceradar:serviceradar /etc/serviceradar
chmod -R 755 /etc/serviceradar

# Reload systemd and manage service
systemctl daemon-reload
systemctl enable serviceradar-poller
systemctl start serviceradar-poller || {
    echo "Failed to start serviceradar-poller service. Check logs with: journalctl -xeu serviceradar-poller"
    exit 1
}