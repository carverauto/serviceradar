#!/usr/bin/env bash
set -euo pipefail

# Fetch the sr-testing NATS client credentials into a local temp directory and
# print the environment variables to export for tests.

NAMESPACE=${NAMESPACE:-sr-testing}
SECRET=${SECRET:-sr-testing-nats-tls}
OUT_DIR=${OUT_DIR:-/tmp/sr-testing-nats-env}

mkdir -p "${OUT_DIR}"

kubectl -n "${NAMESPACE}" get secret "${SECRET}" -o json >"${OUT_DIR}/secret.json"

ca_path="${OUT_DIR}/ca.crt"
client_crt_path="${OUT_DIR}/client.crt"
client_key_path="${OUT_DIR}/client.key"

jq -r '.data["ca.crt"]' <"${OUT_DIR}/secret.json" | base64 -d >"${ca_path}"
jq -r '.data["client.crt"]' <"${OUT_DIR}/secret.json" | base64 -d >"${client_crt_path}"
jq -r '.data["client.key"]' <"${OUT_DIR}/secret.json" | base64 -d >"${client_key_path}"

cat <<EOF
Export these before running Bazel/GitHub/BuildBuddy tests locally:

  export NATS_URL="tls://sr-testing-nats.serviceradar.cloud:4222"
  export NATS_CA_FILE="${ca_path}"
  export NATS_CERT_FILE="${client_crt_path}"
  export NATS_KEY_FILE="${client_key_path}"
  export NATS_SERVER_NAME="sr-testing-nats"

Files written to ${OUT_DIR}
EOF
