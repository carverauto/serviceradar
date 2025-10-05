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
if [ -n "${WAIT_FOR_AGENT:-}" ]; then
    AGENT_HOST_VALUE=$(resolve_service_host "serviceradar-agent" AGENT_HOST "agent")
    AGENT_PORT_VALUE=$(resolve_service_port AGENT_PORT "50051")
    echo "Waiting for Agent service at ${AGENT_HOST_VALUE}:${AGENT_PORT_VALUE}..."

    if wait-for-port \
        --host "${AGENT_HOST_VALUE}" \
        --port "${AGENT_PORT_VALUE}" \
        --attempts 30 \
        --interval 2s \
        --quiet; then
        echo "Agent service is ready!"
    else
        echo "ERROR: Timed out waiting for Agent at ${AGENT_HOST_VALUE}:${AGENT_PORT_VALUE}" >&2
        exit 1
    fi
fi

if [ -n "${WAIT_FOR_OTEL:-}" ]; then
    OTEL_HOST_VALUE=$(resolve_service_host "serviceradar-otel" OTEL_HOST "otel")
    OTEL_PORT_VALUE=$(resolve_service_port OTEL_PORT "4317")
    echo "Waiting for OTEL service at ${OTEL_HOST_VALUE}:${OTEL_PORT_VALUE}..."

    if wait-for-port \
        --host "${OTEL_HOST_VALUE}" \
        --port "${OTEL_PORT_VALUE}" \
        --attempts 30 \
        --interval 2s \
        --quiet; then
        echo "OTEL service is ready!"
    else
        echo "ERROR: Timed out waiting for OTEL at ${OTEL_HOST_VALUE}:${OTEL_PORT_VALUE}" >&2
        exit 1
    fi
fi

# Check if config file exists
CONFIG_PATH="/etc/serviceradar/checkers/snmp.json"
if [ ! -f "$CONFIG_PATH" ]; then
    echo "Error: Configuration file not found at $CONFIG_PATH"
    exit 1
fi

echo "Using configuration from $CONFIG_PATH"
echo "Starting ServiceRadar SNMP Checker with config: $CONFIG_PATH"

# Start the SNMP Checker service
exec /usr/local/bin/serviceradar-snmp-checker -config "$CONFIG_PATH"
