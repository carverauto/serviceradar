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

# postinstall.sh - Post-installation script for serviceradar-core

set -e

# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi

# Create required directories
mkdir -p /var/lib/serviceradar
mkdir -p /etc/serviceradar

# Set permissions
chown -R serviceradar:serviceradar /etc/serviceradar /var/lib/serviceradar
chmod 755 /usr/local/bin/serviceradar-core
chmod 644 /etc/serviceradar/core.json
[ -f /etc/serviceradar/api.env ] && chmod 600 /etc/serviceradar/api.env

# Enable and start service
systemctl daemon-reload
systemctl enable serviceradar-core
systemctl start serviceradar-core || {
    echo "Failed to start serviceradar-core service. Check logs with: journalctl -xeu serviceradar-core"
    exit 1
}

echo "ServiceRadar Core installed successfully!"
