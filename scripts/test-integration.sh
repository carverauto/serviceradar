#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

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
  if [ -n "${CNPG_HOST:-}" ] || [ -n "${CNPG_PASSWORD:-}" ]; then
    db_host="${CNPG_HOST:-localhost}"
    db_port="${CNPG_PORT:-5455}"
    db_name="${SERVICERADAR_TEST_DATABASE:-${CNPG_DATABASE:-serviceradar}}"
    db_user="${CNPG_USERNAME:-serviceradar}"
    db_pass="${CNPG_PASSWORD:-}"
    db_sslmode="${CNPG_SSL_MODE:-verify-full}"

    if [ -z "${db_pass}" ]; then
      echo "CNPG_PASSWORD is required to build the test DSN." >&2
      exit 1
    fi

    db_url="postgres://${db_user}:${db_pass}@${db_host}:${db_port}/${db_name}?sslmode=${db_sslmode}"
    export CNPG_TLS_SERVER_NAME="${CNPG_TLS_SERVER_NAME:-${db_host}}"
  fi
fi

if [ -z "${db_url}" ]; then
  echo "Set SERVICERADAR_TEST_DATABASE_URL, SRQL_TEST_DATABASE_URL, or CNPG_* env vars." >&2
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

  "${REPO_ROOT}/scripts/reset-test-db.sh" "${admin_url}" "${db_url}"
fi

export SERVICERADAR_TEST_DATABASE_URL="${db_url}"
export SERVICERADAR_TEST_DATABASE_OWNERSHIP_TIMEOUT_MS="${SERVICERADAR_TEST_DATABASE_OWNERSHIP_TIMEOUT_MS:-600000}"
export SERVICERADAR_CORE_RUN_MIGRATIONS=false

cd "${REPO_ROOT}/elixir/serviceradar_core"
MIX_ENV=test mix deps.get
MIX_ENV=test mix ash.migrate
MIX_ENV=test mix test --include integration --no-start
