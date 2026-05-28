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
mkdir -p /var/lib/serviceradar/agent/versions
mkdir -p /var/lib/serviceradar/agent/tmp


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
chmod 755 /var/lib/serviceradar/agent
chmod 755 /var/lib/serviceradar/agent/versions
chmod 755 /var/lib/serviceradar/agent/tmp

# Root-owned Bumblebee scanner state. The scanner runs as root with group
# serviceradar so the non-root agent can read sanitized spool files only.
mkdir -p /var/lib/serviceradar/bumblebee/catalog
mkdir -p /var/lib/serviceradar/bumblebee/cache
mkdir -p /var/lib/serviceradar/bumblebee/spool/runs
mkdir -p /var/lib/serviceradar/bumblebee/tmp
chown -R root:serviceradar /var/lib/serviceradar/bumblebee
chmod 750 /var/lib/serviceradar/bumblebee
chmod 750 /var/lib/serviceradar/bumblebee/cache
chmod 750 /var/lib/serviceradar/bumblebee/catalog
chmod 750 /var/lib/serviceradar/bumblebee/spool
chmod 750 /var/lib/serviceradar/bumblebee/spool/runs
chmod 750 /var/lib/serviceradar/bumblebee/tmp
if [ -f /etc/serviceradar/bumblebee-scan.json ]; then
    chown root:serviceradar /etc/serviceradar/bumblebee-scan.json
    chmod 0640 /etc/serviceradar/bumblebee-scan.json
fi
if [ -x /usr/local/lib/serviceradar/bin/serviceradar-bumblebee-scan ]; then
    chown root:root /usr/local/lib/serviceradar/bin/serviceradar-bumblebee-scan
    chmod 0755 /usr/local/lib/serviceradar/bin/serviceradar-bumblebee-scan
fi

NETPROBE_BIN=/usr/local/lib/serviceradar/bin/serviceradar-netprobe
warn_netprobe_capability() {
    echo "Warning: $1; run:"
    echo "  sudo setcap cap_net_raw=+ep $NETPROBE_BIN"
}

if [ -x "$NETPROBE_BIN" ]; then
    chown serviceradar:serviceradar "$NETPROBE_BIN"
    chmod 0755 "$NETPROBE_BIN"
    if command -v setcap >/dev/null 2>&1; then
        setcap cap_net_raw=+ep "$NETPROBE_BIN" || warn_netprobe_capability "failed to set cap_net_raw capability on $NETPROBE_BIN"
    else
        warn_netprobe_capability "setcap not found; install libcap tools"
    fi
fi

# Refresh the package-provided seed runtime on every install, but leave the
# active current symlink alone unless it has never been initialized.
if [ -x /usr/local/lib/serviceradar/agent/serviceradar-agent-seed ]; then
    mkdir -p /var/lib/serviceradar/agent/versions/seed-installed
    cp /usr/local/lib/serviceradar/agent/serviceradar-agent-seed /var/lib/serviceradar/agent/versions/seed-installed/serviceradar-agent.new
    chmod 0755 /var/lib/serviceradar/agent/versions/seed-installed/serviceradar-agent.new
    chown serviceradar:serviceradar /var/lib/serviceradar/agent/versions/seed-installed/serviceradar-agent.new
    mv -Tf /var/lib/serviceradar/agent/versions/seed-installed/serviceradar-agent.new /var/lib/serviceradar/agent/versions/seed-installed/serviceradar-agent
    chown serviceradar:serviceradar /var/lib/serviceradar/agent/versions/seed-installed/serviceradar-agent
fi

if [ ! -e /var/lib/serviceradar/agent/current ]; then
    ln -sfn versions/seed-installed /var/lib/serviceradar/agent/current
fi

# Reload systemd and manage service
systemctl daemon-reload
if [ -f /lib/systemd/system/serviceradar-bumblebee-scan.timer ]; then
    systemctl enable serviceradar-bumblebee-scan.timer || true
    systemctl start serviceradar-bumblebee-scan.timer || true
fi
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
