#!/usr/bin/env bash
# Seed the poller configuration/template into NATS KV so the Admin API can read it immediately.
set -euo pipefail

log() {
    printf '%s\n' "$*" >&2
}

NATS_SERVER="${NATS_SERVER:-tls://serviceradar-nats:4222}"
NATS_CA_FILE="${NATS_CA_FILE:-/etc/serviceradar/certs/root.pem}"
NATS_CERT_FILE="${NATS_CERT_FILE:-/etc/serviceradar/certs/poller.pem}"
NATS_KEY_FILE="${NATS_KEY_FILE:-/etc/serviceradar/certs/poller-key.pem}"
KV_BUCKET="${KV_BUCKET:-serviceradar-datasvc}"
CONFIG_PATH="${POLLERS_CONFIG_PATH:-/etc/serviceradar/config/poller.json}"
TEMPLATE_KEY="${TEMPLATE_KEY:-templates/poller.json}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-30}"
SLEEP_SECONDS="${SLEEP_SECONDS:-5}"

if [ ! -s "${CONFIG_PATH}" ]; then
    log "poller config ${CONFIG_PATH} not found; skipping KV seed"
    exit 0
fi

if command -v jq >/dev/null 2>&1; then
    POLLER_ID="${POLLERS_POLLER_ID:-$(jq -r '.poller_id // empty' "${CONFIG_PATH}" || true)}"
else
    POLLER_ID="${POLLERS_POLLER_ID:-}"
fi
if [ -z "${POLLER_ID}" ]; then
    POLLER_ID="docker-poller"
fi
CONFIG_KEY="${KV_KEY:-config/pollers/${POLLER_ID}.json}"

nats_cmd() {
    nats --server "${NATS_SERVER}" \
        --tlsca "${NATS_CA_FILE}" \
        --tlscert "${NATS_CERT_FILE}" \
        --tlskey "${NATS_KEY_FILE}" \
        "$@"
}

wait_for_nats() {
    attempt=1
    while [ "${attempt}" -le "${MAX_ATTEMPTS}" ]; do
        if nats_cmd kv ls >/dev/null 2>&1; then
            return 0
        fi
        log "waiting for NATS JetStream (${attempt}/${MAX_ATTEMPTS})..."
        sleep "${SLEEP_SECONDS}"
        attempt=$((attempt + 1))
    done
    log "NATS JetStream unavailable after ${MAX_ATTEMPTS} attempts"
    return 1
}

seed_key() {
    key="$1"
    source_file="$2"
    if [ -z "${key}" ] || [ ! -s "${source_file}" ]; then
        return 0
    }

    if nats_cmd kv get "${KV_BUCKET}" "${key}" >/dev/null 2>&1; then
        log "KV key ${key} already present in bucket ${KV_BUCKET}; skipping"
        return 0
    fi

    log "Seeding ${key} from ${source_file}"
    if ! nats_cmd kv put "${KV_BUCKET}" "${key}" <"${source_file}"; then
        log "Failed to seed ${key}"
        return 1
    fi
    return 0
}

if ! wait_for_nats; then
    exit 0
fi

seed_key "${CONFIG_KEY}" "${CONFIG_PATH}" || exit 1
seed_key "${TEMPLATE_KEY}" "${CONFIG_PATH}" || exit 1

log "Poller KV seed complete"
