#!/bin/sh
# Entrypoint for SRQL OCaml service
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

# Default Proton connectivity (align with docker network names)
export PROTON_HOST="${PROTON_HOST:-proton}"
export PROTON_PORT="${PROTON_PORT:-9440}"
export PROTON_TLS="${PROTON_TLS:-1}"
export PROTON_INSECURE_SKIP_VERIFY="${PROTON_INSECURE_SKIP_VERIFY:-1}"
export PROTON_VERIFY_HOSTNAME="${PROTON_VERIFY_HOSTNAME:-0}"
export PROTON_COMPRESSION="${PROTON_COMPRESSION:-lz4}"

# Map certificate paths (generated bundle uses .pem files)
if [ -z "$PROTON_CA_CERT" ] && [ -f /etc/serviceradar/certs/root.pem ]; then
    export PROTON_CA_CERT="/etc/serviceradar/certs/root.pem"
fi

# Client auth is optional; skip unless explicitly provided
if [ -z "$PROTON_CLIENT_CERT" ] && [ -f /etc/serviceradar/certs/srql.pem ]; then
    export PROTON_CLIENT_CERT="/etc/serviceradar/certs/srql.pem"
fi
if [ -z "$PROTON_CLIENT_KEY" ] && [ -f /etc/serviceradar/certs/srql-key.pem ]; then
    export PROTON_CLIENT_KEY="/etc/serviceradar/certs/srql-key.pem"
fi

# Load Proton password from shared credentials volume if present
if [ -z "$PROTON_PASSWORD" ]; then
    PASSWORD_FILE="${PROTON_PASSWORD_FILE:-/etc/serviceradar/credentials/proton-password}"
    if [ -n "$PASSWORD_FILE" ]; then
        if [ ! -r "$PASSWORD_FILE" ]; then
            echo "Waiting for Proton credentials at ${PASSWORD_FILE}..."
            waited=0
            max_wait="${PROTON_PASSWORD_WAIT_SECONDS:-60}"
            while [ $waited -lt "$max_wait" ]; do
                if [ -r "$PASSWORD_FILE" ] && [ -s "$PASSWORD_FILE" ]; then
                    break
                fi
                sleep 2
                waited=$((waited + 2))
            done
        fi

        if [ -r "$PASSWORD_FILE" ] && [ -s "$PASSWORD_FILE" ]; then
            export PROTON_PASSWORD="$(cat "$PASSWORD_FILE")"
        else
            echo "Warning: Proton password file ${PASSWORD_FILE} not available; continuing without password"
        fi
    fi
fi

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
export DREAM_INTERFACE="$SRQL_LISTEN_HOST"
export DREAM_PORT="$SRQL_LISTEN_PORT"

# Launch service
exec "$@"
