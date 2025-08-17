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

# Wait for dependencies to be ready
if [ -n "$WAIT_FOR_NATS" ]; then
    NATS_ADDR="${NATS_HOST:-nats}:${NATS_PORT:-4222}"
    echo "Waiting for NATS service at $NATS_ADDR..."
    for i in {1..30}; do
        if nc -z ${NATS_HOST:-nats} ${NATS_PORT:-4222} > /dev/null 2>&1; then
            echo "NATS service is ready!"
            break
        fi
        echo "Waiting for NATS... ($i/30)"
        sleep 2
    done
fi

if [ -n "$WAIT_FOR_KV" ]; then
    KV_ADDR="${KV_HOST:-kv}:${KV_PORT:-50057}"
    echo "Waiting for KV service at $KV_ADDR..."
    for i in {1..30}; do
        if nc -z ${KV_HOST:-kv} ${KV_PORT:-50057} > /dev/null 2>&1; then
            echo "KV service is ready!"
            break
        fi
        echo "Waiting for KV... ($i/30)"
        sleep 2
    done
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