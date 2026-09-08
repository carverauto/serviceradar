#!/bin/bash
# Configure a local NATS context for the ServiceRadar debug tools.
# Defaults target the Docker Compose stack (nats:4222 with mTLS certs mounted
# under /etc/serviceradar/certs), but can be overridden via env vars.
set -euo pipefail

CONTEXT_NAME="${NATS_CONTEXT:-serviceradar}"
CONTEXT_DESC="${NATS_CONTEXT_DESC:-ServiceRadar NATS Context for Debugging}"
CONTEXT_DIR="${NATS_CONTEXT_DIR:-/root/.config/nats/context}"
NATS_URL="${NATS_URL:-tls://nats:4222}"
NATS_CA="${NATS_CA:-/etc/serviceradar/certs/root.pem}"
NATS_CERT="${NATS_CERT:-/etc/serviceradar/certs/datasvc.pem}"
NATS_KEY="${NATS_KEY:-/etc/serviceradar/certs/datasvc-key.pem}"

mkdir -p "${CONTEXT_DIR}"

if command -v nats >/dev/null 2>&1; then
  # Overwrite any stale context with the current endpoints/certs.
  if nats context ls >/dev/null 2>&1; then
    nats context rm "${CONTEXT_NAME}" >/dev/null 2>&1 || true
  fi

  nats context save "${CONTEXT_NAME}" \
    --description "${CONTEXT_DESC}" \
    --server "${NATS_URL}" \
    --tlsca "${NATS_CA}" \
    --tlscert "${NATS_CERT}" \
    --tlskey "${NATS_KEY}" \
    --select \
    >/dev/null 2>&1 || true

  echo "NATS context '${CONTEXT_NAME}' ready for ${NATS_URL}"
else
  # Fallback: write a JSON context file for manual selection.
  cat >"${CONTEXT_DIR}/${CONTEXT_NAME}.json" <<EOF
{
  "description": "${CONTEXT_DESC}",
  "url": "${NATS_URL}",
  "cert": "${NATS_CERT}",
  "key": "${NATS_KEY}",
  "ca": "${NATS_CA}",
  "inbox_prefix": "_INBOX"
}
EOF
  echo "nats CLI not found; wrote context to ${CONTEXT_DIR}/${CONTEXT_NAME}.json"
fi
