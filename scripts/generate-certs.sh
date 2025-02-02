#!/bin/bash
# generate_certs.sh
# Script to generate self-signed certificates for ServiceRadar components

set -e

# Default values
CERT_DIR="/etc/serviceradar/certs"
DAYS_VALID=365
RSA_BITS=2048
COUNTRY="US"
STATE="CA"
LOCALITY="San Francisco"
ORGANIZATION="ServiceRadar"
ORGANIZATIONAL_UNIT="DevOps"
COMMON_NAME="serviceradar.local"

# Help text
usage() {
    echo "Usage: $0 [-d cert_dir] [-v days_valid]"
    echo "  -d: Directory to store certificates (default: /etc/serviceradar/certs)"
    echo "  -v: Days certificates are valid (default: 365)"
    exit 1
}

# Parse command line options
while getopts "d:v:h" opt; do
    case $opt in
        d) CERT_DIR="$OPTARG" ;;
        v) DAYS_VALID="$OPTARG" ;;
        h) usage ;;
        \?) usage ;;
    esac
done

# Create certificate directory if it doesn't exist
mkdir -p "${CERT_DIR}"
chmod 700 "${CERT_DIR}"

# Generate CA key and certificate
echo "Generating CA key and certificate..."
openssl req -x509 -new -newkey rsa:${RSA_BITS} -nodes \
    -keyout "${CERT_DIR}/ca.key" \
    -out "${CERT_DIR}/ca.crt" \
    -days "${DAYS_VALID}" \
    -subj "/C=${COUNTRY}/ST=${STATE}/L=${LOCALITY}/O=${ORGANIZATION}/OU=${ORGANIZATIONAL_UNIT}/CN=${COMMON_NAME} CA"

chmod 600 "${CERT_DIR}/ca.key"
chmod 644 "${CERT_DIR}/ca.crt"

# Function to generate a key and CSR
generate_cert() {
    local name=$1
    local cn=$2

    echo "Generating ${name} key and CSR..."
    openssl req -new -newkey rsa:${RSA_BITS} -nodes \
        -keyout "${CERT_DIR}/${name}.key" \
        -out "${CERT_DIR}/${name}.csr" \
        -subj "/C=${COUNTRY}/ST=${STATE}/L=${LOCALITY}/O=${ORGANIZATION}/OU=${ORGANIZATIONAL_UNIT}/CN=${cn}"

    echo "Signing ${name} certificate..."
    openssl x509 -req \
        -in "${CERT_DIR}/${name}.csr" \
        -CA "${CERT_DIR}/ca.crt" \
        -CAkey "${CERT_DIR}/ca.key" \
        -CAcreateserial \
        -out "${CERT_DIR}/${name}.crt" \
        -days "${DAYS_VALID}" \
        -extfile <(cat <<EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=DNS:${cn},DNS:localhost,IP:127.0.0.1
EOF
)

    # Clean up CSR
    rm "${CERT_DIR}/${name}.csr"

    # Set permissions
    chmod 600 "${CERT_DIR}/${name}.key"
    chmod 644 "${CERT_DIR}/${name}.crt"
}

# Generate certificates for each component
generate_cert "cloud" "cloud.serviceradar.local"
generate_cert "poller" "poller.serviceradar.local"
generate_cert "agent" "agent.serviceradar.local"

echo "
Certificate generation complete! The following files have been created in ${CERT_DIR}:

CA Certificate:
- ca.crt (Certificate Authority certificate)
- ca.key (Certificate Authority private key)

Cloud Service:
- cloud.crt (Cloud service certificate)
- cloud.key (Cloud service private key)

Poller Service:
- poller.crt (Poller service certificate)
- poller.key (Poller service private key)

Agent Service:
- agent.crt (Agent service certificate)
- agent.key (Agent service private key)

To use these certificates, update your service configurations with:

security:
  mode: mtls
  cert_dir: ${CERT_DIR}

Make sure to distribute the CA certificate (ca.crt) to all nodes, and the respective
key pairs to each service.
"