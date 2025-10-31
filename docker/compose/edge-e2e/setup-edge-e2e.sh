#!/usr/bin/env bash
set -euo pipefail

# Edge E2E Onboarding Setup Script
# This script automates the full edge onboarding flow for E2E testing.
#
# Usage:
#   ./setup-edge-e2e.sh <download-url>
#   ./setup-edge-e2e.sh --package-id <uuid>
#
# Options:
#   --package-id <uuid>     Package UUID to download from Core
#   --core-url <url>        Core URL (default: http://23.138.124.18:8090)
#   --token <token>         JWT token for authentication
#   --poller-id <id>        Override poller ID (auto-generated from SPIFFE ID if not set)
#   --skip-download         Skip download, use existing package in tmp/
#   --clean                 Clean up existing deployment before setup
#   -h, --help             Show this help message

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
COMPOSE_DIR="${REPO_ROOT}/docker/compose"
TMP_DIR="${REPO_ROOT}/tmp/edge-onboarding"

# Defaults
CORE_URL="http://23.138.124.18:8090"
PACKAGE_ID=""
DOWNLOAD_URL=""
JWT_TOKEN=""
POLLER_ID_OVERRIDE=""
SKIP_DOWNLOAD=0
CLEAN=0

print_help() {
  grep '^#' "${BASH_SOURCE[0]}" | grep -v '#!/' | sed 's/^# \{0,1\}//'
}

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

error() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --package-id)
      PACKAGE_ID="$2"
      shift 2
      ;;
    --core-url)
      CORE_URL="$2"
      shift 2
      ;;
    --token)
      JWT_TOKEN="$2"
      shift 2
      ;;
    --poller-id)
      POLLER_ID_OVERRIDE="$2"
      shift 2
      ;;
    --skip-download)
      SKIP_DOWNLOAD=1
      shift
      ;;
    --clean)
      CLEAN=1
      shift
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    *)
      if [[ -z "${DOWNLOAD_URL}" ]]; then
        DOWNLOAD_URL="$1"
      else
        error "Unknown argument: $1"
      fi
      shift
      ;;
  esac
done

# Build download URL if package ID provided
if [[ -n "${PACKAGE_ID}" ]] && [[ -z "${DOWNLOAD_URL}" ]]; then
  DOWNLOAD_URL="${CORE_URL}/api/admin/edge-packages/${PACKAGE_ID}/download"
fi

# Validate inputs
if [[ "${SKIP_DOWNLOAD}" -eq 0 ]] && [[ -z "${DOWNLOAD_URL}" ]]; then
  error "Must provide --package-id or download URL, or use --skip-download"
fi

# Clean up if requested
if [[ "${CLEAN}" -eq 1 ]]; then
  log "Cleaning up existing deployment..."
  cd "${COMPOSE_DIR}"
  docker compose -f poller-stack.compose.yml down 2>/dev/null || true
  docker volume rm compose_poller-spire-runtime compose_poller-generated-config 2>/dev/null || true
fi

# Create tmp directory
mkdir -p "${TMP_DIR}"

# Download package
if [[ "${SKIP_DOWNLOAD}" -eq 0 ]]; then
  log "Downloading edge package from: ${DOWNLOAD_URL}"
  PACKAGE_FILE="${TMP_DIR}/edge-package.tar.gz"

  CURL_ARGS=(-L -o "${PACKAGE_FILE}")
  if [[ -n "${JWT_TOKEN}" ]]; then
    CURL_ARGS+=(-H "Authorization: Bearer ${JWT_TOKEN}")
  fi

  if ! curl "${CURL_ARGS[@]}" "${DOWNLOAD_URL}"; then
    error "Failed to download package"
  fi

  log "Package downloaded to: ${PACKAGE_FILE}"

  # Extract package
  log "Extracting package..."
  cd "${TMP_DIR}"
  tar -xzf edge-package.tar.gz

  # Verify required files
  for file in edge-poller.env metadata.json spire/upstream-join-token spire/upstream-bundle.pem; do
    if [[ ! -f "${file}" ]]; then
      error "Missing required file in package: ${file}"
    fi
  done

  log "Package extracted successfully"
fi

# Verify env file exists
ENV_FILE="${TMP_DIR}/edge-poller.env"
if [[ ! -f "${ENV_FILE}" ]]; then
  error "edge-poller.env not found at: ${ENV_FILE}"
fi

log "Using env file: ${ENV_FILE}"

# Update env file with correct addresses
log "Updating environment file with LoadBalancer IPs..."

# Backup original
cp "${ENV_FILE}" "${ENV_FILE}.backup"

# Replace DNS names with LoadBalancer IPs
sed -i 's|CORE_ADDRESS=serviceradar-core:50052|CORE_ADDRESS=23.138.124.18:50052|g' "${ENV_FILE}"
sed -i 's|KV_ADDRESS=serviceradar-datasvc:50057|KV_ADDRESS=23.138.124.23:50057|g' "${ENV_FILE}"
sed -i 's|POLLERS_SPIRE_UPSTREAM_ADDRESS=spire-server.demo.svc.cluster.local|POLLERS_SPIRE_UPSTREAM_ADDRESS=23.138.124.18|g' "${ENV_FILE}"
sed -i 's|POLLERS_SPIRE_UPSTREAM_PORT=8081|POLLERS_SPIRE_UPSTREAM_PORT=18081|g' "${ENV_FILE}"

# Change agent address to localhost since they share network namespace
sed -i 's|POLLERS_AGENT_ADDRESS=agent:50051|POLLERS_AGENT_ADDRESS=localhost:50051|g' "${ENV_FILE}"

# Add poller ID override if not already present
if ! grep -q "^POLLERS_POLLER_ID=" "${ENV_FILE}"; then
  # Extract a readable ID from the SPIFFE ID if not provided
  if [[ -z "${POLLER_ID_OVERRIDE}" ]]; then
    POLLER_ID_OVERRIDE=$(grep "POLLERS_SPIRE_DOWNSTREAM_SPIFFE_ID=" "${ENV_FILE}" | cut -d'=' -f2 | rev | cut -d'/' -f1 | rev)
  fi

  if [[ -n "${POLLER_ID_OVERRIDE}" ]]; then
    log "Adding POLLERS_POLLER_ID=${POLLER_ID_OVERRIDE}"
    echo "POLLERS_POLLER_ID=${POLLER_ID_OVERRIDE}" >> "${ENV_FILE}"
  fi
fi

log "Environment file updated"

# Copy SPIRE credentials to compose directory
log "Copying SPIRE credentials..."
mkdir -p "${COMPOSE_DIR}/spire"
cp -f "${TMP_DIR}/spire/upstream-join-token" "${COMPOSE_DIR}/spire/"
cp -f "${TMP_DIR}/spire/upstream-bundle.pem" "${COMPOSE_DIR}/spire/"
log "SPIRE credentials copied"

# Run edge-poller-restart.sh
log "Running edge-poller-restart.sh..."
cd "${COMPOSE_DIR}"
bash edge-poller-restart.sh --env-file "${ENV_FILE}"

log "Edge E2E setup complete!"
log ""
log "Next steps:"
log "  1. Check poller logs: docker logs serviceradar-poller"
log "  2. Check agent logs: docker logs serviceradar-agent"
log "  3. Verify poller is registered in Core"
log ""
log "Package location: ${TMP_DIR}"
log "Environment file: ${ENV_FILE}"
