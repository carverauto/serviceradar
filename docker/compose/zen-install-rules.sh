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

CONFIG_PATH="${CONFIG_PATH:-/etc/serviceradar/zen.json}"
DATA_DIR="/var/lib/serviceradar/data"

# Check if config file exists
if [ ! -f "$CONFIG_PATH" ]; then
    echo "Error: Configuration file not found at $CONFIG_PATH"
    exit 1
fi

# Check if data directory exists
if [ ! -d "$DATA_DIR" ]; then
    echo "Error: Data directory not found at $DATA_DIR"
    exit 1
fi

echo "Installing initial zen rules..."

# Install CEF severity rule for syslog events
if [ -f "$DATA_DIR/cef_severity.json" ]; then
    echo "Installing cef_severity rule for events.syslog..."
    zen-put-rule \
        --config "$CONFIG_PATH" \
        --file "$DATA_DIR/cef_severity.json" \
        --subject events.syslog \
        --key cef_severity
    echo "✓ cef_severity rule installed"
else
    echo "Warning: cef_severity.json not found in $DATA_DIR"
fi

# Install strip full message rule for syslog events  
if [ -f "$DATA_DIR/strip_full_message.json" ]; then
    echo "Installing strip_full_message rule for events.syslog..."
    zen-put-rule \
        --config "$CONFIG_PATH" \
        --file "$DATA_DIR/strip_full_message.json" \
        --subject events.syslog \
        --key strip_full_message
    echo "✓ strip_full_message rule installed"
else
    echo "Warning: strip_full_message.json not found in $DATA_DIR"
fi

# Install passthrough rule for OTEL logs (if it exists)
if [ -f "$DATA_DIR/passthrough.json" ]; then
    echo "Installing passthrough rule for events.otel.logs..."
    zen-put-rule \
        --config "$CONFIG_PATH" \
        --file "$DATA_DIR/passthrough.json" \
        --subject events.otel.logs \
        --key passthrough
    echo "✓ passthrough rule installed"
else
    echo "Info: passthrough.json not found in $DATA_DIR (optional)"
fi

echo "✅ Initial zen rules installation completed successfully"
