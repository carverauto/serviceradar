#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SRQL_FIXTURE_PF_PID=""

refresh_srql_fixture_env() {
  local fixture_env

  if ! fixture_env="$("${REPO_ROOT}/scripts/srql-fixture-env.sh" --print-env)"; then
    echo "failed to load srql fixture env via scripts/srql-fixture-env.sh" >&2
    return 1
  fi

  eval "${fixture_env}"
}

port_is_listening() {
  python3 - "${1:-127.0.0.1}" "${2:-5455}" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
family = socket.AF_INET6 if ":" in host else socket.AF_INET

with socket.socket(family, socket.SOCK_STREAM) as sock:
    sock.settimeout(0.2)
    raise SystemExit(0 if sock.connect_ex((host, port)) == 0 else 1)
PY
}

cleanup_srql_fixture_port_forward() {
  if [ -n "${SRQL_FIXTURE_PF_PID}" ] && kill -0 "${SRQL_FIXTURE_PF_PID}" 2>/dev/null; then
    kill "${SRQL_FIXTURE_PF_PID}" 2>/dev/null || true
  fi
}

start_srql_fixture_port_forward() {
  local namespace target local_host local_port log_file

  namespace="${SRQL_FIXTURE_NAMESPACE:-srql-fixtures}"
  local_host="${SRQL_FIXTURE_LOCAL_HOST:-127.0.0.1}"
  local_port="${SRQL_FIXTURE_LOCAL_PORT:-5455}"
  log_file="${XDG_CACHE_HOME:-$HOME/.cache}/serviceradar/test-integration-port-forward.log"

  mkdir -p "$(dirname "${log_file}")"

  target="$(kubectl get pod -n "${namespace}" -l cnpg.io/instanceRole=primary \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "${target}" ]; then
    target="pod/${target}"
  else
    target="${SRQL_FIXTURE_SERVICE:-svc/srql-fixture-rw}"
  fi

  bash -lc '
    set +e
    while true; do
      if python3 - "$1" "$2" <<'"'"'PY'"'"'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
family = socket.AF_INET6 if ":" in host else socket.AF_INET

with socket.socket(family, socket.SOCK_STREAM) as sock:
    sock.settimeout(0.2)
    raise SystemExit(0 if sock.connect_ex((host, port)) == 0 else 1)
PY
      then
        sleep 1
        continue
      fi

      kubectl port-forward -n "$3" "$4" "$2:5432" >>"$5" 2>&1 || true
      sleep 1
    done
  ' _ "${local_host}" "${local_port}" "${namespace}" "${target}" "${log_file}" &
  SRQL_FIXTURE_PF_PID=$!

  for _ in {1..40}; do
    if port_is_listening "${local_host}" "${local_port}"; then
      trap cleanup_srql_fixture_port_forward EXIT
      return 0
    fi

    if ! kill -0 "${SRQL_FIXTURE_PF_PID}" 2>/dev/null; then
      echo "failed to start srql fixture port-forward; see ${log_file}" >&2
      exit 1
    fi

    sleep 0.25
  done

  echo "timed out waiting for srql fixture port-forward on ${local_host}:${local_port}; see ${log_file}" >&2
  exit 1
}

echo "Running serviceradar_core integration tests"

ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"
case "${ENV_FILE}" in
  /*|./*|../*) ;;
  *) ENV_FILE="${REPO_ROOT}/${ENV_FILE}" ;;
esac

if [ -f "${ENV_FILE}" ]; then
  set -a
  # shellcheck disable=SC1090
  . "${ENV_FILE}"
  set +a
fi

db_url="${SERVICERADAR_TEST_DATABASE_URL:-${SRQL_TEST_DATABASE_URL:-}}"
admin_url="${SERVICERADAR_TEST_ADMIN_URL:-${SRQL_TEST_ADMIN_URL:-}}"

if [ -z "${db_url}" ]; then
  if command -v kubectl >/dev/null 2>&1; then
    start_srql_fixture_port_forward
    SRQL_FIXTURE_SKIP_PORT_FORWARD=1 refresh_srql_fixture_env
    db_url="${SERVICERADAR_TEST_DATABASE_URL:-${SRQL_TEST_DATABASE_URL:-}}"
    admin_url="${SERVICERADAR_TEST_ADMIN_URL:-${SRQL_TEST_ADMIN_URL:-}}"
  fi
fi

if [ -z "${db_url}" ]; then
  if [ -n "${CNPG_HOST:-}" ] || [ -n "${CNPG_PASSWORD:-}" ]; then
    db_host="${CNPG_HOST:-localhost}"
    db_port="${CNPG_PORT:-5455}"
    db_name="${SERVICERADAR_TEST_DATABASE:-${CNPG_DATABASE:-serviceradar}}"
    db_user="${CNPG_APP_USER:-${CNPG_USERNAME:-serviceradar}}"
    db_pass="${CNPG_APP_PASSWORD:-${CNPG_PASSWORD:-}}"
    db_sslmode="${CNPG_SSL_MODE:-verify-full}"

    if [ -z "${db_pass}" ]; then
      echo "CNPG_APP_PASSWORD or CNPG_PASSWORD is required to build the test DSN." >&2
      exit 1
    fi

    db_url="postgres://${db_user}:${db_pass}@${db_host}:${db_port}/${db_name}?sslmode=${db_sslmode}"
    export CNPG_TLS_SERVER_NAME="${CNPG_TLS_SERVER_NAME:-${db_host}}"
  fi
fi

if [ -z "${db_url}" ]; then
  echo "Set SERVICERADAR_TEST_DATABASE_URL, SRQL_TEST_DATABASE_URL, or CNPG_* env vars." >&2
  echo "Or ensure kubectl can access the srql-fixtures namespace." >&2
  exit 1
fi

if [ -n "${admin_url}" ]; then
  ca_file="${PGSSLROOTCERT:-${SERVICERADAR_TEST_DATABASE_CA_CERT_FILE:-${SRQL_TEST_DATABASE_CA_CERT_FILE:-${CNPG_CA_FILE:-}}}}"

  if [ -z "${ca_file}" ]; then
    for candidate in "${SERVICERADAR_TEST_DATABASE_CA_CERT:-}" "${SRQL_TEST_DATABASE_CA_CERT:-}"; do
      if [ -n "${candidate}" ] && [ -f "${candidate}" ]; then
        ca_file="${candidate}"
        break
      fi
    done
  fi

  export PGSSLROOTCERT="${ca_file}"
  export PGSSLCERT="${PGSSLCERT:-${SERVICERADAR_TEST_DATABASE_CERT:-${SRQL_TEST_DATABASE_CERT:-}}}"
  export PGSSLKEY="${PGSSLKEY:-${SERVICERADAR_TEST_DATABASE_KEY:-${SRQL_TEST_DATABASE_KEY:-}}}"

  reset_cmd=("${REPO_ROOT}/scripts/reset-test-db.sh" "${admin_url}" "${db_url}")

  if [ "${SERVICERADAR_USE_SRQL_FIXTURE_RESET:-0}" = "1" ]; then
    reset_cmd=("${REPO_ROOT}/scripts/reset-srql-fixture-test-db.sh")
  fi

  if ! "${reset_cmd[@]}"; then
    if command -v kubectl >/dev/null 2>&1; then
      echo "reset-test-db failed, refreshing srql-fixture port-forward and retrying once" >&2
      refresh_srql_fixture_env
      if [ "${SERVICERADAR_USE_SRQL_FIXTURE_RESET:-0}" = "1" ]; then
        cleanup_srql_fixture_port_forward
        start_srql_fixture_port_forward
      fi
      db_url="${SERVICERADAR_TEST_DATABASE_URL:-${SRQL_TEST_DATABASE_URL:-}}"
      admin_url="${SERVICERADAR_TEST_ADMIN_URL:-${SRQL_TEST_ADMIN_URL:-}}"
      export PGSSLROOTCERT="${PGSSLROOTCERT:-${SERVICERADAR_TEST_DATABASE_CA_CERT_FILE:-${SRQL_TEST_DATABASE_CA_CERT_FILE:-${CNPG_CA_FILE:-}}}}"
      if [ "${SERVICERADAR_USE_SRQL_FIXTURE_RESET:-0}" = "1" ]; then
        "${REPO_ROOT}/scripts/reset-srql-fixture-test-db.sh"
      else
        "${REPO_ROOT}/scripts/reset-test-db.sh" "${admin_url}" "${db_url}"
      fi
    else
      exit 1
    fi
  fi
fi

export SERVICERADAR_TEST_DATABASE_URL="${db_url}"
export SERVICERADAR_TEST_DATABASE_OWNERSHIP_TIMEOUT_MS="${SERVICERADAR_TEST_DATABASE_OWNERSHIP_TIMEOUT_MS:-600000}"
export SERVICERADAR_CORE_RUN_MIGRATIONS=false

cd "${REPO_ROOT}/elixir/serviceradar_core"
MIX_ENV=test mix deps.get
MIX_ENV=test mix ash.migrate
MIX_ENV=test mix test --include integration --no-start
