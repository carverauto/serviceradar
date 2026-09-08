#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROFILE="fast"
KEEP_ARTIFACTS="${ARMIS_E2E_KEEP_ARTIFACTS:-0}"
RUN_DIR=""
FAKER_PID=""
FAKER_ENDPOINT=""
ISOLATED_DB_URL=""
ISOLATED_DB_OWNED="0"

usage() {
  cat <<'EOF'
Usage: scripts/test-armis-dire-e2e.sh [--profile fast|scale] [--keep-artifacts]

Required database environment:
  SERVICERADAR_TEST_DATABASE_URL  Explicit PostgreSQL test DSN.

Optional database environment:
  SERVICERADAR_TEST_ADMIN_URL     Admin DSN. When set, the harness creates a
                                  unique disposable database from the test DSN,
                                  resets it, and drops it on exit.
  SERVICERADAR_TEST_DATABASE_CA_CERT_FILE / PGSSLROOTCERT
                                  TLS settings passed through to psql and Mix.
  SERVICERADAR_TEST_DATABASE_CERT / SERVICERADAR_TEST_DATABASE_KEY
                                  Optional client certificate and key paths for
                                  CNPG deployments that require mTLS.

Profiles:
  fast   2,500 devices, page size 997, deterministic IP churn, repeat run.
  scale  50,000 devices, page size 997, deterministic IP churn, repeat run.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile)
      [ "$#" -ge 2 ] || { echo "--profile requires a value" >&2; exit 2; }
      PROFILE="$2"
      shift 2
      ;;
    --keep-artifacts)
      KEEP_ARTIFACTS="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "${PROFILE}" in
  fast)
    DEVICE_COUNT="${ARMIS_E2E_FAST_DEVICES:-2500}"
    ;;
  scale)
    DEVICE_COUNT="${ARMIS_E2E_SCALE_DEVICES:-50000}"
    ;;
  *)
    echo "profile must be fast or scale" >&2
    exit 2
    ;;
esac

case "${DEVICE_COUNT}" in
  ''|*[!0-9]*)
    echo "device count must be a positive integer" >&2
    exit 2
    ;;
esac

[ "${DEVICE_COUNT}" -gt 0 ] || { echo "device count must be positive" >&2; exit 2; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "required command not found: $1" >&2
    exit 1
  }
}

require_command curl
require_command go
require_command mix
require_command python3

if [ -z "${SERVICERADAR_TEST_DATABASE_URL:-}" ]; then
  echo "SERVICERADAR_TEST_DATABASE_URL is required; this harness never discovers a Kubernetes database" >&2
  exit 1
fi

cleanup() {
  cleanup_status="$?"

  if [ "${cleanup_status}" -ne 0 ] || [ "${KEEP_ARTIFACTS}" = "1" ]; then
    if [ -n "${FAKER_ENDPOINT}" ]; then
      curl -fsS "${FAKER_ENDPOINT}/debug/armis/northbound/updates" \
        >"${RUN_DIR}/northbound-capture.json" 2>/dev/null || true
    fi

    if [ "${ISOLATED_DB_OWNED}" = "1" ] && [ -n "${ISOLATED_DB_URL}" ] &&
      command -v psql >/dev/null 2>&1; then
      psql_env=()
      if [ -n "${SERVICERADAR_TEST_DATABASE_CERT:-}" ]; then
        psql_env+=("PGSSLCERT=${SERVICERADAR_TEST_DATABASE_CERT}")
      fi
      if [ -n "${SERVICERADAR_TEST_DATABASE_KEY:-}" ]; then
        psql_env+=("PGSSLKEY=${SERVICERADAR_TEST_DATABASE_KEY}")
      fi

      env "${psql_env[@]}" psql "${ISOLATED_DB_URL}" -X -v ON_ERROR_STOP=1 -P pager=off \
        -c "SELECT id, integration_source_id, run_type, status, device_count, updated_count, skipped_count, error_count, metadata FROM platform.integration_update_runs ORDER BY inserted_at;" \
        >"${RUN_DIR}/integration-update-runs.txt" 2>&1 || true
    fi
  fi

  if [ -n "${FAKER_PID}" ] && kill -0 "${FAKER_PID}" 2>/dev/null; then
    kill "${FAKER_PID}" 2>/dev/null || true
    wait "${FAKER_PID}" 2>/dev/null || true
  fi

  if [ "${ISOLATED_DB_OWNED}" = "1" ] && [ -n "${ISOLATED_DB_URL}" ]; then
    if ! "${SCRIPT_DIR}/drop-test-db.sh" "${SERVICERADAR_TEST_ADMIN_URL}" "${ISOLATED_DB_URL}"; then
      echo "warning: failed to drop isolated database ${ISOLATED_DB_URL}" >&2
      cleanup_status=1
    fi
  fi

  if [ "${cleanup_status}" -ne 0 ] || [ "${KEEP_ARTIFACTS}" = "1" ]; then
    if [ -n "${RUN_DIR}" ]; then
      echo "Armis/DIRE E2E artifacts preserved at ${RUN_DIR}" >&2
    fi
  elif [ -n "${RUN_DIR}" ]; then
    rm -rf "${RUN_DIR}"
  fi

  exit "${cleanup_status}"
}
trap cleanup EXIT

RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/serviceradar-armis-dire-e2e.XXXXXX")"
mkdir -p "${RUN_DIR}/faker-data"

if [ -n "${SERVICERADAR_TEST_ADMIN_URL:-}" ]; then
  ISOLATED_DB_URL="$(python3 - "${SERVICERADAR_TEST_DATABASE_URL}" <<'PY'
import sys
from urllib.parse import quote, urlparse, urlunparse

base = urlparse(sys.argv[1])
if base.scheme not in {"postgres", "postgresql"} or not base.hostname:
    raise SystemExit("SERVICERADAR_TEST_DATABASE_URL must be a PostgreSQL URL")

database = "armis_e2e_" + str(__import__("os").getpid())
print(urlunparse((
    base.scheme,
    base.netloc,
    "/" + quote(database, safe=""),
    base.params,
    base.query,
    base.fragment,
)))
PY
)"
  ISOLATED_DB_OWNED="1"
  "${SCRIPT_DIR}/reset-test-db.sh" "${SERVICERADAR_TEST_ADMIN_URL}" "${ISOLATED_DB_URL}"
  export SERVICERADAR_TEST_DATABASE_URL="${ISOLATED_DB_URL}"
fi

faker_port="$(python3 - <<'PY'
import socket

with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
FAKER_ENDPOINT="http://127.0.0.1:${faker_port}"
faker_config="${RUN_DIR}/faker.json"

python3 - "${faker_config}" "${faker_port}" "${DEVICE_COUNT}" "${RUN_DIR}/faker-data" <<'PY'
import json
import sys

path, port, device_count, data_dir = sys.argv[1:]
config = {
    "service": {"name": "faker", "description": "Armis DIRE E2E faker", "version": "e2e"},
    "server": {
        "listen_address": "127.0.0.1:" + port,
        "read_timeout": "10s",
        "write_timeout": "120s",
        "idle_timeout": "120s",
    },
    "simulation": {
        "total_devices": int(device_count),
        "ip_shuffle": {
            "enabled": False,
            "interval": "1h",
            "percentage": 5,
            "warmup_cycles": 0,
            "seed": 4707,
            "log_changes": False,
            "allow_expansion": False,
            "pool_headroom_percent": 0,
        },
        "bgp": {"enabled": False},
    },
    "storage": {
        "data_dir": data_dir,
        "devices_file": "devices.json",
        "persist_changes": False,
    },
    "logging": {"level": "info", "file": "", "max_size": "10M", "max_backups": 1, "max_age": 1},
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(config, handle)
PY

echo "Building standalone faker and Armis fixture producer"
go build -o "${RUN_DIR}/faker" ./go/cmd/faker
go build -o "${RUN_DIR}/armis-e2e-fixture" ./go/cmd/armis-e2e-fixture

"${RUN_DIR}/faker" -config "${faker_config}" >"${RUN_DIR}/faker.log" 2>&1 &
FAKER_PID="$!"

ready="0"
for _ in $(seq 1 240); do
  if ! kill -0 "${FAKER_PID}" 2>/dev/null; then
    echo "faker exited before readiness" >&2
    tail -200 "${RUN_DIR}/faker.log" >&2 || true
    exit 1
  fi

if ready_count="$(curl -fsS "${FAKER_ENDPOINT}/debug/armis/ready" 2>/dev/null)" &&
    [ "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["device_count"])' <<<"${ready_count}")" = "${DEVICE_COUNT}" ]; then
    ready="1"
    break
  fi
  sleep 0.25
done

[ "${ready}" = "1" ] || {
  echo "timed out waiting for faker readiness" >&2
  tail -200 "${RUN_DIR}/faker.log" >&2 || true
  exit 1
}

echo "Producing ${DEVICE_COUNT} Armis pages through the real Go driver"
"${RUN_DIR}/armis-e2e-fixture" \
  -endpoint "${FAKER_ENDPOINT}" \
  -output "${RUN_DIR}/armis-fixture.jsonl" \
  -page-size 997 \
  -churn-swaps "${ARMIS_E2E_CHURN_SWAPS:-250}" \
  -repeat-after-churn \
  >"${RUN_DIR}/producer-summary.json"

export ARMIS_E2E_FAKER_URL="${FAKER_ENDPOINT}"
export ARMIS_E2E_FIXTURE_FILE="${RUN_DIR}/armis-fixture.jsonl"
export ARMIS_E2E_ARTIFACT_DIR="${RUN_DIR}"
export SERVICERADAR_CORE_RUN_MIGRATIONS="false"
export SERVICERADAR_TEST_DATABASE_OWNERSHIP_TIMEOUT_MS="${SERVICERADAR_TEST_DATABASE_OWNERSHIP_TIMEOUT_MS:-1800000}"

echo "Migrating and running the closed-loop Core suite"
test_status=0
(
  cd "${REPO_ROOT}/elixir/serviceradar_core"
  MIX_ENV=test mix deps.get
  MIX_ENV=test mix ash.migrate
  MIX_ENV=test mix test --include integration --include armis_dire_e2e --no-start --max-cases 1 \
    test/serviceradar/integrations/armis_dire_e2e_test.exs
) >"${RUN_DIR}/core-test.log" 2>&1 || test_status=$?

cat "${RUN_DIR}/core-test.log"

if [ "${test_status}" -ne 0 ]; then
  exit "${test_status}"
fi

echo "Armis/DIRE E2E profile ${PROFILE} passed for ${DEVICE_COUNT} devices"
