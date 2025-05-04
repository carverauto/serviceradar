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

# Post-install script for TimePlus Proton Server
set -e

# Create proton group if it doesn't exist
if ! getent group proton >/dev/null; then
    groupadd --system proton
fi

# Create proton user if it doesn't exist
if ! id -u proton >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin -g proton proton
fi

# Set up required directories
mkdir -p /var/lib/proton
mkdir -p /etc/proton-server/

# Set proper ownership and permissions
chown -R proton:proton /etc/proton-server
chown -R proton:proton /var/lib/proton
chmod 755 /usr/bin/proton
chmod 644 /etc/proton-server/config.yaml
chmod 644 /etc/proton-server/users.yaml

# Enable and start the service
systemctl daemon-reload
systemctl enable serviceradar-proton
if ! systemctl start serviceradar-proton; then
    echo "WARNING: Failed to start serviceradar-proton service. Please check the logs."
    echo "Run: journalctl -u serviceradar-proton.service"
fi

# Configure SELinux if it's enabled
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
    echo "Configuring SELinux policies..."
    # Set correct context for binary
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -v /usr/bin/proton
    fi
fi

echo "ServiceRadar Proton Server installed successfully!"