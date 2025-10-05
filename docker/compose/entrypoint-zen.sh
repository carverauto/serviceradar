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

if [ -n "${WAIT_FOR_KV:-}" ]; then
    KV_HOST_VALUE=$(resolve_service_host "serviceradar-kv" KV_HOST "kv")
    KV_PORT_VALUE=$(resolve_service_port KV_PORT "50057")
    echo "Waiting for KV service at ${KV_HOST_VALUE}:${KV_PORT_VALUE}..."

    if wait-for-port \
        --host "${KV_HOST_VALUE}" \
        --port "${KV_PORT_VALUE}" \
        --attempts 30 \
        --interval 2s \
        --quiet; then
        echo "KV service is ready!"
    else
        echo "ERROR: Timed out waiting for KV at ${KV_HOST_VALUE}:${KV_PORT_VALUE}" >&2
        exit 1
    fi
fi

# Check if config file exists
CONFIG_PATH="${CONFIG_PATH:-/etc/serviceradar/zen.json}"
if [ ! -f "$CONFIG_PATH" ]; then
    echo "Error: Configuration file not found at $CONFIG_PATH"
    exit 1
fi

# Check if this is the first startup by looking for a marker file
RULES_INSTALLED_MARKER="/var/lib/serviceradar/.rules_installed"

if [ ! -f "$RULES_INSTALLED_MARKER" ]; then
    echo "First startup detected - installing initial zen rules..."
    
    # Install initial rules
    if /usr/local/bin/zen-install-rules.sh; then
        # Create marker file to indicate rules have been installed
        touch "$RULES_INSTALLED_MARKER"
        echo "✅ Initial rules installation completed"
    else
        echo "⚠️  Warning: Initial rules installation failed, continuing anyway..."
    fi
else
    echo "Rules already installed, skipping initial rule installation"
fi

echo "Starting ServiceRadar Zen with config: $CONFIG_PATH"

# Start the Zen service
exec /usr/local/bin/serviceradar-zen --config "$CONFIG_PATH"
