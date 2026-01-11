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

# generate-tenant-ca.sh - Generate per-tenant intermediate CAs for ServiceRadar
#
# This script creates a tenant-specific intermediate CA signed by the platform root CA.
# Tenant CAs are used to sign edge component certificates (gateways, agents, checkers).
#
# Usage:
#   ./generate-tenant-ca.sh <tenant-slug> [options]
#
# Options:
#   --root-cert PATH     Path to root CA certificate (default: /etc/serviceradar/certs/root.pem)
#   --root-key PATH      Path to root CA private key (default: /etc/serviceradar/certs/root-key.pem)
#   --output-dir PATH    Output directory for tenant CA (default: /etc/serviceradar/certs/tenants/<slug>)
#   --validity-years N   CA certificate validity in years (default: 10)
#   --json               Output certificate data as JSON (for API integration)
#   --help               Show this help message
#
# Examples:
#   ./generate-tenant-ca.sh acme-corp
#   ./generate-tenant-ca.sh acme-corp --output-dir /tmp/certs --validity-years 5
#   ./generate-tenant-ca.sh acme-corp --json  # Output JSON for API integration

set -e

# Default configuration
ROOT_CERT="${ROOT_CERT:-/etc/serviceradar/certs/root.pem}"
ROOT_KEY="${ROOT_KEY:-/etc/serviceradar/certs/root-key.pem}"
BASE_OUTPUT_DIR="${BASE_OUTPUT_DIR:-/etc/serviceradar/certs/tenants}"
VALIDITY_YEARS=10
JSON_OUTPUT=false

COUNTRY="US"
STATE="California"
LOCALITY="San Francisco"
ORGANIZATION="ServiceRadar"

# Parse arguments
TENANT_SLUG=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --root-cert)
            ROOT_CERT="$2"
            shift 2
            ;;
        --root-key)
            ROOT_KEY="$2"
            shift 2
            ;;
        --output-dir)
            CUSTOM_OUTPUT_DIR="$2"
            shift 2
            ;;
        --validity-years)
            VALIDITY_YEARS="$2"
            shift 2
            ;;
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        --help|-h)
            head -40 "$0" | tail -30
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            if [ -z "$TENANT_SLUG" ]; then
                TENANT_SLUG="$1"
            else
                echo "Error: Multiple tenant slugs provided" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate tenant slug
if [ -z "$TENANT_SLUG" ]; then
    echo "Error: Tenant slug is required" >&2
    echo "Usage: $0 <tenant-slug> [options]" >&2
    exit 1
fi

# Validate tenant slug format (lowercase alphanumeric and hyphens)
if ! [[ "$TENANT_SLUG" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    echo "Error: Invalid tenant slug format. Use lowercase alphanumeric and hyphens." >&2
    exit 1
fi

# Check root CA exists
if [ ! -f "$ROOT_CERT" ]; then
    echo "Error: Root CA certificate not found: $ROOT_CERT" >&2
    exit 1
fi

if [ ! -f "$ROOT_KEY" ]; then
    echo "Error: Root CA private key not found: $ROOT_KEY" >&2
    exit 1
fi

# Set output directory
OUTPUT_DIR="${CUSTOM_OUTPUT_DIR:-$BASE_OUTPUT_DIR/$TENANT_SLUG}"

# Check if CA already exists
if [ -f "$OUTPUT_DIR/ca.pem" ]; then
    if [ "$JSON_OUTPUT" = true ]; then
        CERT_PEM=$(cat "$OUTPUT_DIR/ca.pem")
        CN=$(openssl x509 -in "$OUTPUT_DIR/ca.pem" -noout -subject | sed 's/.*CN = //')
        NOT_BEFORE=$(openssl x509 -in "$OUTPUT_DIR/ca.pem" -noout -startdate | cut -d= -f2)
        NOT_AFTER=$(openssl x509 -in "$OUTPUT_DIR/ca.pem" -noout -enddate | cut -d= -f2)
        SERIAL=$(openssl x509 -in "$OUTPUT_DIR/ca.pem" -noout -serial | cut -d= -f2)

        cat <<EOF
{
  "status": "exists",
  "tenant_slug": "$TENANT_SLUG",
  "subject_cn": "$CN",
  "serial_number": "$SERIAL",
  "not_before": "$NOT_BEFORE",
  "not_after": "$NOT_AFTER",
  "certificate_path": "$OUTPUT_DIR/ca.pem",
  "private_key_path": "$OUTPUT_DIR/ca-key.pem"
}
EOF
    else
        echo "Tenant CA for $TENANT_SLUG already exists at $OUTPUT_DIR/ca.pem"
    fi
    exit 0
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Calculate validity
DAYS_VALID=$((VALIDITY_YEARS * 365))

# Certificate CN
CN="tenant-${TENANT_SLUG}.ca.serviceradar"

# Generate private key
openssl genrsa -out "$OUTPUT_DIR/ca-key.pem" 4096 2>/dev/null

# Create CA config
cat > "$OUTPUT_DIR/ca.conf" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_ca
prompt = no

[req_distinguished_name]
C = $COUNTRY
ST = $STATE
L = $LOCALITY
O = $ORGANIZATION
OU = Tenant-$TENANT_SLUG
CN = $CN

[v3_ca]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF

# Generate CSR
openssl req -new -sha256 -key "$OUTPUT_DIR/ca-key.pem" \
    -out "$OUTPUT_DIR/ca.csr" -config "$OUTPUT_DIR/ca.conf" 2>/dev/null

# Sign with root CA (intermediate CA)
openssl x509 -req -in "$OUTPUT_DIR/ca.csr" -CA "$ROOT_CERT" \
    -CAkey "$ROOT_KEY" -CAcreateserial -out "$OUTPUT_DIR/ca.pem" \
    -days "$DAYS_VALID" -sha256 -extensions v3_ca -extfile "$OUTPUT_DIR/ca.conf" 2>/dev/null

# Create CA chain (tenant CA + root CA)
cat "$OUTPUT_DIR/ca.pem" "$ROOT_CERT" > "$OUTPUT_DIR/ca-chain.pem"

# Clean up temporary files
rm -f "$OUTPUT_DIR/ca.csr" "$OUTPUT_DIR/ca.conf"

# Set secure permissions
chmod 644 "$OUTPUT_DIR/ca.pem" "$OUTPUT_DIR/ca-chain.pem"
chmod 600 "$OUTPUT_DIR/ca-key.pem"

# Extract certificate info
NOT_BEFORE=$(openssl x509 -in "$OUTPUT_DIR/ca.pem" -noout -startdate | cut -d= -f2)
NOT_AFTER=$(openssl x509 -in "$OUTPUT_DIR/ca.pem" -noout -enddate | cut -d= -f2)
SERIAL=$(openssl x509 -in "$OUTPUT_DIR/ca.pem" -noout -serial | cut -d= -f2)

if [ "$JSON_OUTPUT" = true ]; then
    CERT_PEM=$(cat "$OUTPUT_DIR/ca.pem" | sed 's/$/\\n/' | tr -d '\n')
    KEY_PEM=$(cat "$OUTPUT_DIR/ca-key.pem" | sed 's/$/\\n/' | tr -d '\n')

    cat <<EOF
{
  "status": "created",
  "tenant_slug": "$TENANT_SLUG",
  "subject_cn": "$CN",
  "serial_number": "$SERIAL",
  "not_before": "$NOT_BEFORE",
  "not_after": "$NOT_AFTER",
  "validity_years": $VALIDITY_YEARS,
  "certificate_path": "$OUTPUT_DIR/ca.pem",
  "private_key_path": "$OUTPUT_DIR/ca-key.pem",
  "chain_path": "$OUTPUT_DIR/ca-chain.pem",
  "certificate_pem": "$CERT_PEM",
  "private_key_pem": "$KEY_PEM"
}
EOF
else
    echo "Tenant CA generated successfully!"
    echo ""
    echo "Tenant:      $TENANT_SLUG"
    echo "Subject CN:  $CN"
    echo "Serial:      $SERIAL"
    echo "Valid from:  $NOT_BEFORE"
    echo "Valid until: $NOT_AFTER"
    echo ""
    echo "Files created:"
    echo "  Certificate: $OUTPUT_DIR/ca.pem"
    echo "  Private key: $OUTPUT_DIR/ca-key.pem"
    echo "  CA chain:    $OUTPUT_DIR/ca-chain.pem"
fi
