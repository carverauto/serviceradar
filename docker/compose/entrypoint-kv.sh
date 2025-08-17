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
CONFIG_PATH="${CONFIG_PATH:-/etc/serviceradar/kv.json}"

# Check that config file exists
if [ ! -f "$CONFIG_PATH" ]; then
    echo "ERROR: Configuration file not found at $CONFIG_PATH"
    echo "Please mount the config file from docker/compose/kv.docker.json"
    exit 1
fi

echo "Using configuration from $CONFIG_PATH"

# Wait for NATS to be ready if configured
if [ -n "$WAIT_FOR_NATS" ]; then
    NATS_ADDR="${NATS_HOST:-nats}:${NATS_PORT:-4222}"
    echo "Waiting for NATS at $NATS_ADDR..."
    
    for i in {1..30}; do
        if nc -z ${NATS_HOST:-nats} ${NATS_PORT:-4222} > /dev/null 2>&1; then
            echo "NATS is ready!"
            break
        fi
        echo "Waiting for NATS... ($i/30)"
        sleep 2
    done
fi

# Execute the main command
exec "$@" --config "$CONFIG_PATH"