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

# Post-install script for ServiceRadar Log Collector
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
chmod 755 /usr/local/bin/serviceradar-log-collector
chmod 644 /etc/serviceradar/log-collector.toml
chown serviceradar:serviceradar /usr/local/bin/serviceradar-log-collector
chown serviceradar:serviceradar /etc/serviceradar/log-collector.toml

# Set required capability for binding to privileged ports (514/udp)
if [ -x /usr/local/bin/serviceradar-log-collector ]; then
    setcap cap_net_bind_service=+ep /usr/local/bin/serviceradar-log-collector || {
        echo "Warning: Failed to set cap_net_bind_service capability on /usr/local/bin/serviceradar-log-collector"
        echo "  sudo setcap cap_net_bind_service=+ep /usr/local/bin/serviceradar-log-collector"
    }
fi

# Enable and start the service
systemctl daemon-reload
systemctl enable serviceradar-log-collector
if ! systemctl start serviceradar-log-collector; then
    echo "WARNING: Failed to start serviceradar-log-collector service. Please check the logs."
    echo "Run: journalctl -u serviceradar-log-collector.service"
fi

# Configure SELinux if it's enabled
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
    echo "Configuring SELinux policies..."
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -v /usr/local/bin/serviceradar-log-collector
    fi
fi

echo "ServiceRadar Log Collector installed successfully!"
