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

# Pre-removal script for ServiceRadar Web package
set -e

# Stop and disable the web service
if systemctl is-active --quiet serviceradar-web; then
    echo "Stopping serviceradar-web service..."
    systemctl stop serviceradar-web
fi

if systemctl is-enabled --quiet serviceradar-web; then
    echo "Disabling serviceradar-web service..."
    systemctl disable serviceradar-web
fi

# Remove nginx configuration if present
if [ -f /etc/nginx/sites-enabled/serviceradar-web.conf ]; then
    echo "Removing Nginx symlink..."
    rm -f /etc/nginx/sites-enabled/serviceradar-web.conf
fi

# Reload Nginx if running
if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
    echo "Reloading Nginx configuration..."
    systemctl reload nginx || true
fi

# Remove firewall configuration if firewalld is running
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    # Only remove if no other services need HTTP
    REMAINING_HTTP=$(firewall-cmd --list-services | grep -o "http" | wc -l)
    if [ "$REMAINING_HTTP" -eq 1 ]; then
        echo "Removing HTTP from firewall..."
        firewall-cmd --permanent --remove-service=http
        firewall-cmd --reload
    fi
fi

echo "Pre-removal cleanup completed."