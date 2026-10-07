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
mkdir -p /usr/lib/serviceradar/addons
chmod 755 /usr/lib/serviceradar/addons
chown root:root /usr/lib/serviceradar/addons
# Endpoint-inventory state dirs: the agent writes its runtime profile here as the
# serviceradar user. Create and own this subtree explicitly so a stale root-owned
# directory cannot permanently defer the config-version ack (fj #4301).
mkdir -p /var/lib/serviceradar/endpoint-inventory/profile
mkdir -p /var/lib/serviceradar/endpoint-inventory/spool
mkdir -p /var/lib/serviceradar/endpoint-inventory/cache
mkdir -p /var/lib/serviceradar/endpoint-inventory/tmp
mkdir -p /etc/serviceradar/sidecars


# Create checkers/sweep directory if it doesnt already exist
mkdir -p /etc/serviceradar/checkers/sweep

# Set permissions
if [ -f /etc/serviceradar/agent.json ]; then
    chown serviceradar:serviceradar /etc/serviceradar/agent.json
fi
chown -R serviceradar:serviceradar /etc/serviceradar/checkers
chown -R serviceradar:serviceradar /etc/serviceradar/sidecars
# Do not recursively chown the shared state root. Native add-ons keep root-owned
# state below it and may intentionally drop CAP_DAC_OVERRIDE; taking ownership of
# those directories while the add-on remains running makes its next write fail.
chown serviceradar:serviceradar /var/lib/serviceradar
chown -R serviceradar:serviceradar /var/lib/serviceradar/cache
chown -R serviceradar:serviceradar /var/lib/serviceradar/endpoint-inventory
chmod 755 /etc/serviceradar/
chmod 750 /etc/serviceradar/sidecars
chmod 755 /var/lib/serviceradar
chmod 755 /var/lib/serviceradar/cache
chmod 750 /var/lib/serviceradar/endpoint-inventory

if [ -x /usr/local/bin/serviceradar-agent-updater ]; then
    chown root:serviceradar /usr/local/bin/serviceradar-agent-updater
    chmod 4750 /usr/local/bin/serviceradar-agent-updater
fi

# Privileged add-on binaries live under /usr/lib/serviceradar/addons. Without a
# persistent bin_t fcontext, a later restorecon resets them to usr_t/lib_t and
# systemd exec fails with status=203/EXEC. Register the legacy staging context
# for compatibility, but never mutate that service-writable tree as root.
# Idempotent: skip add if the fcontext already exists.
if command -v semanage >/dev/null 2>&1; then
    if ! semanage fcontext -l 2>/dev/null | grep -F '/usr/lib/serviceradar/addons' >/dev/null 2>&1; then
        semanage fcontext -a -t bin_t '/usr/lib/serviceradar/addons(/.*)?' || true
    fi
    if ! semanage fcontext -l 2>/dev/null | grep -F '/var/lib/serviceradar/agent/addons' >/dev/null 2>&1; then
        semanage fcontext -a -t bin_t '/var/lib/serviceradar/agent/addons(/.*)?' || true
    fi
fi
if command -v restorecon >/dev/null 2>&1; then
    restorecon -Rv /usr/lib/serviceradar/addons >/dev/null 2>&1 || true
fi

# netprobe is no longer shipped by the base agent package: its binary and the
# cap_net_raw,cap_bpf,cap_perfmon setcap step moved into the netprobe add-on
# delivery path (migrate-netprobe-to-native-addon §1.4). The root-owned
# setuid agent-updater applies those file capabilities to the privileged
# add-on binary per the add-on assignment's os_capabilities, not here.

# The service runs build/packaging/agent/bin/serviceradar-agent as the
# serviceradar user. That launcher validates the root-owned package seed, then
# initializes or refreshes the writable runtime and current link without a
# privileged process following paths controlled by the service account.

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
    echo "Skipping serviceradar-agent start: enrollment assets not found. Run srctl enroll, then: systemctl restart serviceradar-agent"
fi
