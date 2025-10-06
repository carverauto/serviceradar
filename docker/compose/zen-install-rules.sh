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
DATA_DIR="${DATA_DIR:-/var/lib/serviceradar/data}"
RULE_SOURCE_DIR="${RULE_SOURCE_DIR:-/etc/serviceradar/rules}"

# Check if config file exists
if [ ! -f "$CONFIG_PATH" ]; then
    echo "Error: Configuration file not found at $CONFIG_PATH"
    exit 1
fi

# Ensure data directory exists
if [ ! -d "$DATA_DIR" ]; then
    echo "Creating data directory at $DATA_DIR"
    mkdir -p "$DATA_DIR"
fi

# Seed data directory from mounted rules if available
if [ -d "$RULE_SOURCE_DIR" ]; then
    for rule_file in "$RULE_SOURCE_DIR"/*.json; do
        [ -e "$rule_file" ] || continue
        target="$DATA_DIR/$(basename "$rule_file")"
        if [ ! -f "$target" ]; then
            echo "Copying $(basename "$rule_file") from $RULE_SOURCE_DIR to $DATA_DIR"
            cp "$rule_file" "$target"
        fi
    done
fi

echo "Installing initial zen rules..."

install_rule() {
    local file="$1"
    local subject="$2"
    local key="$3"

    if [ -f "$file" ]; then
        echo "Installing $key rule for $subject..."
        zen-put-rule \
            --config "$CONFIG_PATH" \
            --file "$file" \
            --subject "$subject" \
            --key "$key"
        echo "✓ $key rule installed"
    else
        echo "Warning: $(basename "$file") not found; skipping $key"
    fi
}

install_rule "$DATA_DIR/strip_full_message.json" "events.syslog" "strip_full_message"
install_rule "$DATA_DIR/cef_severity.json" "events.syslog" "cef_severity"
install_rule "$DATA_DIR/snmp_severity.json" "events.snmp" "snmp_severity"
install_rule "$DATA_DIR/passthrough.json" "events.otel.logs" "passthrough"

echo "✅ Initial zen rules installation completed successfully"
