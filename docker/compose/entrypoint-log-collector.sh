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

replace_line() {
    file_path="$1"
    existing_line="$2"
    replacement_line="$3"
    tmp_path="${file_path}.tmp"

    awk -v existing="$existing_line" -v replacement="$replacement_line" '
        $0 == existing {
            print replacement
            next
        }

        { print }
    ' "$file_path" > "$tmp_path"

    mv "$tmp_path" "$file_path"
}

patch_log_collector_configs() {
    flowgger_config_path="${FLOWGGER_CONFIG_PATH:-/etc/serviceradar/flowgger.toml}"
    otel_config_path="${OTEL_CONFIG_PATH:-/etc/serviceradar/otel.toml}"

    if [ -n "${LOG_COLLECTOR_HEALTH_LISTEN_ADDR:-}" ]; then
        replace_line \
            "$CONFIG_PATH" \
            'listen_addr = "0.0.0.0:50044"' \
            "listen_addr = \"${LOG_COLLECTOR_HEALTH_LISTEN_ADDR}\""
    fi

    if [ -n "${FLOWGGER_LISTEN_ADDR:-}" ]; then
        replace_line \
            "$flowgger_config_path" \
            'listen = "0.0.0.0:514"' \
            "listen = \"${FLOWGGER_LISTEN_ADDR}\""
    fi

    if [ -n "${FLOWGGER_NATS_URL:-}" ]; then
        replace_line \
            "$flowgger_config_path" \
            'nats_url = "nats://serviceradar-nats:4222"' \
            "nats_url = \"${FLOWGGER_NATS_URL}\""
    fi

    if [ -n "${FLOWGGER_NATS_CREDS_FILE:-}" ]; then
        replace_line \
            "$flowgger_config_path" \
            'nats_creds_file = "/var/run/serviceradar/runtime/NATS_CREDS_FILE"' \
            "nats_creds_file = \"${FLOWGGER_NATS_CREDS_FILE}\""
    fi

    if [ -n "${FLOWGGER_NATS_SUBJECT:-}" ]; then
        replace_line \
            "$flowgger_config_path" \
            'nats_subject = "logs.syslog"' \
            "nats_subject = \"${FLOWGGER_NATS_SUBJECT}\""
    fi

    if [ -n "${FLOWGGER_NATS_STREAM:-}" ]; then
        replace_line \
            "$flowgger_config_path" \
            'nats_stream = "events"' \
            "nats_stream = \"${FLOWGGER_NATS_STREAM}\""
    fi

    if [ -n "${OTEL_BIND_ADDRESS:-}" ]; then
        replace_line \
            "$otel_config_path" \
            'bind_address = "0.0.0.0"' \
            "bind_address = \"${OTEL_BIND_ADDRESS}\""
    fi

    if [ -n "${OTEL_PORT:-}" ]; then
        replace_line \
            "$otel_config_path" \
            'port = 4317' \
            "port = ${OTEL_PORT}"
    fi

    if [ -n "${OTEL_NATS_URL:-}" ]; then
        replace_line \
            "$otel_config_path" \
            'url = "nats://serviceradar-nats:4222"' \
            "url = \"${OTEL_NATS_URL}\""
    fi

    if [ -n "${OTEL_NATS_CREDS_FILE:-}" ]; then
        replace_line \
            "$otel_config_path" \
            'creds_file = "/var/run/serviceradar/runtime/NATS_CREDS_FILE"' \
            "creds_file = \"${OTEL_NATS_CREDS_FILE}\""
    fi

    if [ -n "${OTEL_SUBJECT:-}" ]; then
        replace_line \
            "$otel_config_path" \
            'subject = "otel"' \
            "subject = \"${OTEL_SUBJECT}\""
    fi

    if [ -n "${OTEL_LOGS_SUBJECT:-}" ]; then
        replace_line \
            "$otel_config_path" \
            'logs_subject = "logs.otel"' \
            "logs_subject = \"${OTEL_LOGS_SUBJECT}\""
    fi

    if [ -n "${OTEL_STREAM:-}" ]; then
        replace_line \
            "$otel_config_path" \
            'stream = "events"' \
            "stream = \"${OTEL_STREAM}\""
    fi
}

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

# Check if config file exists
CONFIG_PATH="${CONFIG_PATH:-/etc/serviceradar/log-collector.toml}"
if [ ! -f "$CONFIG_PATH" ]; then
    echo "Error: Configuration file not found at $CONFIG_PATH"
    exit 1
fi

patch_log_collector_configs

echo "Starting ServiceRadar Log Collector with config: $CONFIG_PATH"

# Start the unified log collector
exec /usr/local/bin/serviceradar-log-collector --config "$CONFIG_PATH"
