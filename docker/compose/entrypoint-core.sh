#!/usr/bin/env bash
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

set -e

resolve_service_host() {
    service_name="$1"
    override_name="$2"
    docker_default="$3"
    override_value=$(eval "printf '%s' \"\${${override_name}:-}\"")
    if [ -n "$override_value" ]; then
        printf '%s' "$override_value"
        return
    fi
    if [ -n "${KUBERNETES_SERVICE_HOST:-}" ]; then
        printf '%s' "$service_name"
        return
    fi
    printf '%s' "$docker_default"
}

resolve_service_port() {
    override_name="$1"
    default_value="$2"
    override_value=$(eval "printf '%s' \"\${${override_name}:-}\"")
    if [ -n "$override_value" ]; then
        printf '%s' "$override_value"
        return
    fi
    printf '%s' "$default_value"
}

export PATH="/usr/local/bin:${PATH}"

# Ensure expected directories exist even on minimal base images.
mkdir -p /etc/serviceradar /var/log/serviceradar /var/lib/serviceradar /data

# Default config path
CONFIG_PATH="${CONFIG_PATH:-/etc/serviceradar/core.json}"

# Load environment variables from api.env if it exists (check generated config first)
if [ -f "/etc/serviceradar/config/api.env" ]; then
    echo "Loading environment from /etc/serviceradar/config/api.env (generated)"
    set -a
    source /etc/serviceradar/config/api.env
    set +a
    echo "✅ Loaded generated secrets (API_KEY length: ${#API_KEY})"
elif [ -f "/etc/serviceradar/api.env" ]; then
    echo "Loading environment from /etc/serviceradar/api.env"
    set -a
    source /etc/serviceradar/api.env
    set +a
    echo "✅ Loaded environment from api.env"
fi

# Set defaults only if not already set from environment files
export API_KEY="${API_KEY:-changeme}"
export JWT_SECRET="${JWT_SECRET:-changeme}"
export AUTH_ENABLED="${AUTH_ENABLED:-true}"

echo "🔑 Using API_KEY: ${API_KEY:0:8}... (${#API_KEY} chars)"
echo "🔐 Using JWT_SECRET: ${JWT_SECRET:0:8}... (${#JWT_SECRET} chars)"

# Check that config file exists
if [ ! -f "$CONFIG_PATH" ]; then
    echo "ERROR: Configuration file not found at $CONFIG_PATH"
    echo "Please mount the config file from packaging/core/config/core.json"
    exit 1
fi

echo "Using configuration from $CONFIG_PATH"

# Check for Proton password in shared credentials volume
if [ -f "/etc/serviceradar/credentials/proton-password" ]; then
    PROTON_PASSWORD=$(cat /etc/serviceradar/credentials/proton-password)
    echo "Found Proton password from shared credentials"
fi

# If PROTON_PASSWORD is available, update the config file
if [ -n "$PROTON_PASSWORD" ] && [ -f "$CONFIG_PATH" ]; then
    echo "Updating configuration with Proton password..."
    # Create a copy of the config with the password injected
    cp "$CONFIG_PATH" /tmp/core-original.json
    jq --arg pwd "$PROTON_PASSWORD" '.database.password = $pwd' /tmp/core-original.json > /tmp/core.json
    CONFIG_PATH="/tmp/core.json"
fi

# Wait for Proton to be ready if configured
if [ -n "$WAIT_FOR_PROTON" ]; then
    PROTON_HOST_VALUE=$(resolve_service_host "serviceradar-proton" PROTON_HOST "proton")
    PROTON_PORT_VALUE=$(resolve_service_port PROTON_PORT "8123")
    PROTON_ADDR="${PROTON_HOST_VALUE}:${PROTON_PORT_VALUE}"
    echo "Waiting for Proton at $PROTON_ADDR..."
    
    for i in {1..30}; do
        # Try connectivity with authentication if password is set
        if [ -n "$PROTON_PASSWORD" ]; then
            if curl -sf "http://default:${PROTON_PASSWORD}@$PROTON_ADDR/?query=SELECT%201" > /dev/null 2>&1; then
                echo "Proton is ready on HTTP port!"
                break
            fi
        else
            if curl -sf "http://$PROTON_ADDR/?query=SELECT%201" > /dev/null 2>&1; then
                echo "Proton is ready on HTTP port!"
                break
            fi
        fi
        echo "Waiting for Proton... ($i/30)"
        sleep 2
    done
fi

# Initialize database tables if needed
if [ "$INIT_DB" = "true" ]; then
    echo "Initializing database tables..."
    # TODO: Add database initialization logic here
fi

# Final environment check before starting core service
echo "🔍 Final environment check:"
echo "  API_KEY: ${API_KEY:0:8}... (${#API_KEY} chars)"
echo "  JWT_SECRET: ${JWT_SECRET:0:8}... (${#JWT_SECRET} chars)"
echo "  AUTH_ENABLED: $AUTH_ENABLED"

# Execute the main command
exec "$@" --config "$CONFIG_PATH"
