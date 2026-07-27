#!/usr/bin/env bash
#
# Source this script immediately before a cosign signing command in Forgejo
# Actions. It intentionally exports the OpenBao token only into the current
# shell step instead of writing it to GITHUB_ENV.

set -euo pipefail

# OpenBao was switched to native TLS (ops/openbao-native-tls). Plain HTTP hits
# the TLS listener and fails with HTTP 400 ("client sent an HTTP request to an
# HTTPS server"). Always use HTTPS in-cluster.
: "${OPENBAO_ADDR:=https://openbao-active.openbao-system.svc.cluster.local:8200}"
: "${OPENBAO_K8S_ROLE:=forgejo-runner}"
: "${COSIGN_KEY_REF:=hashivault://cosign-release}"

if [[ -n "${OPENBAO_SIGNING_ALLOWED_REFS_REGEX:-}" ]]; then
  ref="${GITHUB_REF:-}"
  if [[ ! "${ref}" =~ ${OPENBAO_SIGNING_ALLOWED_REFS_REGEX} ]]; then
    echo "OpenBao signing is not allowed for ref '${ref}'." >&2
    exit 1
  fi
fi

# CI signing must use the centrally managed OpenBao key, not a Forgejo-stored
# private key secret. Keep these unset even if older repository secrets exist.
unset COSIGN_PRIVATE_KEY
unset COSIGN_PASSWORD

# Private cluster CA is not mounted into job containers by default. Prefer an
# explicit CA when provided; otherwise skip verification for the in-cluster
# private OpenBao endpoint so cosign/vault can talk Transit over HTTPS.
curl_tls_args=()
if [[ -n "${OPENBAO_CACERT:-${VAULT_CACERT:-}}" ]]; then
  cacert="${OPENBAO_CACERT:-${VAULT_CACERT}}"
  curl_tls_args+=(--cacert "${cacert}")
  export VAULT_CACERT="${cacert}"
  unset VAULT_SKIP_VERIFY || true
else
  curl_tls_args+=(--insecure)
  export VAULT_SKIP_VERIFY=true
fi

sa_token_file="${OPENBAO_K8S_TOKEN_FILE:-/var/run/secrets/kubernetes.io/serviceaccount/token}"

if [[ -f "${sa_token_file}" ]]; then
  vault_token="$(
    curl -fsSL "${curl_tls_args[@]}" \
      -H 'Content-Type: application/json' \
      -d "{\"role\":\"${OPENBAO_K8S_ROLE}\",\"jwt\":\"$(tr -d '\n' < "${sa_token_file}")\"}" \
      "${OPENBAO_ADDR}/v1/auth/kubernetes/login" \
      | jq -er '.auth.client_token'
  )"

  export VAULT_ADDR="${OPENBAO_ADDR}"
  export VAULT_TOKEN="${vault_token}"
  export COSIGN_KEY_REF
  echo "Authenticated to OpenBao for this signing step."
elif [[ -n "${VAULT_TOKEN:-}" && -n "${VAULT_ADDR:-}" && -n "${COSIGN_KEY_REF:-}" ]]; then
  echo "Using runner-provided OpenBao signing environment for this signing step."
else
  echo "No Kubernetes service account token at '${sa_token_file}' and no runner-provided OpenBao signing env; cannot sign OCI artifacts." >&2
  exit 1
fi
