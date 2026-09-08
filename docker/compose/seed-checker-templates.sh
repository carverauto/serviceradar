#!/usr/bin/env bash
# Seed checker templates into NATS KV so edge onboarding can use them.
set -euo pipefail

log() {
    printf '%s\n' "$*" >&2
}

NATS_SERVER="${NATS_SERVER:-tls://serviceradar-nats:4222}"
NATS_CA_FILE="${NATS_CA_FILE:-/etc/serviceradar/certs/root.pem}"
NATS_CERT_FILE="${NATS_CERT_FILE:-/etc/serviceradar/certs/core.pem}"
NATS_KEY_FILE="${NATS_KEY_FILE:-/etc/serviceradar/certs/core-key.pem}"
KV_BUCKET="${KV_BUCKET:-serviceradar-datasvc}"
TEMPLATES_DIR="${TEMPLATES_DIR:-/etc/serviceradar/checker-templates}"
SECURITY_MODE="${SECURITY_MODE:-mtls}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-30}"
SLEEP_SECONDS="${SLEEP_SECONDS:-5}"

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

seed_template() {
    checker_kind="$1"
    source_file="$2"
    mode="${SECURITY_MODE,,}"

    if [ ! -s "${source_file}" ]; then
        log "Template file ${source_file} not found or empty; skipping"
        return 0
    fi

    mode_segment=""
    if [ -n "${mode}" ]; then
        mode_segment="${mode}/"
    fi
    key="templates/checkers/${mode_segment}${checker_kind}.json"

    # Always overwrite templates (they're factory defaults, safe to update)
    log "Seeding checker template (${mode:-spire}): ${key} from ${source_file}"
    if ! nats_cmd kv put "${KV_BUCKET}" "${key}" <"${source_file}"; then
        log "Failed to seed ${key}"
        return 1
    fi
    return 0
}

if ! wait_for_nats; then
    exit 0
fi

# Seed all checker templates from the templates directory
seeded=0
if [ -d "${TEMPLATES_DIR}" ]; then
    for template_file in "${TEMPLATES_DIR}"/*.json; do
        if [ -f "${template_file}" ]; then
            filename=$(basename "${template_file}")
            checker_kind="${filename%.json}"
            if seed_template "${checker_kind}" "${template_file}"; then
                seeded=$((seeded + 1))
            fi
        fi
    done
fi

log "Checker template KV seed complete: ${seeded} templates seeded"
