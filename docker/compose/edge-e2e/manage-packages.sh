#!/usr/bin/env bash
set -euo pipefail

# Edge Package Management Script
# Helps manage edge onboarding packages for E2E testing
#
# Usage:
#   ./manage-packages.sh list
#   ./manage-packages.sh create <name>
#   ./manage-packages.sh revoke <package-id>
#   ./manage-packages.sh delete <package-id>
#   ./manage-packages.sh activate <package-id>
#
# Options:
#   --core-url <url>    Core URL (default: kubectl port-forward or LoadBalancer)
#   --token <token>     JWT token for authentication
#   --json              Output as JSON
#   -h, --help         Show this help message

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
CORE_URL=""
JWT_TOKEN=""
USE_JSON=0
ACTION=""
PACKAGE_ID=""
PACKAGE_NAME=""

print_help() {
  grep '^#' "${BASH_SOURCE[0]}" | grep -v '#!/' | sed 's/^# \{0,1\}//'
}

log() {
  if [[ "${USE_JSON}" -eq 0 ]]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
  fi
}

error() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --core-url)
      CORE_URL="$2"
      shift 2
      ;;
    --token)
      JWT_TOKEN="$2"
      shift 2
      ;;
    --json)
      USE_JSON=1
      shift
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    list|create|revoke|delete|activate)
      ACTION="$1"
      shift
      ;;
    *)
      if [[ "${ACTION}" == "create" ]] && [[ -z "${PACKAGE_NAME}" ]]; then
        PACKAGE_NAME="$1"
      elif [[ -n "${ACTION}" ]] && [[ -z "${PACKAGE_ID}" ]]; then
        PACKAGE_ID="$1"
      else
        error "Unknown argument: $1"
      fi
      shift
      ;;
  esac
done

# Determine Core URL
if [[ -z "${CORE_URL}" ]]; then
  # Try to get Core from kubectl
  if command -v kubectl >/dev/null 2>&1; then
    CORE_IP=$(kubectl -n demo get svc serviceradar-core -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [[ -n "${CORE_IP}" ]]; then
      CORE_URL="http://${CORE_IP}:8090"
      log "Using Core LoadBalancer: ${CORE_URL}"
    else
      # Try ClusterIP
      CORE_URL="http://localhost:8090"
      log "Using localhost (ensure port-forward is active: kubectl port-forward -n demo svc/serviceradar-core 8090:8090)"
    fi
  else
    error "kubectl not found and --core-url not provided"
  fi
fi

# Get auth token if not provided
if [[ -z "${JWT_TOKEN}" ]]; then
  log "No token provided, attempting to get one..."

  # Try to login
  LOGIN_RESPONSE=$(curl -s -X POST "${CORE_URL}/api/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"username":"admin","password":"admin"}' 2>/dev/null || echo "")

  if [[ -n "${LOGIN_RESPONSE}" ]]; then
    JWT_TOKEN=$(echo "${LOGIN_RESPONSE}" | jq -r '.token // empty' 2>/dev/null || echo "")
    if [[ -n "${JWT_TOKEN}" ]]; then
      log "Authenticated successfully"
    fi
  fi

  if [[ -z "${JWT_TOKEN}" ]]; then
    log "Warning: No authentication token available, some operations may fail"
  fi
fi

# Build curl args
CURL_ARGS=(-s)
if [[ -n "${JWT_TOKEN}" ]]; then
  CURL_ARGS+=(-H "Authorization: Bearer ${JWT_TOKEN}")
fi

# Execute action
case "${ACTION}" in
  list)
    log "Fetching edge packages..."
    RESPONSE=$(curl "${CURL_ARGS[@]}" "${CORE_URL}/api/admin/edge-packages")

    if [[ "${USE_JSON}" -eq 1 ]]; then
      echo "${RESPONSE}" | jq '.'
    else
      echo "${RESPONSE}" | jq -r '.packages // [] | .[] | "\(.component_id)  \(.name)  \(.status)  \(.created_at)"' | column -t
    fi
    ;;

  create)
    if [[ -z "${PACKAGE_NAME}" ]]; then
      error "Package name required for create action"
    fi

    log "Creating edge package: ${PACKAGE_NAME}"
    RESPONSE=$(curl "${CURL_ARGS[@]}" -X POST "${CORE_URL}/api/admin/edge-packages" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"${PACKAGE_NAME}\",\"description\":\"E2E test package\",\"metadata\":{}}")

    if [[ "${USE_JSON}" -eq 1 ]]; then
      echo "${RESPONSE}" | jq '.'
    else
      PACKAGE_ID=$(echo "${RESPONSE}" | jq -r '.package.component_id // empty')
      if [[ -n "${PACKAGE_ID}" ]]; then
        log "Package created successfully!"
        log "Package ID: ${PACKAGE_ID}"
        log "Download URL: ${CORE_URL}/api/admin/edge-packages/${PACKAGE_ID}/download"
      else
        log "Response: ${RESPONSE}"
      fi
    fi
    ;;

  revoke)
    if [[ -z "${PACKAGE_ID}" ]]; then
      error "Package ID required for revoke action"
    fi

    log "Revoking package: ${PACKAGE_ID}"
    RESPONSE=$(curl "${CURL_ARGS[@]}" -X POST "${CORE_URL}/api/admin/edge-packages/${PACKAGE_ID}/revoke")

    if [[ "${USE_JSON}" -eq 1 ]]; then
      echo "${RESPONSE}" | jq '.'
    else
      log "Package revoked successfully"
    fi
    ;;

  delete)
    if [[ -z "${PACKAGE_ID}" ]]; then
      error "Package ID required for delete action"
    fi

    log "Deleting package: ${PACKAGE_ID}"
    RESPONSE=$(curl "${CURL_ARGS[@]}" -X DELETE "${CORE_URL}/api/admin/edge-packages/${PACKAGE_ID}")

    if [[ "${USE_JSON}" -eq 1 ]]; then
      echo "${RESPONSE}" | jq '.'
    else
      log "Package deleted successfully"
    fi
    ;;

  activate)
    if [[ -z "${PACKAGE_ID}" ]]; then
      error "Package ID required for activate action"
    fi

    log "Activating package: ${PACKAGE_ID}"
    RESPONSE=$(curl "${CURL_ARGS[@]}" -X POST "${CORE_URL}/api/admin/edge-packages/${PACKAGE_ID}/activate")

    if [[ "${USE_JSON}" -eq 1 ]]; then
      echo "${RESPONSE}" | jq '.'
    else
      log "Package activated successfully"
    fi
    ;;

  *)
    error "Unknown action: ${ACTION}. Use list, create, revoke, delete, or activate"
    ;;
esac
