#!/bin/sh
# Entrypoint for the Rust-based SRQL service
set -e

echo "Starting ServiceRadar SRQL entrypoint..."

# Load generated secrets if available
if [ -f /etc/serviceradar/config/api.env ]; then
    echo "Loading API configuration from /etc/serviceradar/config/api.env (generated)..."
    set -a
    . /etc/serviceradar/config/api.env
    set +a
elif [ -f /etc/serviceradar/api.env ]; then
    echo "Loading API configuration from /etc/serviceradar/api.env..."
    set -a
    . /etc/serviceradar/api.env
    set +a
fi

urlencode() {
    local input="$1"
    local length=${#input}
    local i=1
    local output=""
    while [ $i -le $length ]; do
        char=$(printf '%s' "$input" | cut -c $i)
        case "$char" in
            [a-zA-Z0-9.~_-])
                output="${output}${char}"
                ;;
            "")
                ;;
            *)
                hex=$(printf '%%%02X' "'$char")
                output="${output}${hex}"
                ;;
        esac
        i=$((i + 1))
    done
    printf '%s' "$output"
}

load_cnpg_password() {
    if [ -n "$CNPG_PASSWORD" ]; then
        printf '%s' "$CNPG_PASSWORD"
        return
    fi

    PASSWORD_FILE="${CNPG_PASSWORD_FILE:-/etc/serviceradar/credentials/cnpg-password}"
    if [ -n "$PASSWORD_FILE" ]; then
        if [ ! -r "$PASSWORD_FILE" ]; then
            echo "Waiting for CNPG password at ${PASSWORD_FILE}..."
            waited=0
            max_wait="${CNPG_PASSWORD_WAIT_SECONDS:-60}"
            while [ $waited -lt "$max_wait" ]; do
                if [ -r "$PASSWORD_FILE" ] && [ -s "$PASSWORD_FILE" ]; then
                    break
                fi
                sleep 2
                waited=$((waited + 2))
            done
        fi

        if [ -r "$PASSWORD_FILE" ] && [ -s "$PASSWORD_FILE" ]; then
            CNPG_PASSWORD="$(cat "$PASSWORD_FILE")"
            printf '%s' "$CNPG_PASSWORD"
            return
        fi
    fi

    printf ''
}

# API key enforcement for SRQL service
if [ -z "$SRQL_API_KEY" ]; then
    if [ -n "$X_API_KEY" ]; then
        export SRQL_API_KEY="$X_API_KEY"
    elif [ -n "$API_KEY" ]; then
        export SRQL_API_KEY="$API_KEY"
    elif [ -f /etc/serviceradar/certs/api-key ]; then
        export SRQL_API_KEY="$(cat /etc/serviceradar/certs/api-key)"
    fi
fi
if [ -z "$SRQL_API_KEY" ]; then
    echo "Warning: SRQL_API_KEY not set; defaulting to changeme"
    export SRQL_API_KEY="changeme"
fi

# Require Bearer tokens when AUTH is enabled
if [ -z "$SRQL_REQUIRE_BEARER" ]; then
    if [ "${AUTH_ENABLED:-true}" = "true" ]; then
        export SRQL_REQUIRE_BEARER="true"
    else
        export SRQL_REQUIRE_BEARER="false"
    fi
fi

# Listening options
export SRQL_LISTEN_HOST="${SRQL_LISTEN_HOST:-0.0.0.0}"
export SRQL_LISTEN_PORT="${SRQL_LISTEN_PORT:-8080}"
export PORT="$SRQL_LISTEN_PORT"

# Build DATABASE_URL if not explicitly provided
if [ -z "$SRQL_DATABASE_URL" ]; then
    CNPG_HOST_VALUE="${CNPG_HOST:-cnpg-rw}"
    CNPG_PORT_VALUE="${CNPG_PORT:-5432}"
    CNPG_DATABASE_VALUE="${CNPG_DATABASE:-telemetry}"
    CNPG_USERNAME_VALUE="${CNPG_USERNAME:-postgres}"
    CNPG_SSLMODE_VALUE="${CNPG_SSLMODE:-require}"
    CNPG_CERT_DIR_VALUE="${CNPG_CERT_DIR:-/etc/serviceradar/certs}"
    CNPG_ROOT_CERT_VALUE="${CNPG_ROOT_CERT:-}"
    if [ -z "$CNPG_ROOT_CERT_VALUE" ] && [ -n "$CNPG_CERT_DIR_VALUE" ]; then
        if [ -f "${CNPG_CERT_DIR_VALUE}/root.pem" ]; then
            CNPG_ROOT_CERT_VALUE="${CNPG_CERT_DIR_VALUE}/root.pem"
        fi
    fi
    CNPG_PASSWORD_VALUE="$(load_cnpg_password)"

    SSL_PARAMS="sslmode=${CNPG_SSLMODE_VALUE}"
    if [ -n "$CNPG_ROOT_CERT_VALUE" ]; then
        SSL_PARAMS="${SSL_PARAMS}&sslrootcert=$(urlencode "$CNPG_ROOT_CERT_VALUE")"
    fi

    if [ -n "$CNPG_PASSWORD_VALUE" ]; then
        ENCODED_PASS="$(urlencode "$CNPG_PASSWORD_VALUE")"
        SRQL_DATABASE_URL="postgresql://${CNPG_USERNAME_VALUE}:${ENCODED_PASS}@${CNPG_HOST_VALUE}:${CNPG_PORT_VALUE}/${CNPG_DATABASE_VALUE}?${SSL_PARAMS}"
    else
        echo "Warning: CNPG password not provided; SRQL will attempt passwordless connection" >&2
        SRQL_DATABASE_URL="postgresql://${CNPG_USERNAME_VALUE}@${CNPG_HOST_VALUE}:${CNPG_PORT_VALUE}/${CNPG_DATABASE_VALUE}?${SSL_PARAMS}"
    fi
fi

export SRQL_DATABASE_URL
export DATABASE_URL="$SRQL_DATABASE_URL"

echo "SRQL listening on ${SRQL_LISTEN_HOST}:${SRQL_LISTEN_PORT}, targeting ${SRQL_DATABASE_URL%%\?*}"

exec "$@"
