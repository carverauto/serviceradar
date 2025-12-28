#!/bin/bash
# Copyright 2025 Carver Automation Corporation.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# generate-tenant-component-cert.sh - Generate edge component certificates for a tenant
#
# This script creates certificates for edge components (pollers, agents, checkers)
# signed by the tenant's intermediate CA. The certificate CN follows the format:
# <component-id>.<partition-id>.<tenant-slug>.serviceradar
#
# Usage:
#   ./generate-tenant-component-cert.sh <tenant-slug> <component-id> <partition-id> [options]
#
# Options:
#   --tenant-ca PATH     Path to tenant CA certificate (default: auto-detect)
#   --tenant-key PATH    Path to tenant CA private key (default: auto-detect)
#   --root-cert PATH     Path to root CA for chain (default: /etc/serviceradar/certs/root.pem)
#   --output-dir PATH    Output directory (default: tenant CA dir/components)
#   --validity-days N    Certificate validity in days (default: 365)
#   --dns-names NAMES    Additional DNS names (comma-separated)
#   --json               Output certificate data as JSON
#   --help               Show this help message
#
# Examples:
#   ./generate-tenant-component-cert.sh acme-corp poller-001 partition-1
#   ./generate-tenant-component-cert.sh acme-corp agent-001 partition-1 --dns-names "agent,localhost"
#   ./generate-tenant-component-cert.sh acme-corp checker-snmp partition-1 --json

set -e

# Default configuration
BASE_CERT_DIR="${BASE_CERT_DIR:-/etc/serviceradar/certs}"
ROOT_CERT="${ROOT_CERT:-$BASE_CERT_DIR/root.pem}"
VALIDITY_DAYS=365
JSON_OUTPUT=false
EXTRA_DNS=""

COUNTRY="US"
STATE="California"
LOCALITY="San Francisco"
ORGANIZATION="ServiceRadar"

# Parse arguments
TENANT_SLUG=""
COMPONENT_ID=""
PARTITION_ID=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --tenant-ca)
            TENANT_CA="$2"
            shift 2
            ;;
        --tenant-key)
            TENANT_KEY="$2"
            shift 2
            ;;
        --root-cert)
            ROOT_CERT="$2"
            shift 2
            ;;
        --output-dir)
            CUSTOM_OUTPUT_DIR="$2"
            shift 2
            ;;
        --validity-days)
            VALIDITY_DAYS="$2"
            shift 2
            ;;
        --dns-names)
            EXTRA_DNS="$2"
            shift 2
            ;;
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        --help|-h)
            head -45 "$0" | tail -35
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            if [ -z "$TENANT_SLUG" ]; then
                TENANT_SLUG="$1"
            elif [ -z "$COMPONENT_ID" ]; then
                COMPONENT_ID="$1"
            elif [ -z "$PARTITION_ID" ]; then
                PARTITION_ID="$1"
            else
                echo "Error: Too many positional arguments" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate required arguments
if [ -z "$TENANT_SLUG" ] || [ -z "$COMPONENT_ID" ] || [ -z "$PARTITION_ID" ]; then
    echo "Error: Missing required arguments" >&2
    echo "Usage: $0 <tenant-slug> <component-id> <partition-id> [options]" >&2
    exit 1
fi

# Auto-detect tenant CA paths if not specified
TENANT_CA_DIR="$BASE_CERT_DIR/tenants/$TENANT_SLUG"
TENANT_CA="${TENANT_CA:-$TENANT_CA_DIR/ca.pem}"
TENANT_KEY="${TENANT_KEY:-$TENANT_CA_DIR/ca-key.pem}"

# Check tenant CA exists
if [ ! -f "$TENANT_CA" ]; then
    echo "Error: Tenant CA certificate not found: $TENANT_CA" >&2
    echo "Generate the tenant CA first using generate-tenant-ca.sh" >&2
    exit 1
fi

if [ ! -f "$TENANT_KEY" ]; then
    echo "Error: Tenant CA private key not found: $TENANT_KEY" >&2
    exit 1
fi

# Set output directory
OUTPUT_DIR="${CUSTOM_OUTPUT_DIR:-$TENANT_CA_DIR/components}"
CERT_NAME="${COMPONENT_ID}-${PARTITION_ID}"

# Check if certificate already exists
if [ -f "$OUTPUT_DIR/$CERT_NAME.pem" ]; then
    if [ "$JSON_OUTPUT" = true ]; then
        CN=$(openssl x509 -in "$OUTPUT_DIR/$CERT_NAME.pem" -noout -subject | sed 's/.*CN = //')
        NOT_BEFORE=$(openssl x509 -in "$OUTPUT_DIR/$CERT_NAME.pem" -noout -startdate | cut -d= -f2)
        NOT_AFTER=$(openssl x509 -in "$OUTPUT_DIR/$CERT_NAME.pem" -noout -enddate | cut -d= -f2)
        SERIAL=$(openssl x509 -in "$OUTPUT_DIR/$CERT_NAME.pem" -noout -serial | cut -d= -f2)

        cat <<EOF
{
  "status": "exists",
  "tenant_slug": "$TENANT_SLUG",
  "component_id": "$COMPONENT_ID",
  "partition_id": "$PARTITION_ID",
  "subject_cn": "$CN",
  "serial_number": "$SERIAL",
  "not_before": "$NOT_BEFORE",
  "not_after": "$NOT_AFTER",
  "certificate_path": "$OUTPUT_DIR/$CERT_NAME.pem",
  "private_key_path": "$OUTPUT_DIR/$CERT_NAME-key.pem"
}
EOF
    else
        echo "Component certificate for $CERT_NAME already exists at $OUTPUT_DIR/$CERT_NAME.pem"
    fi
    exit 0
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Certificate CN
CN="${COMPONENT_ID}.${PARTITION_ID}.${TENANT_SLUG}.serviceradar"
SPIFFE_ID="spiffe://serviceradar.local/${COMPONENT_ID}/${TENANT_SLUG}/${PARTITION_ID}"

# Build SAN list
SAN="DNS:$CN,DNS:${COMPONENT_ID}.serviceradar,DNS:localhost,IP:127.0.0.1,URI:$SPIFFE_ID"
if [ -n "$EXTRA_DNS" ]; then
    for dns in $(echo "$EXTRA_DNS" | tr ',' ' '); do
        SAN="${SAN},DNS:${dns}"
    done
fi

# Generate private key
openssl genrsa -out "$OUTPUT_DIR/$CERT_NAME-key.pem" 2048 2>/dev/null

# Create certificate config
cat > "$OUTPUT_DIR/$CERT_NAME.conf" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
C = $COUNTRY
ST = $STATE
L = $LOCALITY
O = $ORGANIZATION
OU = Tenant-$TENANT_SLUG
CN = $CN

[v3_req]
basicConstraints = CA:FALSE
keyUsage = keyEncipherment, dataEncipherment, digitalSignature
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = $SAN
EOF

# Generate CSR
openssl req -new -sha256 -key "$OUTPUT_DIR/$CERT_NAME-key.pem" \
    -out "$OUTPUT_DIR/$CERT_NAME.csr" -config "$OUTPUT_DIR/$CERT_NAME.conf" 2>/dev/null

# Sign with tenant CA
openssl x509 -req -in "$OUTPUT_DIR/$CERT_NAME.csr" -CA "$TENANT_CA" \
    -CAkey "$TENANT_KEY" -CAcreateserial -out "$OUTPUT_DIR/$CERT_NAME.pem" \
    -days "$VALIDITY_DAYS" -sha256 -extensions v3_req -extfile "$OUTPUT_DIR/$CERT_NAME.conf" 2>/dev/null

# Create full chain (component cert + tenant CA + root CA)
if [ -f "$ROOT_CERT" ]; then
    cat "$OUTPUT_DIR/$CERT_NAME.pem" "$TENANT_CA" "$ROOT_CERT" > "$OUTPUT_DIR/$CERT_NAME-chain.pem"
else
    cat "$OUTPUT_DIR/$CERT_NAME.pem" "$TENANT_CA" > "$OUTPUT_DIR/$CERT_NAME-chain.pem"
fi

# Clean up temporary files
rm -f "$OUTPUT_DIR/$CERT_NAME.csr" "$OUTPUT_DIR/$CERT_NAME.conf"

# Set secure permissions
chmod 644 "$OUTPUT_DIR/$CERT_NAME.pem" "$OUTPUT_DIR/$CERT_NAME-chain.pem"
chmod 600 "$OUTPUT_DIR/$CERT_NAME-key.pem"

# Extract certificate info
NOT_BEFORE=$(openssl x509 -in "$OUTPUT_DIR/$CERT_NAME.pem" -noout -startdate | cut -d= -f2)
NOT_AFTER=$(openssl x509 -in "$OUTPUT_DIR/$CERT_NAME.pem" -noout -enddate | cut -d= -f2)
SERIAL=$(openssl x509 -in "$OUTPUT_DIR/$CERT_NAME.pem" -noout -serial | cut -d= -f2)

if [ "$JSON_OUTPUT" = true ]; then
    CERT_PEM=$(cat "$OUTPUT_DIR/$CERT_NAME.pem" | sed 's/$/\\n/' | tr -d '\n')
    KEY_PEM=$(cat "$OUTPUT_DIR/$CERT_NAME-key.pem" | sed 's/$/\\n/' | tr -d '\n')
    CHAIN_PEM=$(cat "$OUTPUT_DIR/$CERT_NAME-chain.pem" | sed 's/$/\\n/' | tr -d '\n')

    cat <<EOF
{
  "status": "created",
  "tenant_slug": "$TENANT_SLUG",
  "component_id": "$COMPONENT_ID",
  "partition_id": "$PARTITION_ID",
  "subject_cn": "$CN",
  "spiffe_id": "$SPIFFE_ID",
  "serial_number": "$SERIAL",
  "not_before": "$NOT_BEFORE",
  "not_after": "$NOT_AFTER",
  "validity_days": $VALIDITY_DAYS,
  "certificate_path": "$OUTPUT_DIR/$CERT_NAME.pem",
  "private_key_path": "$OUTPUT_DIR/$CERT_NAME-key.pem",
  "chain_path": "$OUTPUT_DIR/$CERT_NAME-chain.pem",
  "certificate_pem": "$CERT_PEM",
  "private_key_pem": "$KEY_PEM",
  "ca_chain_pem": "$CHAIN_PEM"
}
EOF
else
    echo "Component certificate generated successfully!"
    echo ""
    echo "Tenant:       $TENANT_SLUG"
    echo "Component:    $COMPONENT_ID"
    echo "Partition:    $PARTITION_ID"
    echo "Subject CN:   $CN"
    echo "SPIFFE ID:    $SPIFFE_ID"
    echo "Serial:       $SERIAL"
    echo "Valid from:   $NOT_BEFORE"
    echo "Valid until:  $NOT_AFTER"
    echo ""
    echo "Files created:"
    echo "  Certificate: $OUTPUT_DIR/$CERT_NAME.pem"
    echo "  Private key: $OUTPUT_DIR/$CERT_NAME-key.pem"
    echo "  Full chain:  $OUTPUT_DIR/$CERT_NAME-chain.pem"
fi
