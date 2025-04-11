#!/bin/sh
set -e

# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi

# Create required directories
mkdir -p /etc/serviceradar
mkdir -p /var/lib/serviceradar


# Create checkers/sweep directory if it doesnt already exist
mkdir -p /etc/serviceradar/checkers/sweep

# Set permissions
chown serviceradar:serviceradar /etc/serviceradar/agent.json
chown -R serviceradar:serviceradar /etc/serviceradar/checkers
chmod 755 /etc/serviceradar/

# Set required capability for ICMP scanning
if [ -x /usr/local/bin/serviceradar-agent ]; then
    setcap cap_net_raw=+ep /usr/local/bin/serviceradar-agent || {
        echo "Warning: Failed to set cap_net_raw capability on /usr/local/bin/serviceradar-agent"
        echo "ICMP scanning will not work without this capability. Ensure libcap2-bin is installed and run:"
        echo "  sudo setcap cap_net_raw=+ep /usr/local/bin/serviceradar-agent"
    }
fi

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
