#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SRQL_FIXTURE_PF_PID=""

# shellcheck source=scripts/db/test-database-url-guard.sh
source "${SCRIPT_DIR}/db/test-database-url-guard.sh"

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

skip_unreachable_integration_db() {
  if [ "${SERVICERADAR_SKIP_UNREACHABLE_INTEGRATION_DB:-0}" = "1" ]; then
    echo "serviceradar_core integration database is unreachable; skipping optional integration tests" >&2
    exit 0
  fi
}

database_endpoint_reachable() {
  python3 - "${1:-}" <<'PY'
import socket
import sys
from urllib.parse import urlparse

url = sys.argv[1]
parsed = urlparse(url)
host = parsed.hostname
port = parsed.port or 5432

if not host:
    raise SystemExit(1)

try:
    with socket.create_connection((host, port), timeout=5):
        raise SystemExit(0)
except OSError:
    raise SystemExit(1)
PY
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

serviceradar_assert_test_database_url "${db_url}"

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

  # Database provisioning is //rust/integration-db now, not scripts/reset-test-db.sh, and it
  # happens below as part of the Bazel sequence. All this block still has to do is decide
  # whether the fixture is reachable at all -- the reset itself moved.
  if [ "${SERVICERADAR_SKIP_UNREACHABLE_INTEGRATION_DB:-0}" = "1" ] &&
    ! database_endpoint_reachable "${admin_url}"; then
    skip_unreachable_integration_db
  fi
fi

export SERVICERADAR_TEST_DATABASE_URL="${db_url}"
export SERVICERADAR_TEST_DATABASE_OWNERSHIP_TIMEOUT_MS="${SERVICERADAR_TEST_DATABASE_OWNERSHIP_TIMEOUT_MS:-600000}"
export SERVICERADAR_CORE_RUN_MIGRATIONS=false

if [ ! -f "${REPO_ROOT}/elixir/serviceradar_core/test/serviceradar/prefix_tags/integration_test.exs" ]; then
  echo "prefix-tags integration suite missing; expected test/serviceradar/prefix_tags/integration_test.exs" >&2
  exit 1
fi

# Tests run through Bazel so the compiled dependency tree and unchanged targets come from
# the remote cache. //elixir/serviceradar_core:integration_tests sets
# SERVICERADAR_ONLY_INTEGRATION=1, so test_helper.exs selects only the tests that need a
# running application -- include: [:integration, :requires_app], max_cases: 1 -- rather than
# `--include integration`, which ADDED to the default set and re-ran the whole unit tier
# that //elixir/serviceradar_core:unit_tests already covers.
#
# SERVICERADAR_ONLY_INTEGRATION and the fixture URLs reach the test through the --test_env
# list in .bazelrc; SERVICERADAR_TEST_DATABASE_URL is exported above.
cd "${REPO_ROOT}"

bazel_config=()
if [ -f .bazelrc.remote ]; then
  bazel_config=(--config=ci)
else
  echo "no .bazelrc.remote; running without the remote cache" >&2
fi

bazel_test_env=(
  --test_output=errors
  --test_env=SERVICERADAR_TEST_DATABASE_URL
  --test_env=SERVICERADAR_TEST_ADMIN_URL
  --test_env=SERVICERADAR_CORE_RUN_MIGRATIONS
  --test_env=SERVICERADAR_TEST_DATABASE_OWNERSHIP_TIMEOUT_MS
)

# Sequential invocations, because Bazel deliberately does not order tests. prepare_template
# applies the schema (what `mix ash.migrate` used to do), :integration_tests runs against
# it, :teardown_db drops the per-run database. All three are tagged `external`, so none of
# them can be served from the test cache.
# The same sequence .forgejo/workflows/elixir-integration-sr-core.yml runs, in the same order.
# Keep the two in step -- this script exists so `make test-integration` reproduces CI locally,
# and it is worse than useless if it exercises a different graph.
#
#   sweep -> prepare_template -> [migrate_template] -> provision -> suite -> teardown
#
# migrate_template is conditional in CI on prepare_template's needs_migration output. Here it
# runs unconditionally: Ecto.Migrator applies only what is pending, so on a current template
# it is a no-op that costs a BEAM start, and skipping it locally is not worth reproducing the
# GITHUB_OUTPUT plumbing.
echo "Sweeping stale integration databases (Bazel)"
bazel test "${bazel_config[@]}" "${bazel_test_env[@]}" \
  //rust/integration-db:sweep_stale_dbs

echo "Preparing the template database (Bazel)"
bazel run "${bazel_config[@]}" //rust/integration-db:prepare_template

echo "Applying migrations to the template (Bazel)"
bazel test "${bazel_config[@]}" "${bazel_test_env[@]}" \
  //elixir/serviceradar_core:migrate_template

echo "Cloning per-shard integration databases (Bazel)"
bazel test "${bazel_config[@]}" "${bazel_test_env[@]}" \
  //rust/integration-db:provision_db

echo "Running serviceradar_core integration suite (Bazel, sharded)"
integration_status=0
bazel test "${bazel_config[@]}" "${bazel_test_env[@]}" \
  //elixir/serviceradar_core:integration_tests || integration_status=$?

# Teardown runs even when the suite fails, so a red run does not leak its databases. It drops
# every `<run>_<shard>` this run created. The workflow keeps its own cleanup step as a
# backstop for a cancelled or dead runner, which never reaches this line at all.
echo "Dropping the per-run integration databases (Bazel)"
bazel test "${bazel_config[@]}" "${bazel_test_env[@]}" \
  //rust/integration-db:teardown_db || echo "teardown failed; workflow backstop will retry" >&2

exit "${integration_status}"
