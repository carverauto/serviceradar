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

# Post-install script for ServiceRadar trapd Server
set -e

# Create serviceradar group if it doesn't exist
if ! getent group serviceradar >/dev/null; then
    groupadd --system serviceradar
fi

# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin -g serviceradar serviceradar
fi

mkdir -p /var/log/serviceradar
chown serviceradar:serviceradar /var/log/serviceradar

# Set proper ownership and permissions
chmod 755 /usr/local/bin/serviceradar-trapd
chmod 644 /etc/serviceradar/trapd.json

# Set required capability for to listen for SNMP traps
if [ -x /usr/local/bin/serviceradar-trapd ]; then
    setcap cap_net_raw=+ep /usr/local/bin/serviceradar-trapd || {
        echo "Warning: Failed to set cap_net_raw capability on /usr/local/bin/serviceradar-trapd"
        echo "  sudo setcap cap_net_raw=+ep /usr/local/bin/serviceradar-trapd"
    }
fi

# Enable and start the service
systemctl daemon-reload
systemctl enable serviceradar-trapd
if ! systemctl start serviceradar-trapd; then
    echo "WARNING: Failed to start serviceradar-trapd service. Please check the logs."
    echo "Run: journalctl -u serviceradar-trapd.service"
fi

# Configure SELinux if it's enabled
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
    echo "Configuring SELinux policies..."
    # Set correct context for binary
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -v /usr/local/bin/serviceradar-trapd
    fi
fi

echo "ServiceRadar trapd Server installed successfully!"