#!/usr/bin/env bash
set -euo pipefail

# Rebuilds and restarts the edge poller/agent stack in SPIFFE mode.
# The script orchestrates volume cleanup, config regeneration, upstream
# credential refresh, and compose restarts so operators can recover from
# expired tokens or stale runtime state with a single command.
#
# Usage:
#   docker/compose/edge-poller-restart.sh [options] [-- <refresh args>]
#
# Options:
#   --env-file <path>      Override the environment file (default: edge-poller.env)
#   --skip-refresh         Skip refreshing upstream credentials (uses existing files)
#   --refresh-only         Refresh credentials then exit (does not touch Compose)
#   --dry-run              Print the steps without executing them
#   -h, --help             Show this message
#
# Any remaining arguments after '--' are forwarded to refresh-upstream-credentials.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/poller-stack.compose.yml"
DEFAULT_ENV_FILE="${REPO_ROOT}/edge-poller.env"
REFRESH_SCRIPT="${SCRIPT_DIR}/refresh-upstream-credentials.sh"
SETUP_SCRIPT="${SCRIPT_DIR}/setup-edge-poller.sh"
TEMPLATE_DIR="${REPO_ROOT}/packaging/core/config"

ENV_FILE="${DEFAULT_ENV_FILE}"
REFRESH=1
REFRESH_ONLY=0
DRY_RUN=0
REFRESH_ARGS=()

print_help() {
  grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      ENV_FILE="$2"
      shift 2
      ;;
    --skip-refresh)
      REFRESH=0
      shift
      ;;
    --refresh-only)
      REFRESH_ONLY=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    --)
      shift
      REFRESH_ARGS+=("$@")
      break
      ;;
    *)
      REFRESH_ARGS+=("$1")
      shift
      ;;
  esac
done

run() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    printf '[dry-run] %s\n' "$*"
  else
    printf '+ %s\n' "$*"
    "$@"
  fi
}

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "Required file not found: $1" >&2
    exit 1
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command docker
require_command jq
require_file "${COMPOSE_FILE}"
require_file "${SETUP_SCRIPT}"

if [[ "${REFRESH}" -eq 1 ]]; then
  require_file "${REFRESH_SCRIPT}"
  require_command kubectl
fi

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "${ENV_FILE}"
  set +a
fi

CORE_ADDRESS="${CORE_ADDRESS:-}"
if [[ -z "${CORE_ADDRESS}" ]]; then
  echo "CORE_ADDRESS must be set (export it or add to ${ENV_FILE})." >&2
  exit 1
fi

POLLERS_AGENT_ADDRESS="${POLLERS_AGENT_ADDRESS:-agent:50051}"
UPSTREAM_ADDRESS="${POLLERS_SPIRE_UPSTREAM_ADDRESS:-${SPIRE_UPSTREAM_ADDRESS:-host.docker.internal}}"
UPSTREAM_PORT="${POLLERS_SPIRE_UPSTREAM_PORT:-${SPIRE_UPSTREAM_PORT:-18081}}"

PROJECT_ENV=("docker" "compose" "--env-file" "${ENV_FILE}" "-f" "${COMPOSE_FILE}")

down_stack() {
  run "${PROJECT_ENV[@]}" down || true
}

remove_volumes() {
  for volume in compose_poller-spire-runtime compose_poller-generated-config poller-generated-config; do
    run docker volume rm "${volume}" 2>/dev/null || true
  done
}

run_config_updater() {
  local previous_templates="${SERVICERADAR_TEMPLATES-}"
  export SERVICERADAR_TEMPLATES="${TEMPLATE_DIR}"
  run "${PROJECT_ENV[@]}" up --exit-code-from config-updater config-updater
  if [[ -n "${previous_templates:-}" ]]; then
    export SERVICERADAR_TEMPLATES="${previous_templates}"
  else
    unset SERVICERADAR_TEMPLATES
  fi
  run "${PROJECT_ENV[@]}" rm -f config-updater cert-generator || true
}

run_refresh() {
  if [[ "${REFRESH}" -eq 1 ]]; then
    run "${REFRESH_SCRIPT}" "${REFRESH_ARGS[@]}"
  fi
}

rewrite_configs() {
  CONFIG_VOLUME="compose_poller-generated-config" \
  CORE_ADDRESS="${CORE_ADDRESS}" \
  POLLERS_AGENT_ADDRESS="${POLLERS_AGENT_ADDRESS}" \
  SPIRE_UPSTREAM_ADDRESS="${UPSTREAM_ADDRESS}" \
  SPIRE_UPSTREAM_PORT="${UPSTREAM_PORT}" \
  run "${SETUP_SCRIPT}"
}

start_stack() {
  run "${PROJECT_ENV[@]}" up -d --no-deps poller agent
}

if [[ "${REFRESH_ONLY}" -eq 1 ]]; then
  run_refresh
  exit 0
fi

down_stack
remove_volumes
run_config_updater
run_refresh
rewrite_configs
start_stack

echo "Edge poller stack restarted successfully."
