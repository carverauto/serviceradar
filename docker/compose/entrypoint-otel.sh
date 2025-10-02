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
if [ -n "${WAIT_FOR_NATS:-}" ]; then
    NATS_HOST_VALUE="${NATS_HOST:-nats}"
    NATS_PORT_VALUE="${NATS_PORT:-4222}"
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

# Check if config file exists
CONFIG_PATH="${CONFIG_PATH:-/etc/serviceradar/otel.toml}"
if [ ! -f "$CONFIG_PATH" ]; then
    echo "Error: Configuration file not found at $CONFIG_PATH"
    exit 1
fi

echo "Starting ServiceRadar OTEL collector with config: $CONFIG_PATH"

# Start the OTEL service
exec /usr/local/bin/serviceradar-otel --config "$CONFIG_PATH"
