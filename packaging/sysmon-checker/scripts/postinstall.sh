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

# Setup user and directories
setup_user_and_dirs() {
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
}

# Detect ZFS availability
detect_zfs() {
    if command -v zfs >/dev/null && (dpkg -l zfsutils-linux >/dev/null 2>&1 || command -v zpool >/dev/null); then
        echo "ZFS detected, using ZFS-enabled binary"
        return 0
    else
        echo "Using non-ZFS binary"
        return 1
    fi
}

# Copy appropriate binary
setup_binary() {
    local zfs_available=$1

    if [ "$zfs_available" = "true" ] && [ -f /usr/local/bin/serviceradar-sysmon-checker-zfs ]; then
        cp /usr/local/bin/serviceradar-sysmon-checker-zfs /usr/local/bin/serviceradar-sysmon-checker
    elif [ -f /usr/local/bin/serviceradar-sysmon-checker-nonzfs ]; then
        cp /usr/local/bin/serviceradar-sysmon-checker-nonzfs /usr/local/bin/serviceradar-sysmon-checker
    else
        echo "Warning: Required binaries not found, package may be incomplete"
        return 1
    fi

    return 0
}

# Configure sysmon.json
configure_json() {
    local zfs_available=$1

    # If config doesn't exist yet, create it
    if [ ! -f /etc/serviceradar/checkers/sysmon.json ]; then
        if [ "$zfs_available" = "true" ]; then
            # Get ZFS pools
            ZFS_POOLS=$(zfs list -H -o name 2>/dev/null | grep -v "/" | tr '\n' ' ')
            if [ -n "$ZFS_POOLS" ]; then
                # Create pools JSON array
                POOLS_JSON=$(echo "$ZFS_POOLS" | awk '{printf "[\"%s\"]", $1}' | sed 's/ /","/g')

                # Copy from example first to ensure proper format
                cp /etc/serviceradar/checkers/sysmon.json.example /etc/serviceradar/checkers/sysmon.json

                # Update ZFS configuration with detected pools
                sed -i 's/"zfs":[^,]*,/"zfs": {\
        "enabled": true,\
        "pools": '"$POOLS_JSON"',\
        "include_datasets": true,\
        "use_libzetta": true\
    },/g' /etc/serviceradar/checkers/sysmon.json
            else
                # No pools found, use example config
                cp /etc/serviceradar/checkers/sysmon.json.example /etc/serviceradar/checkers/sysmon.json
            fi
        else
            # No ZFS available, use example config
            cp /etc/serviceradar/checkers/sysmon.json.example /etc/serviceradar/checkers/sysmon.json

            # Ensure ZFS is explicitly disabled
            sed -i 's/"zfs":[^,]*,/"zfs": null,/g' /etc/serviceradar/checkers/sysmon.json
        fi
    fi
}

# Set permissions and start service
finalize_installation() {
    # Set permissions
    chown -R serviceradar:serviceradar /etc/serviceradar/checkers
    chown -R serviceradar:serviceradar /var/lib/serviceradar
    chmod 755 /usr/local/bin/serviceradar-sysmon-checker
    chmod 644 /etc/serviceradar/checkers/sysmon.json

    # Enable and start the service
    systemctl daemon-reload
    systemctl enable serviceradar-sysmon-checker
    if ! systemctl start serviceradar-sysmon-checker; then
        echo "WARNING: Failed to start serviceradar-sysmon-checker service."
        echo "Check logs with: journalctl -u serviceradar-sysmon-checker.service"
        return 1
    fi

    return 0
}

# Main installation process
main() {
    setup_user_and_dirs

    # Detect ZFS
    if detect_zfs; then
        ZFS_AVAILABLE="true"
    else
        ZFS_AVAILABLE="false"
    fi

    # Setup binary based on ZFS availability
    setup_binary "$ZFS_AVAILABLE"

    # Configure JSON file
    configure_json "$ZFS_AVAILABLE"

    # Finalize installation
    finalize_installation

    echo "ServiceRadar SysMon Checker installed successfully!"
}

# Run the main function
main