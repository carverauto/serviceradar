#!/bin/bash

# Copyright 2025 Carver Automation Corporation.
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

# Post-install script for ServiceRadar NetFlow Collector
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
mkdir -p /var/lib/serviceradar
chown serviceradar:serviceradar /var/log/serviceradar
chown serviceradar:serviceradar /var/lib/serviceradar

# Set proper ownership and permissions
chmod 755 /usr/local/bin/serviceradar-netflow-collector
chmod 644 /etc/serviceradar/netflow-collector.json
chown serviceradar:serviceradar /usr/local/bin/serviceradar-netflow-collector
chown serviceradar:serviceradar /etc/serviceradar/netflow-collector.json

# Set required capability for binding to privileged ports if configured
if [ -x /usr/local/bin/serviceradar-netflow-collector ]; then
    setcap cap_net_bind_service=+ep /usr/local/bin/serviceradar-netflow-collector || {
        echo "Warning: Failed to set cap_net_bind_service on /usr/local/bin/serviceradar-netflow-collector"
        echo "  sudo setcap cap_net_bind_service=+ep /usr/local/bin/serviceradar-netflow-collector"
    }
fi

# Enable and start the service
systemctl daemon-reload
systemctl enable serviceradar-netflow-collector
if ! systemctl start serviceradar-netflow-collector; then
    echo "WARNING: Failed to start serviceradar-netflow-collector service. Please check the logs."
    echo "Run: journalctl -u serviceradar-netflow-collector.service"
fi

# Configure SELinux if it's enabled
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
    echo "Configuring SELinux policies..."
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -v /usr/local/bin/serviceradar-netflow-collector
    fi
fi

echo "ServiceRadar NetFlow Collector installed successfully!"
