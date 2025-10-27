#!/bin/sh
# Entrypoint wrapper for serviceradar-poller that can optionally manage
# embedded SPIRE components for non-Kubernetes deployments. When the poller
# runs in SPIFFE mode and MANAGE_NESTED_SPIRE=enabled, this script starts the
# upstream agent, downstream server, and downstream agent before launching the
# poller binary. All subprocesses inherit the container lifecycle and are torn
# down automatically on exit.

set -eu

log() {
    printf '[poller-entrypoint] %s\n' "$*" >&2
}

MODE="${POLLERS_SECURITY_MODE:-mtls}"
MANAGE="${MANAGE_NESTED_SPIRE:-disabled}"
RUN_DIR="${NESTED_SPIRE_RUN_DIR:-/run/spire/nested}"
DEFAULT_CONFIG_DIR="/etc/serviceradar/config/poller-spire"
if [ ! -d "$DEFAULT_CONFIG_DIR" ] && [ -d "/etc/poller-spire" ]; then
    DEFAULT_CONFIG_DIR="/etc/poller-spire"
fi
CONFIG_DIR="${NESTED_SPIRE_CONFIG_DIR:-${DEFAULT_CONFIG_DIR}}"
UPSTREAM_AGENT_CONFIG="${NESTED_SPIRE_UPSTREAM_AGENT_CONFIG:-${CONFIG_DIR}/upstream-agent.conf}"
SERVER_CONFIG="${NESTED_SPIRE_SERVER_CONFIG:-${CONFIG_DIR}/server.conf}"
DOWNSTREAM_AGENT_CONFIG="${NESTED_SPIRE_DOWNSTREAM_AGENT_CONFIG:-${CONFIG_DIR}/downstream-agent.conf}"
CONFIG_ENV_FILE="${NESTED_SPIRE_CONFIG_ENV_FILE:-${CONFIG_DIR}/env}"
if [ -r "$CONFIG_ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_ENV_FILE"
fi
UPSTREAM_AGENT_CMD="${NESTED_SPIRE_UPSTREAM_AGENT_CMD:-/usr/local/bin/spire-agent run -config ${UPSTREAM_AGENT_CONFIG}}"
SERVER_CMD="${NESTED_SPIRE_SERVER_CMD:-/usr/local/bin/spire-server run -config ${SERVER_CONFIG}}"
DOWNSTREAM_AGENT_CMD="${NESTED_SPIRE_DOWNSTREAM_AGENT_CMD:-/usr/local/bin/spire-agent run -config ${DOWNSTREAM_AGENT_CONFIG}}"
SERVER_SOCKET="${NESTED_SPIRE_SERVER_SOCKET:-${RUN_DIR}/server/api.sock}"
TRUST_DOMAIN_DEFAULT="carverauto.dev"
TRUST_DOMAIN="${POLLERS_TRUST_DOMAIN:-${TRUST_DOMAIN:-${TRUST_DOMAIN_DEFAULT}}}"
DOWNSTREAM_PARENT_ID_DEFAULT="spiffe://${TRUST_DOMAIN}/ns/serviceradar/poller-nested-spire"
DOWNSTREAM_PARENT_ID="${NESTED_SPIRE_PARENT_ID:-${DOWNSTREAM_PARENT_ID_DEFAULT}}"
DOWNSTREAM_SPIFFE_ID_DEFAULT="spiffe://${TRUST_DOMAIN}/services/poller"
DOWNSTREAM_SPIFFE_ID="${NESTED_SPIRE_DOWNSTREAM_SPIFFE_ID:-${DOWNSTREAM_SPIFFE_ID_DEFAULT}}"
DOWNSTREAM_TOKEN_TTL="${NESTED_SPIRE_DOWNSTREAM_TOKEN_TTL:-4h}"

resolve_join_token() {
    value="$1"
    file="$2"
    if [ -n "$value" ]; then
        printf '%s' "$value"
        return
    fi
    if [ -n "$file" ] && [ -r "$file" ]; then
        head -n1 "$file"
        return
    fi
    printf ''
}

pids=""
cleanup() {
    for pid in $pids; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done
}
trap cleanup EXIT INT TERM

start_component() {
    name="$1"
    shift
    cmdline="$1"
    shift
    binary="$(printf '%s' "$cmdline" | awk '{print $1}')"
    if [ ! -x "$binary" ]; then
        log "WARN: $name binary '$binary' not found or not executable; skipping embedded SPIRE startup."
        return 1
    fi
    safe_cmdline=$(printf '%s' "$cmdline" | sed -E 's/(-joinToken[[:space:]]+)([^[:space:]]+)/\1****/g')
    log "Starting embedded SPIRE $name: $safe_cmdline"
    sh -c "$cmdline" &
    pids="$pids $!"
    return 0
}

wait_for_socket() {
    description="$1"
    socket_path="$2"
    attempts="${3:-30}"
    sleep_seconds="${4:-1}"

    i=0
    while [ "$i" -lt "$attempts" ]; do
        if [ -S "$socket_path" ]; then
            log "$description is ready at $socket_path"
            return 0
        fi
        i=$((i + 1))
        sleep "$sleep_seconds"
    done
    log "ERROR: timed out waiting for $description socket $socket_path"
    return 1
}

if [ "$MODE" = "spiffe" ] && [ "$MANAGE" = "enabled" ]; then
    mkdir -p "$RUN_DIR/upstream" "$RUN_DIR/upstream-agent" "$RUN_DIR/server" "$RUN_DIR/workload" "$RUN_DIR/downstream-agent"
    UPSTREAM_JOIN_TOKEN="$(resolve_join_token "${NESTED_SPIRE_UPSTREAM_JOIN_TOKEN:-}" "${NESTED_SPIRE_UPSTREAM_JOIN_TOKEN_FILE:-}")"
    if [ -n "$UPSTREAM_JOIN_TOKEN" ]; then
        UPSTREAM_AGENT_CMD="${UPSTREAM_AGENT_CMD} -joinToken ${UPSTREAM_JOIN_TOKEN}"
    fi
    if [ -n "${NESTED_SPIRE_UPSTREAM_TRUST_BUNDLE:-}" ] && [ -r "${NESTED_SPIRE_UPSTREAM_TRUST_BUNDLE}" ]; then
        UPSTREAM_AGENT_CMD="${UPSTREAM_AGENT_CMD} -trustBundle ${NESTED_SPIRE_UPSTREAM_TRUST_BUNDLE}"
    elif [ -n "${NESTED_SPIRE_UPSTREAM_TRUST_BUNDLE_FILE:-}" ] && [ -r "${NESTED_SPIRE_UPSTREAM_TRUST_BUNDLE_FILE}" ]; then
        UPSTREAM_AGENT_CMD="${UPSTREAM_AGENT_CMD} -trustBundle ${NESTED_SPIRE_UPSTREAM_TRUST_BUNDLE_FILE}"
    fi

    DOWNSTREAM_JOIN_TOKEN="$(resolve_join_token "${NESTED_SPIRE_DOWNSTREAM_JOIN_TOKEN:-}" "${NESTED_SPIRE_DOWNSTREAM_JOIN_TOKEN_FILE:-}")"

    if [ -f "$UPSTREAM_AGENT_CONFIG" ]; then
        start_component "upstream agent" "$UPSTREAM_AGENT_CMD"
    else
        log "WARN: upstream agent config $UPSTREAM_AGENT_CONFIG not found; skipping embedded SPIRE startup."
    fi
    if [ -f "$SERVER_CONFIG" ]; then
        start_component "nested server" "$SERVER_CMD"
    else
        log "WARN: nested server config $SERVER_CONFIG not found; skipping embedded SPIRE startup."
    fi
    if [ -s "$DOWNSTREAM_AGENT_CONFIG" ]; then
        if [ -z "$DOWNSTREAM_JOIN_TOKEN" ] && [ -n "${NESTED_SPIRE_AUTO_GENERATE_DOWNSTREAM_TOKEN:-1}" ]; then
            if wait_for_socket "Nested SPIRE server" "$SERVER_SOCKET" "${NESTED_SPIRE_WAIT_ATTEMPTS:-30}" "${NESTED_SPIRE_WAIT_SLEEP:-1}"; then
                if command -v spire-server >/dev/null 2>&1; then
                    TOKEN_OUTPUT=$(spire-server token generate -socketPath "$SERVER_SOCKET" -spiffeID "$DOWNSTREAM_SPIFFE_ID" -parentID "$DOWNSTREAM_PARENT_ID" -downstream -ttl "$DOWNSTREAM_TOKEN_TTL" 2>/dev/null || true)
                    DOWNSTREAM_JOIN_TOKEN=$(printf '%s' "$TOKEN_OUTPUT" | awk '/token:/ {print $2; exit}')
                    if [ -n "$DOWNSTREAM_JOIN_TOKEN" ]; then
                        log "Generated downstream join token for ${DOWNSTREAM_SPIFFE_ID}"
                    else
                        log "WARN: failed to parse generated downstream join token; downstream agent may not start correctly."
                    fi
                else
                    log "WARN: spire-server binary not available; cannot auto-generate downstream join token."
                fi
            fi
        fi
        if [ -n "$DOWNSTREAM_JOIN_TOKEN" ]; then
            DOWNSTREAM_AGENT_CMD="${DOWNSTREAM_AGENT_CMD} -joinToken ${DOWNSTREAM_JOIN_TOKEN}"
        fi
        start_component "downstream agent" "$DOWNSTREAM_AGENT_CMD"
    else
        log "WARN: downstream agent config $DOWNSTREAM_AGENT_CONFIG not found; skipping embedded SPIRE startup."
    fi

    # Best-effort wait to reduce race window
    if [ -n "${NESTED_SPIRE_WAIT_FOR_SOCKETS:-1}" ]; then
        SOCKET="${NESTED_SPIRE_WORKLOAD_SOCKET:-${RUN_DIR}/workload/agent.sock}"
        wait_for_socket "Downstream SPIRE workload API" "$SOCKET" "${NESTED_SPIRE_WAIT_ATTEMPTS:-30}" "${NESTED_SPIRE_WAIT_SLEEP:-1}" || true
    fi
fi

if [ "$#" -gt 0 ]; then
    exec "$@"
else
    CONFIG_PATH="${CONFIG_PATH:-/etc/serviceradar/poller.json}"
    exec /usr/local/bin/serviceradar-poller -config "$CONFIG_PATH"
fi
