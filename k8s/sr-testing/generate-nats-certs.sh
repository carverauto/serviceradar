#!/usr/bin/env bash
set -euo pipefail

# Generate self-signed CA, server, and client certificates for the sr-testing NATS fixture
# and create/update the sr-testing-nats-tls secret with those artifacts.

NAMESPACE=${NAMESPACE:-sr-testing}
OUT_DIR=${OUT_DIR:-/tmp/sr-testing-nats-certs}
SERVICE_NAME=${SERVICE_NAME:-sr-testing-nats}
SERVICE_FQDN="${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local"

mkdir -p "${OUT_DIR}"

echo "Generating CA..."
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout "${OUT_DIR}/ca.key" \
  -out "${OUT_DIR}/ca.crt" \
  -subj "/CN=${SERVICE_NAME}-ca"

cat >"${OUT_DIR}/server.cnf" <<EOF
[req]
distinguished_name = dn
req_extensions = v3_req
prompt = no

[dn]
CN = ${SERVICE_NAME}

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${SERVICE_NAME}
DNS.2 = ${SERVICE_FQDN}
DNS.3 = localhost
IP.1 = 127.0.0.1
EOF

echo "Generating server key/cert..."
openssl req -nodes -newkey rsa:2048 \
  -keyout "${OUT_DIR}/server.key" \
  -out "${OUT_DIR}/server.csr" \
  -config "${OUT_DIR}/server.cnf"
openssl x509 -req -in "${OUT_DIR}/server.csr" \
  -CA "${OUT_DIR}/ca.crt" -CAkey "${OUT_DIR}/ca.key" -CAcreateserial \
  -out "${OUT_DIR}/server.crt" -days 3650 -extfile "${OUT_DIR}/server.cnf" -extensions v3_req

cat >"${OUT_DIR}/client.cnf" <<EOF
[req]
distinguished_name = dn
req_extensions = v3_req
prompt = no

[dn]
CN = sr-testing-client

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EOF

echo "Generating client key/cert..."
openssl req -nodes -newkey rsa:2048 \
  -keyout "${OUT_DIR}/client.key" \
  -out "${OUT_DIR}/client.csr" \
  -config "${OUT_DIR}/client.cnf"
openssl x509 -req -in "${OUT_DIR}/client.csr" \
  -CA "${OUT_DIR}/ca.crt" -CAkey "${OUT_DIR}/ca.key" -CAcreateserial \
  -out "${OUT_DIR}/client.crt" -days 3650 -extfile "${OUT_DIR}/client.cnf" -extensions v3_req

echo "Creating/updating secret sr-testing-nats-tls in namespace ${NAMESPACE}..."
kubectl create namespace "${NAMESPACE}" >/dev/null 2>&1 || true
kubectl -n "${NAMESPACE}" create secret generic sr-testing-nats-tls \
  --from-file=ca.crt="${OUT_DIR}/ca.crt" \
  --from-file=server.crt="${OUT_DIR}/server.crt" \
  --from-file=server.key="${OUT_DIR}/server.key" \
  --from-file=client.crt="${OUT_DIR}/client.crt" \
  --from-file=client.key="${OUT_DIR}/client.key" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Done. Artifacts left in ${OUT_DIR}."
