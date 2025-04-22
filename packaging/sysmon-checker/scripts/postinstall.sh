#!/bin/bash
# Copyright 2023 Carver Automation Corporation.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Post-install script for ServiceRadar SysMon Checker
set -e

# Create serviceradar group if it doesn't exist
if ! getent group serviceradar >/dev/null; then
    groupadd --system serviceradar
fi

# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin -g serviceradar serviceradar
fi

# Set up required directories
mkdir -p /var/lib/serviceradar
mkdir -p /etc/serviceradar/checkers

# Check for ZFS availability
ZFS_AVAILABLE=false
if command -v zfs >/dev/null && (dpkg -l zfsutils-linux >/dev/null 2>&1 || command -v zpool >/dev/null); then
    ZFS_AVAILABLE=true
    # For Debian/Ubuntu, try to install ZFS utils if not present
    if [ -f /etc/debian_version ] && ! dpkg -l zfsutils-linux >/dev/null 2>&1; then
        echo "ZFS detected, installing zfsutils-linux if not present"
        apt-get update && apt-get install -y zfsutils-linux || true
    fi
fi

# Copy appropriate binary if both exist
if [ "$ZFS_AVAILABLE" = "true" ] && [ -f /usr/local/bin/serviceradar-sysmon-checker-zfs ]; then
    cp /usr/local/bin/serviceradar-sysmon-checker-zfs /usr/local/bin/serviceradar-sysmon-checker
    echo "Using ZFS-enabled binary"
else
    if [ -f /usr/local/bin/serviceradar-sysmon-checker-nonzfs ]; then
        cp /usr/local/bin/serviceradar-sysmon-checker-nonzfs /usr/local/bin/serviceradar-sysmon-checker
        echo "Using non-ZFS binary"
    else
        echo "Warning: Neither ZFS nor non-ZFS binary found, package may be incomplete"
    fi
fi

# Configure sysmon.json
if [ ! -f /etc/serviceradar/checkers/sysmon.json ]; then
    if [ "$ZFS_AVAILABLE" = "true" ]; then
        ZFS_POOLS=$(zfs list -H -o name 2>/dev/null | grep -v "/" | tr '\n' ' ')
        if [ -n "$ZFS_POOLS" ]; then
            POOLS_JSON=$(echo "$ZFS_POOLS" | awk '{printf "[\"%s\"]", $1}' | sed 's/ /","/g')
            cat > /etc/serviceradar/checkers/sysmon.json << EOF
{
    "listen_addr": "0.0.0.0:50060",
    "security": {"tls_enabled": false},
    "poll_interval": 30,
    "zfs": {
        "enabled": true,
        "pools": $POOLS_JSON,
        "include_datasets": true,
        "use_libzetta": true
    },
    "filesystems": [{"name": "/", "type": "ext4", "monitor": true}]
}
EOF
        else
            # Fall back to non-ZFS config if no pools found
            cp /etc/serviceradar/checkers/sysmon.json.example /etc/serviceradar/checkers/sysmon.json
        fi
    else
        # Use example config for non-ZFS systems
        cp /etc/serviceradar/checkers/sysmon.json.example /etc/serviceradar/checkers/sysmon.json
    fi
    chmod 644 /etc/serviceradar/checkers/sysmon.json
fi

# Set permissions
chown -R serviceradar:serviceradar /etc/serviceradar/checkers
chown -R serviceradar:serviceradar /var/lib/serviceradar
chmod 755 /usr/local/bin/serviceradar-sysmon-checker

# Enable and start the service
systemctl daemon-reload
systemctl enable serviceradar-sysmon-checker
if ! systemctl start serviceradar-sysmon-checker; then
    echo "WARNING: Failed to start serviceradar-sysmon-checker service. Please check the logs."
    echo "Run: journalctl -u serviceradar-sysmon-checker.service"
fi

echo "ServiceRadar SysMon Checker installed successfully!"