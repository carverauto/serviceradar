#!/usr/bin/env sh
set -eu

SPIRE_VERSION="${SPIRE_VERSION:-1.11.2}"
SPIRE_BIN_DIR="${SPIRE_BIN_DIR:-/spire/bin}"
SPIRE_ARCHIVE="${SPIRE_DOWNLOAD_ARCHIVE:-spire-${SPIRE_VERSION}-linux-amd64-musl.tar.gz}"
SPIRE_DOWNLOAD_URL="${SPIRE_DOWNLOAD_URL:-https://github.com/spiffe/spire/releases/download/v${SPIRE_VERSION}/${SPIRE_ARCHIVE}}"
SERVER_BIN="${SPIRE_SERVER_BIN:-${SPIRE_BIN_DIR}/spire-server}"
SERVER_SOCKET="${SPIRE_SERVER_SOCKET:-/run/spire/server/api.sock}"
TRUST_DOMAIN="${SPIRE_TRUST_DOMAIN:-carverauto.dev}"
PARENT_ID="${SPIRE_WORKLOAD_PARENT_ID:-}"
AGENT_ID="${SPIRE_AGENT_SPIFFE_ID:-}"
TOKEN_FILE="${SPIRE_AGENT_JOIN_TOKEN_FILE:-/spire/bootstrap/join_token}"
WAIT_ATTEMPTS="${SPIRE_BOOTSTRAP_ATTEMPTS:-60}"
WAIT_SLEEP="${SPIRE_BOOTSTRAP_SLEEP_SECONDS:-2}"

WORKLOADS=$(cat <<'EOF'
core|serviceradar-core
datasvc|serviceradar-datasvc
poller|serviceradar-poller
agent|serviceradar-agent
sync|serviceradar-sync
db-event-writer|serviceradar-db-event-writer
mapper|serviceradar-mapper
otel|serviceradar-otel
flowgger|serviceradar-flowgger
trapd|serviceradar-trapd
zen|serviceradar-zen
snmp-checker|serviceradar-snmp-checker
rperf-client|serviceradar-rperf-client
EOF
)

wait_for_socket() {
    attempt=1
    while [ "$attempt" -le "$WAIT_ATTEMPTS" ]; do
        if [ -S "$SERVER_SOCKET" ]; then
            return 0
        fi
        sleep "$WAIT_SLEEP"
        attempt=$((attempt + 1))
    done
    echo "[spire-bootstrap] ERROR: server socket $SERVER_SOCKET not ready" >&2
    return 1
}

ensure_spire_cli() {
    if [ -x "$SERVER_BIN" ]; then
        return
    fi
    echo "[spire-bootstrap] downloading SPIRE CLI from ${SPIRE_DOWNLOAD_URL}"
    mkdir -p "$SPIRE_BIN_DIR"
    tmp_dir="$(mktemp -d)"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$SPIRE_DOWNLOAD_URL" -o "${tmp_dir}/spire.tgz"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "${tmp_dir}/spire.tgz" "$SPIRE_DOWNLOAD_URL"
    else
        echo "[spire-bootstrap] ERROR: curl or wget required to download SPIRE CLI" >&2
        exit 1
    fi
    tar -xzf "${tmp_dir}/spire.tgz" -C "$tmp_dir"
    found_bin="$(find "$tmp_dir" -name spire-server -type f | head -n1 || true)"
    if [ -z "$found_bin" ]; then
        echo "[spire-bootstrap] ERROR: failed to extract spire-server binary" >&2
        exit 1
    fi
    cp "$found_bin" "$SERVER_BIN"
    chmod +x "$SERVER_BIN"
    echo "[spire-bootstrap] installed spire-server CLI to ${SERVER_BIN}"
    rm -rf "$tmp_dir"
}

ensure_workload_entry() {
    spiffe_id="$1"
    selector="$2"

    if [ -z "$PARENT_ID" ]; then
        echo "[spire-bootstrap] ERROR: workload parent ID is unset; cannot create entry for ${spiffe_id}" >&2
        return 1
    fi

    existing="$($SERVER_BIN entry show -socketPath "$SERVER_SOCKET" -spiffeID "$spiffe_id" 2>/dev/null || true)"
    entry_id="$(printf '%s\n' "$existing" | sed -n 's/^Entry ID[[:space:]]*:[[:space:]]*//p' | head -n1 | tr -d '\r')"

    set -- "$SERVER_BIN" entry
    if [ -n "$entry_id" ]; then
        set -- "$@" update -entryID "$entry_id"
    else
        set -- "$@" create
    fi
    set -- "$@" \
        -socketPath "$SERVER_SOCKET" \
        -spiffeID "$spiffe_id" \
        -parentID "$PARENT_ID" \
        -selector "$selector"

    if "$@"; then
        action="created"
        [ -n "$entry_id" ] && action="updated"
        echo "[spire-bootstrap] ${action} entry for ${spiffe_id}"
    else
        echo "[spire-bootstrap] WARN: failed to ensure entry for ${spiffe_id}" >&2
    fi
}

generate_join_token() {
    if [ -s "$TOKEN_FILE" ] && [ -z "${SPIRE_FORCE_NEW_JOIN_TOKEN:-}" ]; then
        token="$(cat "$TOKEN_FILE" 2>/dev/null | tr -d '[:space:]')"
        if [ -n "$token" ]; then
            echo "[spire-bootstrap] reusing existing join token from ${TOKEN_FILE}"
            if [ -z "${SPIRE_WORKLOAD_PARENT_ID:-}" ]; then
                PARENT_ID="spiffe://${TRUST_DOMAIN}/spire/agent/join_token/${token}"
                echo "[spire-bootstrap] derived workload parent ID ${PARENT_ID}"
            fi
            return
        fi
        echo "[spire-bootstrap] existing join token file empty, generating new token"
    fi

    set -- "$SERVER_BIN" token generate -socketPath "$SERVER_SOCKET"
    if [ -n "$AGENT_ID" ]; then
        set -- "$@" -spiffeID "$AGENT_ID"
    fi
    if ! OUTPUT="$("$@" 2>&1)"; then
        echo "[spire-bootstrap] WARN: failed to generate join token: ${OUTPUT}" >&2
        return
    fi
    token="$(printf '%s\n' "$OUTPUT" | sed -n 's/^Token:[[:space:]]*//p' | head -n1)"
    if [ -z "$token" ]; then
        echo "[spire-bootstrap] WARN: token command succeeded but no token returned" >&2
        return
    fi
    mkdir -p "$(dirname "$TOKEN_FILE")"
    printf '%s\n' "$token" >"$TOKEN_FILE"
    echo "[spire-bootstrap] wrote join token to ${TOKEN_FILE}"
    if [ -z "${SPIRE_WORKLOAD_PARENT_ID:-}" ]; then
        PARENT_ID="spiffe://${TRUST_DOMAIN}/spire/agent/join_token/${token}"
        echo "[spire-bootstrap] derived workload parent ID ${PARENT_ID}"
    fi
}

ensure_spire_cli
wait_for_socket
generate_join_token

printf '%s\n' "$WORKLOADS" | while IFS='|' read -r name binary; do
    [ -z "$name" ] && continue
    spiffe_id="spiffe://${TRUST_DOMAIN}/services/${name}"
    selector="unix:path:/usr/local/bin/${binary}"
    ensure_workload_entry "$spiffe_id" "$selector"
done

echo "[spire-bootstrap] bootstrap complete"
