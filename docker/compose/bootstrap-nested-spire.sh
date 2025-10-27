#!/usr/bin/env bash
set -euo pipefail

# Idempotently ensure the downstream SPIRE entry for the poller's nested server exists.

SPIRE_SERVER_SOCKET="${SPIRE_SERVER_SOCKET:-/spire-server/api.sock}"
TRUST_DOMAIN="${SPIRE_TRUST_DOMAIN:-carverauto.dev}"
NAMESPACE="${SPIRE_NAMESPACE:-serviceradar}"
SERVICE_ACCOUNT="${NESTED_SERVICE_ACCOUNT:-serviceradar-poller}"
PARENT_ID="${NESTED_PARENT_ID:-spiffe://$TRUST_DOMAIN/ns/$NAMESPACE/sa/$SERVICE_ACCOUNT}"
SPIFFE_ID="${NESTED_SPIFFE_ID:-spiffe://$TRUST_DOMAIN/ns/$NAMESPACE/poller-nested-spire}"
CONTAINER_NAME="${NESTED_CONTAINER_NAME:-poller-nested-spire}"
POD_LABEL_KEY="${NESTED_POD_LABEL_KEY:-app}"
POD_LABEL_VALUE="${NESTED_POD_LABEL_VALUE:-serviceradar-poller}"
X509_TTL="${NESTED_X509_TTL:-4h}"
JWT_TTL="${NESTED_JWT_TTL:-30m}"
JOIN_TOKEN_OUTPUT="${NESTED_JOIN_TOKEN_OUTPUT:-}"

USE_JOIN_TOKEN="true"
if [[ -n "${NESTED_SELECTORS:-}" ]]; then
  USE_JOIN_TOKEN="false"
  IFS=',' read -r -a SELECTORS <<<"${NESTED_SELECTORS}"
else
  SELECTORS=(
    "k8s:ns:${NAMESPACE}"
    "k8s:sa:${SERVICE_ACCOUNT}"
    "k8s:pod-label:${POD_LABEL_KEY}:${POD_LABEL_VALUE}"
    "k8s:container-name:${CONTAINER_NAME}"
  )
fi

if spire-server entry show -socketPath "${SPIRE_SERVER_SOCKET}" -spiffeID "${SPIFFE_ID}" >/dev/null 2>&1; then
  echo "Nested SPIRE entry ${SPIFFE_ID} already exists; nothing to do."
  if [[ "$USE_JOIN_TOKEN" == "true" ]]; then
    echo "No new join token generated."
  fi
  exit 0
fi

if [[ "$USE_JOIN_TOKEN" == "true" ]]; then
  echo "Generating downstream join token for ${SPIFFE_ID}..."
  TOKEN_OUTPUT=$(spire-server token generate \
    -socketPath "${SPIRE_SERVER_SOCKET}" \
    -spiffeID "${SPIFFE_ID}" \
    -parentID "${PARENT_ID}" \
    -downstream \
    -ttl "${X509_TTL}" 2>&1)
  TOKEN=$(awk '/token:/ {print $2; exit}' <<< "${TOKEN_OUTPUT}")
  if [[ -z "${TOKEN}" ]]; then
    echo "Failed to generate join token: ${TOKEN_OUTPUT}" >&2
    exit 1
  fi
  if [[ -n "${JOIN_TOKEN_OUTPUT}" ]]; then
    printf '%s\n' "${TOKEN}" > "${JOIN_TOKEN_OUTPUT}"
    echo "Join token written to ${JOIN_TOKEN_OUTPUT}"
  else
    echo "Downstream join token: ${TOKEN}"
  fi
  echo "Registration entry for ${SPIFFE_ID} created via join token."
  exit 0
fi

CMD=(spire-server entry create
  -socketPath "${SPIRE_SERVER_SOCKET}"
  -spiffeID "${SPIFFE_ID}"
  -parentID "${PARENT_ID}"
  -downstream
  -admin
  -storeSVID
  -x509SVIDTTL "${X509_TTL}"
  -jwtSVIDTTL "${JWT_TTL}"
)

for selector in "${SELECTORS[@]}"; do
  CMD+=(-selector "${selector}")
done

echo "Creating downstream SPIRE entry ${SPIFFE_ID} with selectors..."
"${CMD[@]}"
echo "Nested SPIRE entry ${SPIFFE_ID} created."
