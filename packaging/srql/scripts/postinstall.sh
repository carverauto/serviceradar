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

# Post-install script for ServiceRadar SRQL service
set -euo pipefail

# Ensure serviceradar group exists
if ! getent group serviceradar >/dev/null; then
    groupadd --system serviceradar
fi

# Ensure serviceradar user exists
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin -g serviceradar serviceradar
fi

# Ensure configuration and log directories exist
mkdir -p /etc/serviceradar
mkdir -p /var/log/serviceradar
chown serviceradar:serviceradar /var/log/serviceradar

# Harden SRQL environment file if present
if [ -f /etc/serviceradar/srql.env ]; then
    chown root:serviceradar /etc/serviceradar/srql.env
    chmod 640 /etc/serviceradar/srql.env
fi

# Ensure binary has correct permissions
if [ -x /usr/local/bin/serviceradar-srql ]; then
    chmod 755 /usr/local/bin/serviceradar-srql
fi

# Register service
systemctl daemon-reload
systemctl enable serviceradar-srql
if ! systemctl start serviceradar-srql; then
    echo "WARNING: Failed to start serviceradar-srql service automatically."
    echo "         Run 'journalctl -u serviceradar-srql.service' for details."
fi

# Restore SELinux contexts if SELinux is active
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -Rv /usr/local/bin/serviceradar-srql /etc/serviceradar 2>/dev/null || true
    fi
fi

exit 0
