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

set -e

# Default config path
CONFIG_PATH="${CONFIG_PATH:-/etc/serviceradar/core.json}"

# Load environment variables from api.env if it exists
if [ -f "/etc/serviceradar/api.env" ]; then
    echo "Loading environment from /etc/serviceradar/api.env"
    set -a
    source /etc/serviceradar/api.env
    set +a
fi

# Override with Docker environment variables if set
export API_KEY="${API_KEY:-changeme}"
export JWT_SECRET="${JWT_SECRET:-changeme}"
export AUTH_ENABLED="${AUTH_ENABLED:-true}"

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
    PROTON_ADDR="${PROTON_HOST:-proton}:${PROTON_PORT:-8123}"
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

# Execute the main command
exec "$@" --config "$CONFIG_PATH"