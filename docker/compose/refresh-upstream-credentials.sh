#!/usr/bin/env bash
set -euo pipefail

# Generates a fresh upstream join token for the nested poller SPIRE server,
# recreates the downstream registration entry, and optionally refreshes the
# upstream trust bundle so the edge Docker stack can bootstrap without any
# manual kubectl work.
#
# The script assumes kubectl can reach the demo cluster and that the SPIRE
# server is running in the target namespace. All parameters can be overridden
# via flags or environment variables.
#
# Examples:
#   ./refresh-upstream-credentials.sh
#   ./refresh-upstream-credentials.sh --namespace demo --spiffe-id spiffe://carverauto.dev/ns/edge/poller-nested-spire
#   SPIRE_TOKEN_TTL=900 ./refresh-upstream-credentials.sh --no-bundle

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DEFAULT_OUTPUT_DIR="${SCRIPT_DIR}/spire"

KUBECTL_BIN="${KUBECTL:-kubectl}"
SPIRE_NAMESPACE="${SPIRE_NAMESPACE:-demo}"
SPIRE_LABEL_SELECTOR="${SPIRE_LABEL_SELECTOR:-app=spire-server}"
SPIRE_POD_NAME="${SPIRE_POD_NAME:-}"
SPIRE_CONTAINER_NAME="${SPIRE_CONTAINER_NAME:-spire-server}"
TRUST_DOMAIN="${SPIRE_TRUST_DOMAIN:-carverauto.dev}"
NESTED_NAMESPACE="${NESTED_NAMESPACE:-edge}"
NESTED_SPIFFE_ID_DEFAULT="spiffe://${TRUST_DOMAIN}/ns/${NESTED_NAMESPACE}/poller-nested-spire"
NESTED_SPIFFE_ID="${NESTED_SPIFFE_ID:-${NESTED_SPIFFE_ID_DEFAULT}}"
ENTRY_SELECTORS="${SPIRE_ENTRY_SELECTORS:-unix:uid:0,unix:gid:0,unix:user:root,unix:group:root}"
TOKEN_TTL="${SPIRE_TOKEN_TTL:-900}"
OUTPUT_DIR="${OUTPUT_DIR:-${DEFAULT_OUTPUT_DIR}}"
TOKEN_PATH="${TOKEN_PATH:-${OUTPUT_DIR}/upstream-join-token}"
BUNDLE_PATH="${BUNDLE_PATH:-${OUTPUT_DIR}/upstream-bundle.pem}"
FETCH_BUNDLE="${FETCH_BUNDLE:-1}"
X509_SVID_TTL="${SPIRE_X509_TTL:-14400}"
JWT_SVID_TTL="${SPIRE_JWT_TTL:-1800}"

print_help() {
  cat <<EOF
Usage: ${0##*/} [options]

Options:
  -n, --namespace <name>        Kubernetes namespace that hosts SPIRE (default: ${SPIRE_NAMESPACE})
      --pod <name>              Explicit SPIRE server pod name (auto-detected when omitted)
      --container <name>        SPIRE server container name (default: ${SPIRE_CONTAINER_NAME})
      --label-selector <expr>   Pod label selector for auto-detection (default: ${SPIRE_LABEL_SELECTOR})
      --spiffe-id <id>          Downstream SPIRE server SPIFFE ID (default: ${NESTED_SPIFFE_ID_DEFAULT})
      --selectors <list>        Comma-separated selectors for the downstream entry (default: ${ENTRY_SELECTORS})
      --ttl <seconds|duration>  Join token TTL (default: ${TOKEN_TTL})
      --output-dir <path>       Directory for credential artifacts (default: ${OUTPUT_DIR})
      --token-path <path>       Override join-token file path (default: ${TOKEN_PATH})
      --bundle-path <path>      Override upstream bundle path (default: ${BUNDLE_PATH})
      --no-bundle               Skip downloading the upstream trust bundle
      --x509-ttl <seconds>      Downstream X.509 SVID TTL (default: ${X509_SVID_TTL})
      --jwt-ttl <seconds>       Downstream JWT SVID TTL (default: ${JWT_SVID_TTL})
  -h, --help                    Show this help text

Environment overrides:
  KUBECTL             kubectl binary to use (default: kubectl)
  SPIRE_NAMESPACE     Namespace hosting SPIRE (default: demo)
  SPIRE_LABEL_SELECTOR Label selector for SPIRE pods (default: app=spire-server)
  SPIRE_POD_NAME      Explicit pod name (skips auto-detection)
  SPIRE_CONTAINER_NAME Container name inside the pod (default: spire-server)
  SPIRE_TRUST_DOMAIN  Trust domain (default: carverauto.dev)
  NESTED_NAMESPACE    Namespace portion for the downstream SPIFFE ID (default: edge)
  NESTED_SPIFFE_ID    Explicit downstream SPIFFE ID
  SPIRE_ENTRY_SELECTORS Comma-separated selectors (default: unix:uid:0,...)
  SPIRE_TOKEN_TTL     Join token TTL in seconds (default: 900)
  SPIRE_X509_TTL      Downstream X.509 SVID TTL in seconds (default: 14400)
  SPIRE_JWT_TTL       Downstream JWT SVID TTL in seconds (default: 1800)
  OUTPUT_DIR          Artifact directory (default: docker/compose/spire)
  TOKEN_PATH          Explicit token file path
  BUNDLE_PATH         Explicit bundle file path
  FETCH_BUNDLE        Set to 0 to skip bundle download
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--namespace)
        SPIRE_NAMESPACE="$2"
        shift 2
        ;;
      --pod)
        SPIRE_POD_NAME="$2"
        shift 2
        ;;
      --container)
        SPIRE_CONTAINER_NAME="$2"
        shift 2
        ;;
      --label-selector)
        SPIRE_LABEL_SELECTOR="$2"
        shift 2
        ;;
      --spiffe-id)
        NESTED_SPIFFE_ID="$2"
        shift 2
        ;;
      --selectors)
        ENTRY_SELECTORS="$2"
        shift 2
        ;;
      --ttl)
        TOKEN_TTL="$2"
        shift 2
        ;;
      --output-dir)
        OUTPUT_DIR="$2"
        shift 2
        ;;
      --token-path)
        TOKEN_PATH="$2"
        shift 2
        ;;
      --bundle-path)
        BUNDLE_PATH="$2"
        shift 2
        ;;
      --no-bundle)
        FETCH_BUNDLE=0
        shift
        ;;
      --x509-ttl)
        X509_SVID_TTL="$2"
        shift 2
        ;;
      --jwt-ttl)
        JWT_SVID_TTL="$2"
        shift 2
        ;;
      -h|--help)
        print_help
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        print_help >&2
        exit 1
        ;;
    esac
  done
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

detect_spire_pod() {
  if [[ -n "${SPIRE_POD_NAME}" ]]; then
    return
  fi
  SPIRE_POD_NAME="$(${KUBECTL_BIN} get pods -n "${SPIRE_NAMESPACE}" -l "${SPIRE_LABEL_SELECTOR}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "${SPIRE_POD_NAME}" ]]; then
    echo "Failed to locate SPIRE server pod in namespace ${SPIRE_NAMESPACE} with selector ${SPIRE_LABEL_SELECTOR}." >&2
    exit 1
  fi
}

kubectl_exec() {
  "${KUBECTL_BIN}" exec -n "${SPIRE_NAMESPACE}" "${SPIRE_POD_NAME}" -c "${SPIRE_CONTAINER_NAME}" -- "$@"
}

refresh_join_token() {
  local token_output token
  token_output="$(kubectl_exec /opt/spire/bin/spire-server token generate \
    -spiffeID "${NESTED_SPIFFE_ID}" \
    -ttl "${TOKEN_TTL}" \
    -output json || true)"
  token="$(echo "${token_output}" | jq -r '(.token // .value) // empty' 2>/dev/null || true)"
  if [[ -z "${token}" ]]; then
    echo "Failed to generate join token: ${token_output}" >&2
    exit 1
  fi
  printf '%s\n' "${token}"
}

delete_existing_entry() {
  local entry_output entry_id
  entry_output="$(kubectl_exec /opt/spire/bin/spire-server entry show -spiffeID "${NESTED_SPIFFE_ID}" || true)"
  if [[ -z "${entry_output}" ]]; then
    return
  fi
  entry_id="$(awk -F: '/Entry ID/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' <<<"${entry_output}")"
  if [[ -z "${entry_id}" ]]; then
    return
  fi
  kubectl_exec /opt/spire/bin/spire-server entry delete -entryID "${entry_id}" >/dev/null
  echo "Deleted existing downstream entry ${entry_id} for ${NESTED_SPIFFE_ID}."
}

create_downstream_entry() {
  local parent_id selectors_array create_args
  parent_id="spiffe://${TRUST_DOMAIN}/spire/agent/join_token/${1}"
  IFS=',' read -r -a selectors_array <<<"${ENTRY_SELECTORS}"
  create_args=(
    /opt/spire/bin/spire-server entry create
    -spiffeID "${NESTED_SPIFFE_ID}"
    -parentID "${parent_id}"
    -downstream
    -admin
    -x509SVIDTTL "${X509_SVID_TTL}"
    -jwtSVIDTTL "${JWT_SVID_TTL}"
  )
  for selector in "${selectors_array[@]}"; do
    selector_trimmed="${selector//[[:space:]]/}"
    [[ -z "${selector_trimmed}" ]] && continue
    create_args+=(-selector "${selector_trimmed}")
  done
  kubectl_exec "${create_args[@]}" >/dev/null
  echo "Created downstream entry for ${NESTED_SPIFFE_ID} with parent ${parent_id}."
}

write_token_file() {
  mkdir -p "$(dirname "${TOKEN_PATH}")"
  printf '%s\n' "$1" > "${TOKEN_PATH}"
  echo "Join token written to ${TOKEN_PATH}."
}

refresh_bundle() {
  if [[ "${FETCH_BUNDLE}" != "1" ]]; then
    return
  fi
  mkdir -p "$(dirname "${BUNDLE_PATH}")"
  "${KUBECTL_BIN}" get configmap spire-bundle -n "${SPIRE_NAMESPACE}" \
    -o jsonpath='{.data.bundle\.crt}' > "${BUNDLE_PATH}"
  echo "Upstream bundle written to ${BUNDLE_PATH}."
}

main() {
  parse_args "$@"
  require_command "${KUBECTL_BIN}"
  require_command jq
  detect_spire_pod
  token_value="$(refresh_join_token)"
  delete_existing_entry
  create_downstream_entry "${token_value}"
  write_token_file "${token_value}"
  refresh_bundle
  echo "Upstream SPIRE credentials refreshed successfully."
}

main "$@"
