#!/usr/bin/env sh
set -eu

SPIRE_VERSION="${SPIRE_AGENT_VERSION:-1.11.2}"
SPIRE_BIN_DIR="${SPIRE_AGENT_BIN_DIR:-/spire/bin}"
SPIRE_ARCHIVE="${SPIRE_AGENT_ARCHIVE:-spire-${SPIRE_VERSION}-linux-amd64-musl.tar.gz}"
SPIRE_DOWNLOAD_URL="${SPIRE_AGENT_DOWNLOAD_URL:-https://github.com/spiffe/spire/releases/download/v${SPIRE_VERSION}/${SPIRE_ARCHIVE}}"
BIN="${SPIRE_AGENT_BIN:-${SPIRE_BIN_DIR}/spire-agent}"
CONFIG_FILE="${SPIRE_AGENT_CONFIG:-/spire/config/agent.conf}"
TOKEN_FILE="${SPIRE_AGENT_JOIN_TOKEN_FILE:-/spire/bootstrap/join_token}"
DATA_DIR="${SPIRE_AGENT_DATA_DIR:-/run/spire/data}"
AGENT_DATA_FILE="${SPIRE_AGENT_DATA_FILE:-${DATA_DIR}/agent-data.json}"
SOCKET_PATH="${SPIRE_AGENT_SOCKET:-/run/spire/sockets/agent.sock}"
SOCKET_DIR="$(dirname "$SOCKET_PATH")"

mkdir -p "$DATA_DIR" "$DATA_DIR/keys" "$SOCKET_DIR"
chmod 0777 "$SOCKET_DIR" || true
mkdir -p "$SPIRE_BIN_DIR"

ensure_spire_agent() {
    if [ -x "$BIN" ]; then
        return
    fi
    echo "[spire-agent] ERROR: expected vetted spire-agent binary at ${BIN}" >&2
    echo "[spire-agent] Refusing to download and execute SPIRE agent from ${SPIRE_DOWNLOAD_URL} without integrity verification" >&2
    exit 1
}

ensure_spire_agent

should_use_join_token() {
    if [ ! -s "$TOKEN_FILE" ]; then
        return 1
    fi
    if [ -s "$AGENT_DATA_FILE" ]; then
        if grep -q '"reattestable"[[:space:]]*:[[:space:]]*true' "$AGENT_DATA_FILE" 2>/dev/null; then
            return 1
        fi
        if grep -q '"svid":\["[^"]*"\]' "$AGENT_DATA_FILE" 2>/dev/null; then
            return 1
        fi
    fi
    return 0
}

JOIN_TOKEN=""
if [ -s "$TOKEN_FILE" ]; then
    if should_use_join_token; then
        TOKEN="$(head -n1 "$TOKEN_FILE" | tr -d '\r\n')"
        if [ -n "$TOKEN" ]; then
            echo "[spire-agent] Using join token from ${TOKEN_FILE}"
            JOIN_TOKEN="$TOKEN"
        fi
    else
        echo "[spire-agent] Existing SVID detected; skipping join token"
    fi
else
    echo "[spire-agent] Join token file ${TOKEN_FILE} not found; relying on cached credentials if available"
fi

set -- "$BIN" run -config "$CONFIG_FILE"
if [ -n "$JOIN_TOKEN" ]; then
    set -- "$@" -joinToken "$JOIN_TOKEN"
fi

exec "$@"
