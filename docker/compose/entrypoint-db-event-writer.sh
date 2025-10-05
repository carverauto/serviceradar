#!/bin/sh
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

# Helper to resolve service hosts depending on the environment (Docker vs. Kubernetes)
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

# Wait for dependencies to be ready
if [ -n "${WAIT_FOR_NATS:-}" ]; then
    NATS_HOST_VALUE=$(resolve_service_host "serviceradar-nats" NATS_HOST "nats")
    NATS_PORT_VALUE=$(resolve_service_port NATS_PORT "4222")
    echo "Waiting for NATS service at ${NATS_HOST_VALUE}:${NATS_PORT_VALUE}..."

    if wait-for-port \
        --host "${NATS_HOST_VALUE}" \
        --port "${NATS_PORT_VALUE}" \
        --attempts 30 \
        --interval 2s \
        --quiet; then
        echo "NATS service is ready!"
    else
        echo "ERROR: Timed out waiting for NATS at ${NATS_HOST_VALUE}:${NATS_PORT_VALUE}" >&2
        exit 1
    fi
fi

if [ -n "${WAIT_FOR_PROTON:-}" ]; then
    PROTON_HOST_VALUE=$(resolve_service_host "serviceradar-proton" PROTON_HOST "proton")
    PROTON_PORT_VALUE=$(resolve_service_port PROTON_PORT "9440")
    echo "Waiting for Proton database at ${PROTON_HOST_VALUE}:${PROTON_PORT_VALUE}..."

    if wait-for-port \
        --host "${PROTON_HOST_VALUE}" \
        --port "${PROTON_PORT_VALUE}" \
        --attempts 30 \
        --interval 2s \
        --quiet; then
        echo "Proton database is ready!"
    else
        echo "ERROR: Timed out waiting for Proton at ${PROTON_HOST_VALUE}:${PROTON_PORT_VALUE}" >&2
        exit 1
    fi
fi

# Initialize config from template on first run
CONFIG_PATH="/etc/serviceradar/consumers/db-event-writer.json"
TEMPLATE_PATH="/etc/serviceradar/templates/db-event-writer.json"

if [ ! -f "$CONFIG_PATH" ]; then
    if [ ! -f "$TEMPLATE_PATH" ]; then
        echo "Error: Template configuration file not found at $TEMPLATE_PATH"
        exit 1
    fi
    echo "First-time setup: Copying template config to writable location..."
    cp "$TEMPLATE_PATH" "$CONFIG_PATH"
    echo "Configuration initialized at $CONFIG_PATH"
else
    echo "Using existing configuration from $CONFIG_PATH"
fi

# Check for Proton password in shared credentials volume (same as core service)
# One-time password injection: update config if new password detected
if [ -f "/etc/serviceradar/credentials/proton-password" ]; then
    PROTON_PASSWORD=$(cat /etc/serviceradar/credentials/proton-password)
    echo "Found Proton password from shared credentials"
fi

if [ -n "$PROTON_PASSWORD" ]; then
    CURRENT_PASSWORD=$(jq -r '.database.password' "$CONFIG_PATH")
    if [ "$CURRENT_PASSWORD" != "$PROTON_PASSWORD" ]; then
        echo "Updating Proton password in $CONFIG_PATH"
        jq --arg pwd "$PROTON_PASSWORD" '.database.password = $pwd' "$CONFIG_PATH" > /tmp/config-updated.json
        mv /tmp/config-updated.json "$CONFIG_PATH"
    else
        echo "✅ Proton password already up to date"
    fi
else
    echo "⚠️  Warning: No Proton password found in credentials, using config as-is"
fi

echo "Starting ServiceRadar DB Event Writer with config: $CONFIG_PATH"

# Start the DB Event Writer service
exec /usr/local/bin/serviceradar-db-event-writer
