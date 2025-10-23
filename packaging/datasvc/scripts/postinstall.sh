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

# Only try to manage service if it exists
if [ -f "/lib/systemd/system/serviceradar-${component_dir}.service" ]; then
    # Reload systemd
    systemctl daemon-reload

    # Enable and start service
    systemctl enable "serviceradar-${component_dir}"
    systemctl start "serviceradar-${component_dir}"
fi

# Set required capability for ICMP scanning if this is the agent
if [ "${component_dir}" = "agent" ] && [ -x /usr/local/bin/serviceradar-agent ]; then
    setcap cap_net_raw=+ep /usr/local/bin/serviceradar-agent
fi
