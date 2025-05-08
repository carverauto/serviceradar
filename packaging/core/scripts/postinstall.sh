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

# Ensure certificate directory permissions
if [ -d "/etc/serviceradar/certs" ]; then
    chown -R serviceradar:serviceradar /etc/serviceradar/certs
    chmod -R 640 /etc/serviceradar/certs/*.pem
fi

# Ensure api.env exists and has valid API_KEY and JWT_SECRET values
if [ ! -f "/etc/serviceradar/api.env" ]; then
    echo "Generating new api.env with API_KEY and JWT_SECRET..."
    API_KEY=$(openssl rand -hex 32)
    JWT_SECRET=$(openssl rand -hex 32)
    echo "API_KEY=$API_KEY" > /etc/serviceradar/api.env
    echo "JWT_SECRET=$JWT_SECRET" >> /etc/serviceradar/api.env
    echo "AUTH_ENABLED=false" >> /etc/serviceradar/api.env
    echo "NEXT_PUBLIC_API_URL=http://localhost:8090" >> /etc/serviceradar/api.env
    chmod 640 /etc/serviceradar/api.env
    chown serviceradar:serviceradar /etc/serviceradar/api.env
    echo "New API key and JWT secret generated and stored in /etc/serviceradar/api.env"
else
    # Check if API_KEY is missing or set to 'changeme'
    if ! grep -q "^API_KEY=" /etc/serviceradar/api.env || grep -q "^API_KEY=changeme$" /etc/serviceradar/api.env; then
        echo "Updating API_KEY in existing api.env..."
        API_KEY=$(openssl rand -hex 32)
        # Replace the existing API_KEY line or add a new one
        if grep -q "^API_KEY=" /etc/serviceradar/api.env; then
            sed -i "s/^API_KEY=.*$/API_KEY=$API_KEY/" /etc/serviceradar/api.env
        else
            echo "API_KEY=$API_KEY" >> /etc/serviceradar/api.env
        fi
        echo "Generated and stored new API key in /etc/serviceradar/api.env"
    else
        # Extract existing API_KEY
        API_KEY=$(grep "^API_KEY=" /etc/serviceradar/api.env | cut -d'=' -f2)
    fi

    # Check if JWT_SECRET is missing or set to 'changeme'
    if ! grep -q "^JWT_SECRET=" /etc/serviceradar/api.env || grep -q "^JWT_SECRET=changeme$" /etc/serviceradar/api.env; then
        echo "Updating JWT_SECRET in existing api.env..."
        JWT_SECRET=$(openssl rand -hex 32)
        # Replace the existing JWT_SECRET line or add a new one
        if grep -q "^JWT_SECRET=" /etc/serviceradar/api.env; then
            sed -i "s/^JWT_SECRET=.*$/JWT_SECRET=$JWT_SECRET/" /etc/serviceradar/api.env
        else
            echo "JWT_SECRET=$JWT_SECRET" >> /etc/serviceradar/api.env
        fi
        echo "Generated and stored new JWT secret in /etc/serviceradar/api.env"
    else
        # Extract existing JWT_SECRET
        JWT_SECRET=$(grep "^JWT_SECRET=" /etc/serviceradar/api.env | cut -d'=' -f2)
    fi

    # Check if AUTH_ENABLED is missing
    if ! grep -q "^AUTH_ENABLED=" /etc/serviceradar/api.env; then
        echo "Adding AUTH_ENABLED to existing api.env..."
        echo "AUTH_ENABLED=false" >> /etc/serviceradar/api.env
    fi

    # Ensure NEXT_PUBLIC_API_URL is present
    if ! grep -q "^NEXT_PUBLIC_API_URL=" /etc/serviceradar/api.env; then
        echo "Adding NEXT_PUBLIC_API_URL to existing api.env..."
        echo "NEXT_PUBLIC_API_URL=http://localhost:8090" >> /etc/serviceradar/api.env
    fi

    # Update permissions
    chmod 640 /etc/serviceradar/api.env
    chown serviceradar:serviceradar /etc/serviceradar/api.env
fi

# Update core.json with JWT_SECRET if it exists
if [ -f "/etc/serviceradar/core.json" ] && [ -n "$JWT_SECRET" ]; then
    # Check if core.json has auth section and a jwt_secret field
    if grep -q '"auth":' /etc/serviceradar/core.json; then
        # Check if the jwt_secret is set to the placeholder value or needs updating
        if grep -q '"jwt_secret":[[:space:]]*"changeme"' /etc/serviceradar/core.json || \
           grep -q '"jwt_secret":[[:space:]]*""' /etc/serviceradar/core.json; then
            echo "Updating JWT_SECRET in core.json with the value from api.env..."
            TEMP_FILE=$(mktemp)
            # Use --arg to safely pass JWT_SECRET to jq
            jq --arg secret "$JWT_SECRET" '.auth.jwt_secret = $secret' /etc/serviceradar/core.json > "$TEMP_FILE"
            mv "$TEMP_FILE" /etc/serviceradar/core.json
            echo "Updated JWT_SECRET in core.json"
        else
            # If jwt_secret exists but doesn't match the one in api.env, synchronize them
            CORE_JWT=$(jq -r '.auth.jwt_secret' /etc/serviceradar/core.json)
            if [ "$CORE_JWT" != "$JWT_SECRET" ]; then
                echo "Synchronizing JWT_SECRET in core.json with api.env..."
                TEMP_FILE=$(mktemp)
                # Use --arg to safely pass JWT_SECRET to jq
                jq --arg secret "$JWT_SECRET" '.auth.jwt_secret = $secret' /etc/serviceradar/core.json > "$TEMP_FILE"
                mv "$TEMP_FILE" /etc/serviceradar/core.json
                echo "Synchronized JWT_SECRET between core.json and api.env"
            fi
        fi

        # Make sure ownership and permissions are correct
        chown serviceradar:serviceradar /etc/serviceradar/core.json
        chmod 644 /etc/serviceradar/core.json
    else
        # If there's no auth section, add one with the JWT_SECRET
        echo "Adding auth section with JWT_SECRET to core.json..."
        TEMP_FILE=$(mktemp)
        # Use --arg to safely pass JWT_SECRET to jq
        jq --arg secret "$JWT_SECRET" '. + {auth: {jwt_secret: $secret, local_users: {}}}' /etc/serviceradar/core.json > "$TEMP_FILE"
        mv "$TEMP_FILE" /etc/serviceradar/core.json
        chown serviceradar:serviceradar /etc/serviceradar/core.json
        chmod 644 /etc/serviceradar/core.json
        echo "Added auth section with JWT_SECRET to core.json"
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

# Only restart web if it's installed
if systemctl list-unit-files | grep -q serviceradar-web.service; then
    echo "Restarting serviceradar-web service..."
    systemctl restart serviceradar-web || {
        echo "Failed to start serviceradar-web service. Check logs with: journalctl -xeu serviceradar-web"
    }
fi

# Only restart nginx if it's installed
if command -v nginx >/dev/null && systemctl list-unit-files | grep -q nginx.service; then
    echo "Restarting nginx service..."
    systemctl restart nginx || {
        echo "Failed to restart nginx. Check logs with: journalctl -xeu nginx"
    }
fi

echo "ServiceRadar Core installed successfully!"