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

# sync-tenant-ca-to-k8s.sh - Sync tenant CA certificates to Kubernetes secrets
#
# This script creates or updates Kubernetes secrets containing tenant CA certificates.
# It can read from local files or receive certificate data via stdin/arguments.
#
# Usage:
#   ./sync-tenant-ca-to-k8s.sh <tenant-slug> [options]
#
# Options:
#   --namespace NS       Target Kubernetes namespace (default: serviceradar)
#   --cert-file PATH     Path to CA certificate PEM file
#   --key-file PATH      Path to CA private key PEM file
#   --chain-file PATH    Path to CA chain PEM file (optional)
#   --cert-data DATA     Base64-encoded CA certificate
#   --key-data DATA      Base64-encoded CA private key
#   --dry-run            Print secret YAML without applying
#   --help               Show this help message
#
# Examples:
#   # From local files
#   ./sync-tenant-ca-to-k8s.sh acme-corp \
#       --cert-file /etc/serviceradar/certs/tenants/acme-corp/ca.pem \
#       --key-file /etc/serviceradar/certs/tenants/acme-corp/ca-key.pem
#
#   # From base64-encoded data (e.g., from API)
#   ./sync-tenant-ca-to-k8s.sh acme-corp \
#       --cert-data "LS0tLS1CRUdJTi..." \
#       --key-data "LS0tLS1CRUdJTi..."
#
#   # Dry run
#   ./sync-tenant-ca-to-k8s.sh acme-corp --cert-file ca.pem --key-file ca-key.pem --dry-run

set -e

# Default configuration
NAMESPACE="${NAMESPACE:-serviceradar}"
DRY_RUN=false

# Parse arguments
TENANT_SLUG=""
CERT_FILE=""
KEY_FILE=""
CHAIN_FILE=""
CERT_DATA=""
KEY_DATA=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --cert-file)
            CERT_FILE="$2"
            shift 2
            ;;
        --key-file)
            KEY_FILE="$2"
            shift 2
            ;;
        --chain-file)
            CHAIN_FILE="$2"
            shift 2
            ;;
        --cert-data)
            CERT_DATA="$2"
            shift 2
            ;;
        --key-data)
            KEY_DATA="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
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

# Get certificate data
if [ -n "$CERT_FILE" ]; then
    if [ ! -f "$CERT_FILE" ]; then
        echo "Error: Certificate file not found: $CERT_FILE" >&2
        exit 1
    fi
    CERT_B64=$(base64 -w0 < "$CERT_FILE")
elif [ -n "$CERT_DATA" ]; then
    CERT_B64="$CERT_DATA"
else
    echo "Error: Either --cert-file or --cert-data is required" >&2
    exit 1
fi

# Get private key data
if [ -n "$KEY_FILE" ]; then
    if [ ! -f "$KEY_FILE" ]; then
        echo "Error: Private key file not found: $KEY_FILE" >&2
        exit 1
    fi
    KEY_B64=$(base64 -w0 < "$KEY_FILE")
elif [ -n "$KEY_DATA" ]; then
    KEY_B64="$KEY_DATA"
else
    echo "Error: Either --key-file or --key-data is required" >&2
    exit 1
fi

# Get optional chain data
CHAIN_B64=""
if [ -n "$CHAIN_FILE" ] && [ -f "$CHAIN_FILE" ]; then
    CHAIN_B64=$(base64 -w0 < "$CHAIN_FILE")
fi

# Build secret name
SECRET_NAME="tenant-${TENANT_SLUG}-ca"

# Generate secret YAML
generate_secret_yaml() {
    cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: serviceradar
    app.kubernetes.io/component: tenant-ca
    serviceradar.io/tenant: ${TENANT_SLUG}
type: kubernetes.io/tls
data:
  tls.crt: ${CERT_B64}
  tls.key: ${KEY_B64}
EOF

    if [ -n "$CHAIN_B64" ]; then
        echo "  ca-chain.pem: ${CHAIN_B64}"
    fi
}

if [ "$DRY_RUN" = true ]; then
    echo "# Dry run - would apply the following secret:"
    generate_secret_yaml
else
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        echo "Error: kubectl is not installed or not in PATH" >&2
        exit 1
    fi

    # Check if we can access the cluster
    if ! kubectl cluster-info &> /dev/null; then
        echo "Error: Cannot connect to Kubernetes cluster" >&2
        exit 1
    fi

    # Apply the secret
    echo "Creating/updating secret ${SECRET_NAME} in namespace ${NAMESPACE}..."
    generate_secret_yaml | kubectl apply -f -

    echo ""
    echo "Secret ${SECRET_NAME} created/updated successfully!"
    echo ""
    echo "To use this CA in a pod, mount the secret:"
    echo "  volumes:"
    echo "    - name: tenant-ca"
    echo "      secret:"
    echo "        secretName: ${SECRET_NAME}"
    echo "  volumeMounts:"
    echo "    - name: tenant-ca"
    echo "      mountPath: /etc/serviceradar/certs/tenant-ca"
    echo "      readOnly: true"
fi
