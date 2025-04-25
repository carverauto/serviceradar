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

# Create serviceradar group if it doesn't exist
if ! getent group serviceradar >/dev/null; then
    groupadd --system serviceradar
fi

# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin -g serviceradar serviceradar
fi

# Create required directories
mkdir -p /var/lib/serviceradar
mkdir -p /etc/serviceradar

# Ensure api.env exists and has API_KEY and JWT_SECRET
if [ ! -f "/etc/serviceradar/api.env" ]; then
    echo "Generating new api.env with API_KEY and JWT_SECRET..."
    API_KEY=$(openssl rand -hex 32)
    JWT_SECRET=$(openssl rand -hex 32)
    echo "API_KEY=$API_KEY" > /etc/serviceradar/api.env
    echo "JWT_SECRET=$JWT_SECRET" >> /etc/serviceradar/api.env
    echo "AUTH_ENABLED=false" >> /etc/serviceradar/api.env
    chmod 640 /etc/serviceradar/api.env
    chown serviceradar:serviceradar /etc/serviceradar/api.env
    echo "New API key and JWT secret generated and stored in /etc/serviceradar/api.env"
else
    # Check if JWT_SECRET is missing and add it
    if ! grep -q "^JWT_SECRET=" /etc/serviceradar/api.env; then
        echo "Adding JWT_SECRET to existing api.env..."
        JWT_SECRET=$(openssl rand -hex 32)
        echo "JWT_SECRET=$JWT_SECRET" >> /etc/serviceradar/api.env
    else
        # Extract existing JWT_SECRET
        JWT_SECRET=$(grep "^JWT_SECRET=" /etc/serviceradar/api.env | cut -d'=' -f2)
    fi

    # Check if AUTH_ENABLED is missing and add it
    if ! grep -q "^AUTH_ENABLED=" /etc/serviceradar/api.env; then
        echo "Adding AUTH_ENABLED to existing api.env..."
        echo "AUTH_ENABLED=false" >> /etc/serviceradar/api.env
    fi
fi

# Update core.json with JWT_SECRET if it exists
if [ -f "/etc/serviceradar/core.json" ] && [ -n "$JWT_SECRET" ]; then
    # Check if core.json has auth section and update JWT_SECRET
    if grep -q '"auth":' /etc/serviceradar/core.json; then
        # Use temp file to avoid issues with in-place editing
        TEMP_FILE=$(mktemp)
        cat /etc/serviceradar/core.json |
            sed -E 's/"jwt_secret":[[:space:]]*"[^"]*"/"jwt_secret": "'"$JWT_SECRET"'"/' > "$TEMP_FILE"
        mv "$TEMP_FILE" /etc/serviceradar/core.json
        chown serviceradar:serviceradar /etc/serviceradar/core.json
        chmod 644 /etc/serviceradar/core.json
    fi
fi

# Set permissions
chown -R serviceradar:serviceradar /etc/serviceradar /var/lib/serviceradar
chmod 755 /usr/local/bin/serviceradar-core
[ -f /etc/serviceradar/core.json ] && chown serviceradar:serviceradar /etc/serviceradar/core.json
[ -f /etc/serviceradar/core.json ] && chmod 644 /etc/serviceradar/core.json
[ -f /etc/serviceradar/api.env ] && chmod 640 /etc/serviceradar/api.env

# Enable and start service
systemctl daemon-reload
systemctl enable serviceradar-core
systemctl restart serviceradar-core || {
    echo "Failed to start serviceradar-core service. Check logs with: journalctl -xeu serviceradar-core"
    exit 1
}

echo "ServiceRadar Core installed successfully!"