#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE_COUNT="${SERVICERADAR_LARGE_INGESTION_DEVICE_COUNT:-50000}"
CHUNK_SIZE="${SERVICERADAR_LARGE_INGESTION_CHUNK_SIZE:-1000}"

echo "Running Armis agent large-ingestion release gate (${DEVICE_COUNT} devices)"
(
  cd "${ROOT_DIR}"
  SERVICERADAR_LARGE_INGESTION_TEST=1 go test ./go/pkg/agent \
    -run TestRunArmisSyncReleaseGateStreamsMultipleQueriesAndRefreshesToken \
    -count=1
)

RUN_ID="${SERVICERADAR_INTEGRATION_RUN_ID:-}"

if [[ -z "${RUN_ID}" ]]; then
  cat >&2 <<'MSG'
SERVICERADAR_INTEGRATION_RUN_ID is required for the core ingestion gate.
Prepare the schema generation and run //rust/integration-db:provision_generation_large_ingestion
under that run id first (docs/agent-runbooks.md), then rerun this script with the same id.
MSG
  exit 1
fi

echo "Running core EdgeRecord large-ingestion release gate (${DEVICE_COUNT} devices, chunk size ${CHUNK_SIZE})"
(
  cd "${ROOT_DIR}"
  bazel test -c opt --//build:enable_integration_tests "--//build:run_id=${RUN_ID}" \
    --strategy=TestRunner=local --nocache_test_results \
    "--test_env=SERVICERADAR_LARGE_INGESTION_DEVICE_COUNT=${DEVICE_COUNT}" \
    "--test_env=SERVICERADAR_LARGE_INGESTION_CHUNK_SIZE=${CHUNK_SIZE}" \
    //elixir/serviceradar_core:large_ingestion_release_gate
)
