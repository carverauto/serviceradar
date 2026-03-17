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

CONFIG_PATH="${CONFIG_PATH:-/etc/serviceradar/datasvc.json}"

patch_datasvc_config() {
    LISTEN_ADDR_VALUE="${DATASVC_LISTEN_ADDR:-}"
    NATS_URL_VALUE="${DATASVC_NATS_URL:-${NATS_URL:-}}"
    NATS_CREDS_FILE_VALUE="${DATASVC_NATS_CREDS_FILE:-${NATS_CREDS_FILE:-}}"
    SECURITY_MODE_VALUE="${DATASVC_SECURITY_MODE:-}"
    DISABLE_NATS_SECURITY_VALUE="${DATASVC_DISABLE_NATS_SECURITY:-}"
    BUCKET_VALUE="${DATASVC_BUCKET:-}"
    DOMAIN_VALUE="${DATASVC_DOMAIN:-}"

    jq \
       --arg listen_addr "$LISTEN_ADDR_VALUE" \
       --arg nats_url "$NATS_URL_VALUE" \
       --arg nats_creds_file "$NATS_CREDS_FILE_VALUE" \
       --arg security_mode "$SECURITY_MODE_VALUE" \
       --arg disable_nats_security "$DISABLE_NATS_SECURITY_VALUE" \
       --arg bucket "$BUCKET_VALUE" \
       --arg domain "$DOMAIN_VALUE" \
       '
       if $listen_addr != "" then .listen_addr = $listen_addr else . end
       | if $nats_url != "" then .nats_url = $nats_url else . end
       | if $nats_creds_file != "" then .nats_creds_file = $nats_creds_file else . end
       | if $bucket != "" then .bucket = $bucket else . end
       | if $domain != "" then .domain = $domain else del(.domain) end
       | if $security_mode != "" then .security.mode = $security_mode else . end
       | if ($disable_nats_security | ascii_downcase) == "true" then del(.nats_security) else . end
       ' "$CONFIG_PATH" > /tmp/datasvc-config-updated.json
    mv /tmp/datasvc-config-updated.json "$CONFIG_PATH"
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

# Check that config file exists
if [ ! -f "$CONFIG_PATH" ]; then
    echo "ERROR: Configuration file not found at $CONFIG_PATH"
    echo "Please mount the config file from docker/compose/datasvc.docker.json"
    exit 1
fi

echo "Using configuration from $CONFIG_PATH"

patch_datasvc_config

# Wait for NATS to be ready if configured
if [ -n "${WAIT_FOR_NATS:-}" ]; then
    NATS_HOST_VALUE=$(resolve_service_host "serviceradar-nats" NATS_HOST "nats")
    NATS_PORT_VALUE=$(resolve_service_port NATS_PORT "4222")
    echo "Waiting for NATS at ${NATS_HOST_VALUE}:${NATS_PORT_VALUE}..."

    if wait-for-port \
        --host "${NATS_HOST_VALUE}" \
        --port "${NATS_PORT_VALUE}" \
        --attempts 30 \
        --interval 2s \
        --quiet; then
        echo "NATS is ready!"
    else
        echo "ERROR: Timed out waiting for NATS at ${NATS_HOST_VALUE}:${NATS_PORT_VALUE}" >&2
        exit 1
    fi
fi

# Execute the main command
exec "$@" --config "$CONFIG_PATH"
