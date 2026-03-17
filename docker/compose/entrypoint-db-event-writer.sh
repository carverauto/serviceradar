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
CNPG_CERT_FILE_VALUE="${CNPG_CERT_FILE:-$CNPG_CERT_DIR_VALUE/cnpg-client.pem}"
CNPG_KEY_FILE_VALUE="${CNPG_KEY_FILE:-$CNPG_CERT_DIR_VALUE/cnpg-client-key.pem}"

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

SOURCE_CONFIG_PATH="${CONFIG_PATH:-/etc/serviceradar/consumers/db-event-writer.json}"
if [ ! -f "$SOURCE_CONFIG_PATH" ]; then
    echo "Error: Configuration file not found at $SOURCE_CONFIG_PATH"
    exit 1
fi

echo "Using configuration from $SOURCE_CONFIG_PATH"

# Copy to a writable location so jq patching works with read-only bind mounts
WORKING_CONFIG_PATH="/tmp/db-event-writer-config.json"
cp "$SOURCE_CONFIG_PATH" "$WORKING_CONFIG_PATH"

write_config_json() {
    jq "$@" "$WORKING_CONFIG_PATH" > /tmp/config-updated.json
    mv /tmp/config-updated.json "$WORKING_CONFIG_PATH"
}

NATS_URL_VALUE="${DB_EVENT_WRITER_NATS_URL:-${NATS_URL:-}}"
NATS_CREDS_FILE_VALUE="${DB_EVENT_WRITER_NATS_CREDS_FILE:-${NATS_CREDS_FILE:-}}"
LISTEN_ADDR_VALUE="${DB_EVENT_WRITER_LISTEN_ADDR:-}"
STREAM_NAME_VALUE="${DB_EVENT_WRITER_STREAM_NAME:-}"
CONSUMER_NAME_VALUE="${DB_EVENT_WRITER_CONSUMER_NAME:-}"
AGENT_ID_VALUE="${DB_EVENT_WRITER_AGENT_ID:-}"
GATEWAY_ID_VALUE="${DB_EVENT_WRITER_GATEWAY_ID:-}"
DISABLE_SECURITY_VALUE="${DB_EVENT_WRITER_DISABLE_SECURITY:-}"
DISABLE_NATS_SECURITY_VALUE="${DB_EVENT_WRITER_DISABLE_NATS_SECURITY:-}"
OTEL_ENABLED_VALUE="${DB_EVENT_WRITER_OTEL_ENABLED:-}"
STREAMS_JSON_VALUE="${DB_EVENT_WRITER_STREAMS_JSON:-}"

write_config_json \
   --arg nats_url "$NATS_URL_VALUE" \
   --arg nats_creds_file "$NATS_CREDS_FILE_VALUE" \
   --arg listen_addr "$LISTEN_ADDR_VALUE" \
   --arg stream_name "$STREAM_NAME_VALUE" \
   --arg consumer_name "$CONSUMER_NAME_VALUE" \
   --arg agent_id "$AGENT_ID_VALUE" \
   --arg gateway_id "$GATEWAY_ID_VALUE" \
   --arg disable_security "$DISABLE_SECURITY_VALUE" \
   --arg disable_nats_security "$DISABLE_NATS_SECURITY_VALUE" \
   --arg otel_enabled "$OTEL_ENABLED_VALUE" \
   --arg streams_json "$STREAMS_JSON_VALUE" \
   '
   if $listen_addr != "" then .listen_addr = $listen_addr else . end
   | if $nats_url != "" then .nats_url = $nats_url else . end
   | if $nats_creds_file != "" then .nats_creds_file = $nats_creds_file else . end
   | if $stream_name != "" then .stream_name = $stream_name else . end
   | if $consumer_name != "" then .consumer_name = $consumer_name else . end
   | if $agent_id != "" then .agent_id = $agent_id else . end
   | if $gateway_id != "" then .gateway_id = $gateway_id else . end
   | if $streams_json != "" then .streams = ($streams_json | fromjson) else . end
   | if ($disable_security | ascii_downcase) == "true" then del(.security) else . end
   | if ($disable_nats_security | ascii_downcase) == "true" then del(.nats_security) else . end
   | if ($otel_enabled | ascii_downcase) == "true" then .logging.otel.enabled = true
     elif ($otel_enabled | ascii_downcase) == "false" then .logging.otel.enabled = false
     else . end
   '

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
    CURRENT_PASSWORD=$(jq -r '.cnpg.password // ""' "$WORKING_CONFIG_PATH")
    if [ "$CURRENT_PASSWORD" != "$CNPG_PASSWORD_VALUE" ]; then
        echo "Updating CNPG password in $WORKING_CONFIG_PATH"
        write_config_json --arg pwd "$CNPG_PASSWORD_VALUE" '.cnpg.password = $pwd'
    else
        echo "✅ CNPG password already up to date"
    fi
else
    echo "⚠️  Warning: No CNPG password provided; config will rely on existing settings"
fi

# Enforce CNPG connection settings to avoid stale configs
# For plain hosted mode, do not emit a TLS block at all.
case "$CNPG_SSL_MODE_VALUE" in
    disable|allow|prefer)
    write_config_json --arg host "$CNPG_HOST_VALUE" \
       --argjson port "${CNPG_PORT_VALUE:-5432}" \
       --arg db "$CNPG_DATABASE_VALUE" \
       --arg user "$CNPG_USERNAME_VALUE" \
       --arg ssl "$CNPG_SSL_MODE_VALUE" \
       '
       .cnpg = (.cnpg // {})
       | .cnpg.host = $host
       | .cnpg.port = ($port | tonumber)
       | .cnpg.database = $db
       | .cnpg.username = $user
       | .cnpg.ssl_mode = $ssl
       | del(.cnpg.tls)
       '
    echo "✅ Ensured CNPG plain config (host=$CNPG_HOST_VALUE port=$CNPG_PORT_VALUE ssl_mode=$CNPG_SSL_MODE_VALUE)"
    ;;
    *)
    # Build TLS config based on whether client certs are provided
if [ -n "$CNPG_CERT_FILE_VALUE" ] && [ -n "$CNPG_KEY_FILE_VALUE" ]; then
    # Full mTLS with client certs
    write_config_json --arg host "$CNPG_HOST_VALUE" \
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
       '
    echo "✅ Ensured CNPG mTLS config (host=$CNPG_HOST_VALUE port=$CNPG_PORT_VALUE ssl_mode=$CNPG_SSL_MODE_VALUE)"
else
    # Server TLS verification only (no client certs)
    write_config_json --arg host "$CNPG_HOST_VALUE" \
       --argjson port "${CNPG_PORT_VALUE:-5432}" \
       --arg db "$CNPG_DATABASE_VALUE" \
       --arg user "$CNPG_USERNAME_VALUE" \
       --arg ssl "$CNPG_SSL_MODE_VALUE" \
       --arg ca "$CNPG_CA_FILE_VALUE" \
       '
       .cnpg = (.cnpg // {})
       | .cnpg.host = $host
       | .cnpg.port = ($port | tonumber)
       | .cnpg.database = $db
       | .cnpg.username = $user
       | .cnpg.ssl_mode = $ssl
       | .cnpg.tls = {
           ca_file: $ca
         }
       '
    echo "✅ Ensured CNPG TLS config (host=$CNPG_HOST_VALUE port=$CNPG_PORT_VALUE ssl_mode=$CNPG_SSL_MODE_VALUE ca_only=true)"
fi
    ;;
esac

echo "Starting ServiceRadar DB Event Writer with config: $WORKING_CONFIG_PATH"

# Start the DB Event Writer service
exec /usr/local/bin/serviceradar-db-event-writer --config "$WORKING_CONFIG_PATH"
