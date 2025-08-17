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

# Wait for dependencies to be ready
if [ -n "$WAIT_FOR_AGENT" ]; then
    AGENT_ADDR="${AGENT_HOST:-agent}:${AGENT_PORT:-50051}"
    echo "Waiting for Agent service at $AGENT_ADDR..."
    for i in {1..30}; do
        if nc -z ${AGENT_HOST:-agent} ${AGENT_PORT:-50051} > /dev/null 2>&1; then
            echo "Agent service is ready!"
            break
        fi
        echo "Waiting for Agent... ($i/30)"
        sleep 2
    done
fi

if [ -n "$WAIT_FOR_OTEL" ]; then
    OTEL_ADDR="${OTEL_HOST:-otel}:${OTEL_PORT:-4317}"
    echo "Waiting for OTEL service at $OTEL_ADDR..."
    for i in {1..30}; do
        if nc -z ${OTEL_HOST:-otel} ${OTEL_PORT:-4317} > /dev/null 2>&1; then
            echo "OTEL service is ready!"
            break
        fi
        echo "Waiting for OTEL... ($i/30)"
        sleep 2
    done
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