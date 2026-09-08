#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-serviceradar-bootstrap-smoke}"
TARGET_SECONDS="${SERVICERADAR_BOOTSTRAP_TARGET_SECONDS:-300}"
POLL_SECONDS="${SERVICERADAR_BOOTSTRAP_POLL_SECONDS:-5}"
APP_TAG="${APP_TAG:-latest}"
COMPOSE_FILE="${ROOT_DIR}/tmp/docker-compose.bootstrap-smoke.yml"

export APP_TAG
export SERVICERADAR_VOLUME_PREFIX="${SERVICERADAR_VOLUME_PREFIX:-${PROJECT_NAME}}"

compose() {
  docker compose --project-directory "${ROOT_DIR}" -f "${COMPOSE_FILE}" -p "${PROJECT_NAME}" "$@"
}

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required" >&2
  exit 1
fi

cd "${ROOT_DIR}"

cleanup() {
  if [[ "${SERVICERADAR_BOOTSTRAP_KEEP_STACK:-0}" != "1" ]]; then
    compose down -v --remove-orphans >/dev/null 2>&1 || true
    rm -f "${COMPOSE_FILE}"
  fi
}
trap cleanup EXIT

mkdir -p "${ROOT_DIR}/tmp"
sed '/^[[:space:]]*container_name:/d' "${ROOT_DIR}/docker-compose.yml" >"${COMPOSE_FILE}"

echo "Starting isolated Docker Compose bootstrap smoke stack"
echo "project=${PROJECT_NAME} app_tag=${APP_TAG} target_seconds=${TARGET_SECONDS}"

compose down -v --remove-orphans >/dev/null 2>&1 || true

if [[ "${SERVICERADAR_BOOTSTRAP_SKIP_PULL:-0}" != "1" ]]; then
  compose pull
fi

start_epoch="$(date +%s)"
compose up -d --force-recreate

stack_ready() {
  local ids
  ids="$(compose ps -q)"

  if [[ -z "${ids}" ]]; then
    return 1
  fi

  while IFS= read -r id; do
    [[ -z "${id}" ]] && continue

    local state
    state="$(
      docker inspect \
        --format '{{ index .Config.Labels "com.docker.compose.service" }}|{{ .State.Status }}|{{ if .State.Health }}{{ .State.Health.Status }}{{ else }}none{{ end }}|{{ .State.ExitCode }}' \
        "${id}"
    )"

    IFS='|' read -r service status health exit_code <<<"${state}"

    case "${status}" in
      running)
        if [[ "${health}" == "unhealthy" || "${health}" == "starting" ]]; then
          return 1
        fi
        ;;
      exited)
        if [[ "${exit_code}" != "0" ]]; then
          echo "service ${service} exited with ${exit_code}" >&2
          return 2
        fi
        ;;
      *)
        return 1
        ;;
    esac
  done <<<"${ids}"

  return 0
}

while true; do
  now="$(date +%s)"
  elapsed=$((now - start_epoch))

  if stack_ready; then
    echo "Docker Compose bootstrap reached ready state in ${elapsed}s"
    compose ps
    exit 0
  fi

  if (( elapsed >= TARGET_SECONDS )); then
    echo "Docker Compose bootstrap did not reach ready state within ${TARGET_SECONDS}s" >&2
    compose ps >&2 || true
    compose logs --tail=200 >&2 || true
    exit 1
  fi

  sleep "${POLL_SECONDS}"
done
