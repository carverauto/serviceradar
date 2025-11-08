#!/usr/bin/env bash
# Wrapper that optionally runs config-sync before launching the service.
set -euo pipefail

CONFIG_SYNC_ENABLED="${CONFIG_SYNC_ENABLED:-true}"
CONFIG_SYNC_BIN="${CONFIG_SYNC_BIN:-/usr/local/bin/config-sync}"
CONFIG_SERVICE_NAME="${CONFIG_SERVICE:-}"
CONFIG_KV_KEY="${CONFIG_KV_KEY:-}"
CONFIG_OUTPUT_PATH="${CONFIG_OUTPUT:-}"
CONFIG_TEMPLATE_PATH="${CONFIG_TEMPLATE:-}"
CONFIG_SYNC_ROLE="${CONFIG_SYNC_ROLE:-}"
CONFIG_SYNC_SEED="${CONFIG_SYNC_SEED:-true}"
CONFIG_SYNC_WATCH="${CONFIG_SYNC_WATCH:-false}"
CONFIG_SYNC_EXTRA_ARGS="${CONFIG_SYNC_EXTRA_ARGS:-}"

run_config_sync() {
  if [[ "${CONFIG_SYNC_ENABLED}" != "true" ]]; then
    return 0
  fi
  if [[ ! -x "${CONFIG_SYNC_BIN}" ]]; then
    echo "config-sync binary not found at ${CONFIG_SYNC_BIN}, skipping" >&2
    return 0
  }

  declare -a args=()
  if [[ -n "${CONFIG_SERVICE_NAME}" ]]; then
    args+=("--service" "${CONFIG_SERVICE_NAME}")
  fi
  if [[ -n "${CONFIG_KV_KEY}" ]]; then
    args+=("--kv-key" "${CONFIG_KV_KEY}")
  fi
  if [[ -n "${CONFIG_OUTPUT_PATH}" ]]; then
    args+=("--output" "${CONFIG_OUTPUT_PATH}")
  fi
  if [[ -n "${CONFIG_TEMPLATE_PATH}" ]]; then
    args+=("--template" "${CONFIG_TEMPLATE_PATH}")
  fi
  if [[ -n "${CONFIG_SYNC_ROLE}" ]]; then
    args+=("--role" "${CONFIG_SYNC_ROLE}")
  fi
  if [[ "${CONFIG_SYNC_SEED}" != "true" ]]; then
    args+=("--seed=false")
  fi
  if [[ "${CONFIG_SYNC_WATCH}" == "true" ]]; then
    args+=("--watch")
  fi
  if [[ -n "${CONFIG_SYNC_EXTRA_ARGS}" ]]; then
    # shellcheck disable=SC2206
    extra_args=( ${CONFIG_SYNC_EXTRA_ARGS} )
    args+=("${extra_args[@]}")
  fi

  echo "Running config-sync ${args[*]}"
  "${CONFIG_SYNC_BIN}" "${args[@]}"
}

run_config_sync

exec "$@"
