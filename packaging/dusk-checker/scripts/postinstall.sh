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

# Reload systemd and manage service
systemctl daemon-reload
systemctl enable serviceradar-dusk-checker
systemctl start serviceradar-dusk-checker || {
    echo "Failed to start serviceradar-dusk-checker service. Check logs with: journalctl -xeu serviceradar-dusk-checker"
    exit 1
}