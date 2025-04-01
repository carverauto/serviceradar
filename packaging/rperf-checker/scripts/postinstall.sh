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

# Post-install script for ServiceRadar SNMP Checker
set -e

# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi

# Set up required directories
mkdir -p /var/lib/serviceradar
mkdir -p /etc/serviceradar/checkers

# Set proper ownership and permissions
chown -R serviceradar:serviceradar /etc/serviceradar/checkers
chown -R serviceradar:serviceradar /var/lib/serviceradar
chmod 755 /usr/local/bin/serviceradar-snmp-checker
chmod 644 /etc/serviceradar/checkers/snmp.json

# Enable and start the service
systemctl daemon-reload
systemctl enable serviceradar-snmp-checker
if ! systemctl start serviceradar-snmp-checker; then
    echo "WARNING: Failed to start serviceradar-snmp-checker service. Please check the logs."
    echo "Run: journalctl -u serviceradar-snmp-checker.service"
fi

# Configure SELinux if it's enabled
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
    echo "Configuring SELinux policies..."
    # Set correct context for binary
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -v /usr/local/bin/serviceradar-snmp-checker
    fi
fi

echo "ServiceRadar SNMP Checker installed successfully!"