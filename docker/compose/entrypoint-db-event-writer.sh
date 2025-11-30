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

# Default attempt count for dependency waits (2 minutes at 2s interval)
DEFAULT_WAIT_ATTEMPTS="${WAIT_FOR_ATTEMPTS_DEFAULT:-60}"

# Helper to resolve service hosts depending on the environment (Docker vs. Kubernetes)
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

# CNPG connection defaults (TLS/mTLS)
CNPG_HOST_VALUE=$(resolve_service_host "cnpg" CNPG_HOST "cnpg")
CNPG_PORT_VALUE=$(resolve_service_port CNPG_PORT "5432")
CNPG_DATABASE_VALUE="${CNPG_DATABASE:-serviceradar}"
CNPG_USERNAME_VALUE="${CNPG_USERNAME:-serviceradar}"
CNPG_SSL_MODE_VALUE="${CNPG_SSL_MODE:-${CNPG_SSLMODE:-verify-full}}"
CNPG_CERT_DIR_VALUE="${CNPG_CERT_DIR:-/etc/serviceradar/certs}"
CNPG_CA_FILE_VALUE="${CNPG_CA_FILE:-$CNPG_CERT_DIR_VALUE/root.pem}"
CNPG_CERT_FILE_VALUE="${CNPG_CERT_FILE:-$CNPG_CERT_DIR_VALUE/db-event-writer.pem}"
CNPG_KEY_FILE_VALUE="${CNPG_KEY_FILE:-$CNPG_CERT_DIR_VALUE/db-event-writer-key.pem}"

# Wait for dependencies to be ready
if [ -n "${WAIT_FOR_NATS:-}" ]; then
    NATS_HOST_VALUE=$(resolve_service_host "serviceradar-nats" NATS_HOST "nats")
    NATS_PORT_VALUE=$(resolve_service_port NATS_PORT "4222")
    echo "Waiting for NATS service at ${NATS_HOST_VALUE}:${NATS_PORT_VALUE}..."

    NATS_ATTEMPTS="${WAIT_FOR_NATS_ATTEMPTS:-$DEFAULT_WAIT_ATTEMPTS}"
    if wait-for-port \
        --host "${NATS_HOST_VALUE}" \
        --port "${NATS_PORT_VALUE}" \
        --attempts "${NATS_ATTEMPTS}" \
        --interval 2s \
        --quiet; then
        echo "NATS service is ready!"
    else
        echo "ERROR: Timed out waiting for NATS at ${NATS_HOST_VALUE}:${NATS_PORT_VALUE}" >&2
        exit 1
    fi
fi

if [ -n "${WAIT_FOR_CNPG:-}" ]; then
    echo "Waiting for CNPG database at ${CNPG_HOST_VALUE}:${CNPG_PORT_VALUE}..."

    CNPG_ATTEMPTS="${WAIT_FOR_CNPG_ATTEMPTS:-$DEFAULT_WAIT_ATTEMPTS}"
    if wait-for-port \
        --host "${CNPG_HOST_VALUE}" \
        --port "${CNPG_PORT_VALUE}" \
        --attempts "${CNPG_ATTEMPTS}" \
        --interval 2s \
        --quiet; then
        echo "CNPG database is ready!"
    else
        echo "ERROR: Timed out waiting for CNPG at ${CNPG_HOST_VALUE}:${CNPG_PORT_VALUE}" >&2
        exit 1
    fi
fi

# Initialize config from template on first run
CONFIG_PATH="/etc/serviceradar/consumers/db-event-writer.json"
TEMPLATE_PATH="/etc/serviceradar/templates/db-event-writer.json"

if [ ! -f "$CONFIG_PATH" ]; then
    if [ ! -f "$TEMPLATE_PATH" ]; then
        echo "Error: Template configuration file not found at $TEMPLATE_PATH"
        exit 1
    fi
    echo "First-time setup: Copying template config to writable location..."
    cp "$TEMPLATE_PATH" "$CONFIG_PATH"
    echo "Configuration initialized at $CONFIG_PATH"
else
    echo "Using existing configuration from $CONFIG_PATH"
fi

# One-time password injection for CNPG
CNPG_PASSWORD_VALUE=""
if [ -n "${CNPG_PASSWORD_FILE:-}" ] && [ -f "${CNPG_PASSWORD_FILE}" ]; then
    CNPG_PASSWORD_VALUE=$(cat "${CNPG_PASSWORD_FILE}")
    echo "Using CNPG password from ${CNPG_PASSWORD_FILE}"
elif [ -f "/etc/serviceradar/credentials/cnpg-password" ]; then
    CNPG_PASSWORD_VALUE=$(cat /etc/serviceradar/credentials/cnpg-password)
    echo "Found CNPG password from shared credentials"
elif [ -n "${CNPG_PASSWORD:-}" ]; then
    CNPG_PASSWORD_VALUE="${CNPG_PASSWORD}"
fi

if [ -n "$CNPG_PASSWORD_VALUE" ]; then
    CURRENT_PASSWORD=$(jq -r '.cnpg.password // ""' "$CONFIG_PATH")
    if [ "$CURRENT_PASSWORD" != "$CNPG_PASSWORD_VALUE" ]; then
        echo "Updating CNPG password in $CONFIG_PATH"
        jq --arg pwd "$CNPG_PASSWORD_VALUE" '.cnpg.password = $pwd' "$CONFIG_PATH" > /tmp/config-updated.json
        mv /tmp/config-updated.json "$CONFIG_PATH"
    else
        echo "✅ CNPG password already up to date"
    fi
else
    echo "⚠️  Warning: No CNPG password provided; config will rely on existing settings"
fi

# Enforce CNPG TLS/mTLS settings to avoid stale configs
jq --arg host "$CNPG_HOST_VALUE" \
   --argjson port "${CNPG_PORT_VALUE:-5432}" \
   --arg db "$CNPG_DATABASE_VALUE" \
   --arg user "$CNPG_USERNAME_VALUE" \
   --arg ssl "$CNPG_SSL_MODE_VALUE" \
   --arg ca "$CNPG_CA_FILE_VALUE" \
   --arg cert "$CNPG_CERT_FILE_VALUE" \
   --arg key "$CNPG_KEY_FILE_VALUE" \
   '
   .cnpg = (.cnpg // {})
   | .cnpg.host = $host
   | .cnpg.port = ($port | tonumber)
   | .cnpg.database = $db
   | .cnpg.username = $user
   | .cnpg.ssl_mode = $ssl
   | .cnpg.tls = {
       ca_file: $ca,
       cert_file: $cert,
       key_file: $key
     }
   ' "$CONFIG_PATH" > /tmp/config-updated.json
mv /tmp/config-updated.json "$CONFIG_PATH"
echo "✅ Ensured CNPG TLS config (host=$CNPG_HOST_VALUE port=$CNPG_PORT_VALUE ssl_mode=$CNPG_SSL_MODE_VALUE)"

echo "Starting ServiceRadar DB Event Writer with config: $CONFIG_PATH"

# Start the DB Event Writer service
exec /usr/local/bin/serviceradar-db-event-writer
