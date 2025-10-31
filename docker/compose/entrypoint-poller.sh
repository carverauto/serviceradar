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
DOWNSTREAM_PARENT_ID_DEFAULT="spiffe://${TRUST_DOMAIN}/ns/edge/poller-nested-spire"
DOWNSTREAM_PARENT_ID="${NESTED_SPIRE_PARENT_ID:-${DOWNSTREAM_PARENT_ID_DEFAULT}}"
DOWNSTREAM_SPIFFE_ID_DEFAULT="spiffe://${TRUST_DOMAIN}/services/poller"
DOWNSTREAM_SPIFFE_ID="${NESTED_SPIRE_DOWNSTREAM_SPIFFE_ID:-${DOWNSTREAM_SPIFFE_ID_DEFAULT}}"
AGENT_SPIFFE_ID_DEFAULT="spiffe://${TRUST_DOMAIN}/services/agent"
AGENT_SPIFFE_ID="${NESTED_SPIRE_AGENT_SPIFFE_ID:-${AGENT_SPIFFE_ID_DEFAULT}}"
POLLER_WORKLOAD_SELECTORS="${NESTED_SPIRE_POLLER_SELECTORS:-unix:uid:0 unix:gid:0 unix:user:root unix:group:root}"
AGENT_WORKLOAD_SELECTORS="${NESTED_SPIRE_AGENT_SELECTORS:-unix:uid:0 unix:gid:0 unix:user:root unix:group:root}"

parse_duration_seconds() {
    value="$1"
    if [ -z "$value" ]; then
        echo ""
        return
    fi
    case "$value" in
        *[!0-9smhd]*)
            echo ""
            return
            ;;
    esac
    case "$value" in
        *[smhd])
            number=${value%?}
            suffix=${value#$number}
            case "$number" in
                ''|*[!0-9]*)
                    echo ""
                    return
                    ;;
            esac
            case "$suffix" in
                s)
                    echo "$number"
                    ;;
                m)
                    echo $(( number * 60 ))
                    ;;
                h)
                    echo $(( number * 3600 ))
                    ;;
                d)
                    echo $(( number * 86400 ))
                    ;;
            esac
            ;;
        *)
            echo "$value"
            ;;
    esac
}

DOWNSTREAM_TOKEN_TTL_DEFAULT="14400"
DOWNSTREAM_TOKEN_TTL_RAW="${NESTED_SPIRE_DOWNSTREAM_TOKEN_TTL:-${DOWNSTREAM_TOKEN_TTL_DEFAULT}}"
DOWNSTREAM_TOKEN_TTL="$(parse_duration_seconds "$DOWNSTREAM_TOKEN_TTL_RAW")"
if [ -z "$DOWNSTREAM_TOKEN_TTL" ]; then
    DOWNSTREAM_TOKEN_TTL="$DOWNSTREAM_TOKEN_TTL_DEFAULT"
    log "WARN: invalid downstream token TTL '${DOWNSTREAM_TOKEN_TTL_RAW}', defaulting to ${DOWNSTREAM_TOKEN_TTL_DEFAULT}s"
fi

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

ensure_workload_entry() {
    spiffe="$1"
    parent="$2"
    selectors="$3"

    log "Ensuring workload entry for ${spiffe} (parent ${parent})"
    if [ -z "$spiffe" ] || [ -z "$parent" ]; then
        return
    fi
    if ! command -v spire-server >/dev/null 2>&1; then
        return
    fi
    if [ ! -S "$SERVER_SOCKET" ]; then
        return
    fi
    if [ -z "$selectors" ]; then
        log "WARN: no selectors provided for workload ${spiffe}; skipping entry creation."
        return
    fi
    set -- $selectors
    entry_args=""
    for sel in "$@"; do
        entry_args="$entry_args -selector $sel"
    done
    existing_entry="$(spire-server entry show -socketPath "$SERVER_SOCKET" -spiffeID "$spiffe" 2>/dev/null || true)"
    if [ -n "$existing_entry" ]; then
        entry_id="$(printf '%s\n' "$existing_entry" | awk -F: '/Entry ID/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')"
        if [ -n "$entry_id" ]; then
            if spire-server entry update -socketPath "$SERVER_SOCKET" -entryID "$entry_id" -spiffeID "$spiffe" -parentID "$parent" $entry_args >/dev/null 2>&1; then
                log "Updated workload entry for ${spiffe} (entry ${entry_id})"
            else
                log "WARN: failed to update workload entry for ${spiffe} (entry ${entry_id})"
            fi
            return
        fi
    fi
    if spire-server entry create -socketPath "$SERVER_SOCKET" -spiffeID "$spiffe" -parentID "$parent" $entry_args >/dev/null 2>&1; then
        log "Created workload entry for ${spiffe}"
    else
        log "WARN: failed to create workload entry for ${spiffe}"
    fi
}

if [ "$MODE" = "spiffe" ] && [ "$MANAGE" = "enabled" ]; then
    mkdir -p "$RUN_DIR/upstream" "$RUN_DIR/upstream-agent" "$RUN_DIR/server" "$RUN_DIR/workload" "$RUN_DIR/downstream-agent"
    UPSTREAM_JOIN_TOKEN="$(resolve_join_token "${NESTED_SPIRE_UPSTREAM_JOIN_TOKEN:-}" "${NESTED_SPIRE_UPSTREAM_JOIN_TOKEN_FILE:-}")"
    UPSTREAM_AGENT_DATA_PATH="${RUN_DIR}/upstream-agent/agent-data.json"
    if [ -n "$UPSTREAM_JOIN_TOKEN" ]; then
        if [ -s "$UPSTREAM_AGENT_DATA_PATH" ] && \
           grep -Eq '"svid":\["[^"]+"' "$UPSTREAM_AGENT_DATA_PATH" 2>/dev/null && \
           grep -Eq '"reattestable":[[:space:]]*true' "$UPSTREAM_AGENT_DATA_PATH" 2>/dev/null; then
            log "Existing reattestable upstream SVID detected; skipping join token flag."
        else
            UPSTREAM_AGENT_CMD="${UPSTREAM_AGENT_CMD} -joinToken ${UPSTREAM_JOIN_TOKEN}"
        fi
    elif [ ! -s "$UPSTREAM_AGENT_DATA_PATH" ]; then
        log "WARN: no upstream join token provided and no cached SVID found; upstream agent may fail to attest."
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
                    TOKEN_OUTPUT=$(spire-server token generate -socketPath "$SERVER_SOCKET" -spiffeID "$DOWNSTREAM_SPIFFE_ID" -ttl "$DOWNSTREAM_TOKEN_TTL" 2>/dev/null || true)
                    DOWNSTREAM_JOIN_TOKEN=$(printf '%s' "$TOKEN_OUTPUT" | awk '/Token:/ {print $2; exit}')
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
            DOWNSTREAM_AGENT_SPIFFE_ID="spiffe://${TRUST_DOMAIN}/spire/agent/join_token/${DOWNSTREAM_JOIN_TOKEN}"
            ensure_workload_entry "$DOWNSTREAM_SPIFFE_ID" "$DOWNSTREAM_AGENT_SPIFFE_ID" "$POLLER_WORKLOAD_SELECTORS"
            ensure_workload_entry "$AGENT_SPIFFE_ID" "$DOWNSTREAM_AGENT_SPIFFE_ID" "$AGENT_WORKLOAD_SELECTORS"
        else
            DOWNSTREAM_AGENT_SPIFFE_ID=""
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
