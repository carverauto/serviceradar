#!/bin/bash
# Start web-ng in local dev mode against the CNPG cluster in Kubernetes
#
# Usage: ./dev-k8s.sh [namespace] [context]
#
# This script:
# 1. Extracts the CA cert and DB credentials from K8s secrets
# 2. Starts a port-forward to the cnpg-rw service
# 3. Launches Phoenix with the correct CNPG_* env vars
#
# Prerequisites:
#   - kubectl configured with access to the cluster
#   - Elixir/Erlang installed locally
#   - mix deps.get already run

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Configurable
NAMESPACE="${1:-demo}"
KUBE_CONTEXT="${2:-}"
LOCAL_PORT="${CNPG_LOCAL_PORT:-15432}"
CERT_DIR="$SCRIPT_DIR/.local-dev-certs"
CNPG_SERVICE="svc/cnpg-rw"
CNPG_CA_SECRET="cnpg-ca"
CNPG_CRED_SECRET="serviceradar-db-credentials"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Build kubectl command with optional context
KUBECTL="kubectl"
if [ -n "$KUBE_CONTEXT" ]; then
    KUBECTL="kubectl --context $KUBE_CONTEXT"
fi

cleanup() {
    echo ""
    echo -e "${CYAN}Cleaning up...${NC}"
    if [ -n "$PF_PID" ] && kill -0 "$PF_PID" 2>/dev/null; then
        kill "$PF_PID" 2>/dev/null || true
        wait "$PF_PID" 2>/dev/null || true
        echo -e "  ${GREEN}Port-forward stopped${NC}"
    fi
    echo "Done."
}
trap cleanup EXIT INT TERM

echo "=========================================="
echo " ServiceRadar Web-NG (K8s Dev Mode)"
echo "=========================================="
echo ""

# --- Prerequisites ---
echo -e "${CYAN}Checking prerequisites...${NC}"

if ! command -v kubectl &>/dev/null; then
    echo -e "${RED}Error: kubectl not found${NC}"
    exit 1
fi

if ! command -v mix &>/dev/null; then
    echo -e "${RED}Error: mix not found (install Elixir)${NC}"
    exit 1
fi

# Verify cluster access
if ! $KUBECTL get ns "$NAMESPACE" &>/dev/null; then
    echo -e "${RED}Error: Cannot access namespace '$NAMESPACE'${NC}"
    echo "Check your kubectl context and permissions."
    exit 1
fi
echo -e "  ${GREEN}kubectl OK, namespace '$NAMESPACE' accessible${NC}"
echo ""

# --- Extract CA Certificate ---
echo -e "${CYAN}Extracting CA certificate...${NC}"
mkdir -p "$CERT_DIR"

$KUBECTL get secret "$CNPG_CA_SECRET" -n "$NAMESPACE" \
    -o jsonpath='{.data.ca\.crt}' | base64 -d > "$CERT_DIR/root.pem"

if [ ! -s "$CERT_DIR/root.pem" ]; then
    echo -e "${RED}Error: Failed to extract CA cert from secret '$CNPG_CA_SECRET'${NC}"
    exit 1
fi
echo -e "  ${GREEN}CA cert -> $CERT_DIR/root.pem${NC}"

# --- Extract DB Credentials ---
echo -e "${CYAN}Extracting database credentials...${NC}"

DB_USERNAME=$($KUBECTL get secret "$CNPG_CRED_SECRET" -n "$NAMESPACE" \
    -o jsonpath='{.data.username}' | base64 -d)
DB_PASSWORD=$($KUBECTL get secret "$CNPG_CRED_SECRET" -n "$NAMESPACE" \
    -o jsonpath='{.data.password}' | base64 -d)

if [ -z "$DB_USERNAME" ] || [ -z "$DB_PASSWORD" ]; then
    echo -e "${RED}Error: Failed to extract credentials from secret '$CNPG_CRED_SECRET'${NC}"
    exit 1
fi
echo -e "  ${GREEN}Username: $DB_USERNAME${NC}"
echo -e "  ${GREEN}Password: ****${NC}"
echo ""

# --- Start Port Forward ---
echo -e "${CYAN}Starting port-forward ($CNPG_SERVICE $LOCAL_PORT:5432)...${NC}"

$KUBECTL port-forward "$CNPG_SERVICE" "$LOCAL_PORT:5432" -n "$NAMESPACE" &
PF_PID=$!

# Wait for port-forward to be ready
echo -n "  Waiting for port-forward..."
for i in $(seq 1 20); do
    if nc -z localhost "$LOCAL_PORT" 2>/dev/null; then
        echo -e " ${GREEN}OK${NC}"
        break
    fi
    if ! kill -0 "$PF_PID" 2>/dev/null; then
        echo -e " ${RED}FAILED (port-forward process died)${NC}"
        exit 1
    fi
    sleep 0.5
    echo -n "."
done

if ! nc -z localhost "$LOCAL_PORT" 2>/dev/null; then
    echo -e " ${RED}FAILED (timeout)${NC}"
    exit 1
fi
echo ""

# --- Configure Environment ---
export CNPG_HOST="localhost"
export CNPG_PORT="$LOCAL_PORT"
export CNPG_DATABASE="${CNPG_DATABASE:-serviceradar}"
export CNPG_USERNAME="$DB_USERNAME"
export CNPG_PASSWORD="$DB_PASSWORD"
export CNPG_SSL_MODE="verify-full"
export CNPG_CERT_DIR="$CERT_DIR"
export CNPG_TLS_SERVER_NAME="cnpg-rw"
# No client certs needed — pg_hba uses scram-sha-256, not mTLS client cert auth.
# Explicitly blank these to prevent dev.exs from defaulting to workstation.pem/key.
export CNPG_CERT_FILE=""
export CNPG_KEY_FILE=""

echo -e "${CYAN}Database Configuration:${NC}"
echo "  Host:       $CNPG_HOST:$CNPG_PORT"
echo "  Database:   $CNPG_DATABASE"
echo "  Username:   $CNPG_USERNAME"
echo "  SSL Mode:   $CNPG_SSL_MODE"
echo "  TLS SNI:    $CNPG_TLS_SERVER_NAME"
echo "  Cert Dir:   $CNPG_CERT_DIR"
echo ""

# --- Check DB Connectivity ---
echo -n -e "${CYAN}Testing database connection...${NC} "
if timeout 5 bash -c "echo '' | openssl s_client -connect localhost:$LOCAL_PORT -servername cnpg-rw -CAfile $CERT_DIR/root.pem 2>/dev/null | grep -q 'Verify return code: 0'" 2>/dev/null; then
    echo -e "${GREEN}TLS OK${NC}"
else
    echo -e "${YELLOW}(TLS check skipped - will verify on connect)${NC}"
fi
echo ""

# --- Disable services that aren't available locally ---
# No OTEL collector running locally — disable to avoid noisy gRPC errors
unset OTEL_EXPORTER_OTLP_ENDPOINT

# --- Enable features ---
export SERVICERADAR_GOD_VIEW_ENABLED="true"

# --- Launch Phoenix ---
echo "=========================================="
echo -e "${GREEN}Starting Phoenix server...${NC}"
echo "=========================================="
echo ""

exec mix phx.server
