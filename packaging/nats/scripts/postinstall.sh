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

# Create NATS user if it doesn't exist
if ! id -u nats >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin -g serviceradar nats
fi

# Create required directories
mkdir -p /etc/serviceradar
mkdir -p /var/lib/serviceradar

# Set permissions
chown -R serviceradar:serviceradar /etc/serviceradar
chmod -R 755 /etc/serviceradar
# if the certs dir exists, set permissions
if [ -d "/etc/serviceradar/certs" ]; then
    chown -R serviceradar:serviceradar /etc/serviceradar/certs
    chmod -R 755 /etc/serviceradar/certs
fi

# Only try to manage service if it exists
if [ -f "/lib/systemd/system/serviceradar-${component_dir}.service" ]; then
    # Reload systemd
    systemctl daemon-reload

    # Enable and start service
    systemctl enable "serviceradar-${component_dir}"
    systemctl start "serviceradar-${component_dir}"
fi