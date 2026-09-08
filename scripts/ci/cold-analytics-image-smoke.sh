#!/usr/bin/env bash
# Copyright 2026 Carver Automation Corporation.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Boot-smoke for the serviceradar-cnpg-analytics image base (openspec
# add-tiered-telemetry-offload, task 1.4). Gates every @pgduckdb_18 digest
# pin bump in MODULE.bazel:
#   1. initdb with C collation + UTF8 encoding (mirrors the chart-owned
#      analytics head posture: localeCollate/localeCType C, encoding UTF8 —
#      the stock pgduckdb image defaults to en_US.utf8, which breaks
#      DuckDB/PG ordering parity, and a bare `--locale=C` flips the encoding
#      to SQL_ASCII, which pg_duckdb refuses to install into).
#   2. CREATE EXTENSION pg_duckdb.
#   3. duckdb.query() executes inside DuckDB.
#   4. Local Parquet COPY + read_parquet round-trip (no S3 required).
#   5. pg_database.datcollate = 'C' guard (query pg_database, NOT
#      `SHOW lc_collate` — removed in PG18).
#
# Usage:
#   scripts/ci/cold-analytics-image-smoke.sh [image-ref]
# Without an argument the image is derived from the @pgduckdb_18 digest pinned
# in MODULE.bazel, so CI exercises exactly the pinned base.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

DOCKER_BIN="${DOCKER_BIN:-docker}"
WAIT_SECONDS="${WAIT_SECONDS:-120}"

IMAGE="${1:-${COLD_ANALYTICS_IMAGE:-}}"
if [[ -z "${IMAGE}" ]]; then
  digest="$(awk '/name = "pgduckdb_18"/,/^\)/' "${REPO_ROOT}/MODULE.bazel" \
    | sed -n 's/.*digest = "\(sha256:[0-9a-f]*\)".*/\1/p' | head -n1)"
  if [[ -z "${digest}" ]]; then
    echo "error: could not extract the @pgduckdb_18 digest from MODULE.bazel" >&2
    exit 1
  fi
  IMAGE="docker.io/pgduckdb/pgduckdb@${digest}"
fi

# The UID the chart runs this image under (cold-analytics-head.yaml
# postgresUID/postgresGID). The image's postgres user is 999, NOT
# CloudNativePG's default 26 — running the smoke as root or as the image
# default would pass while production dies at initdb with "could not look up
# effective user ID". Keep this in lockstep with the chart.
RUN_UID="${COLD_ANALYTICS_UID:-999}"
RUN_GID="${COLD_ANALYTICS_GID:-999}"

CONTAINER="cold-analytics-smoke-$$"

cleanup() {
  "${DOCKER_BIN}" rm -f "${CONTAINER}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Boot-smoking analytics image: ${IMAGE}"

echo "==> Running as UID ${RUN_UID}:${RUN_GID} (the UID the chart configures)"

"${DOCKER_BIN}" run -d --name "${CONTAINER}" \
  --user "${RUN_UID}:${RUN_GID}" \
  -e POSTGRES_PASSWORD=smoke \
  -e POSTGRES_INITDB_ARGS='--locale=C --encoding=UTF8' \
  "${IMAGE}" >/dev/null

psql_smoke() {
  "${DOCKER_BIN}" exec -u postgres "${CONTAINER}" \
    psql -v ON_ERROR_STOP=1 -U postgres -tA "$@"
}

echo "==> Waiting for the FINAL PostgreSQL server (max ${WAIT_SECONDS}s)"
# The stock entrypoint runs a TEMPORARY postmaster (listening on the unix
# socket only) to execute initdb scripts, then shuts it down and starts the
# real one. Accepting the first successful `SELECT 1` races that bounce: the
# query can hit the temporary server, which then stops before CREATE
# EXTENSION, so the gate fails intermittently and passes on rerun.
#
# The entrypoint prints this exact banner only after the temporary server is
# gone, so wait for it, then require readiness to hold steady.
ready=false
for _ in $(seq 1 "${WAIT_SECONDS}"); do
  if "${DOCKER_BIN}" logs "${CONTAINER}" 2>&1 | grep -q 'database system is ready to accept connections'; then
    if "${DOCKER_BIN}" logs "${CONTAINER}" 2>&1 | grep -q 'PostgreSQL init process complete; ready for start up'; then
      # Require several consecutive successes so we never certify a server
      # that is about to stop.
      stable=0
      for _ in $(seq 1 5); do
        if [[ "$(psql_smoke -c 'SELECT 1' 2>/dev/null || true)" == "1" ]]; then
          stable=$((stable + 1))
        else
          stable=0
        fi
        sleep 1
      done
      if [[ "${stable}" -ge 3 ]]; then
        ready=true
        break
      fi
    fi
  fi
  if [[ "$("${DOCKER_BIN}" inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null || true)" != "true" ]]; then
    echo "error: container exited during startup" >&2
    "${DOCKER_BIN}" logs "${CONTAINER}" | tail -50 >&2
    exit 1
  fi
  sleep 1
done
if [[ "${ready}" != "true" ]]; then
  echo "error: the final PostgreSQL server was not stably ready within ${WAIT_SECONDS}s" >&2
  "${DOCKER_BIN}" logs "${CONTAINER}" | tail -50 >&2
  exit 1
fi

echo "==> Asserting C collation (pg_database.datcollate — SHOW lc_collate is gone in PG18)"
datcollate="$(psql_smoke -c "SELECT datcollate FROM pg_database WHERE datname = current_database()")"
if [[ "${datcollate}" != "C" ]]; then
  echo "error: expected datcollate='C', got '${datcollate}' — ordering parity with DuckDB requires C" >&2
  exit 1
fi

echo "==> CREATE EXTENSION pg_duckdb"
psql_smoke -c "CREATE EXTENSION IF NOT EXISTS pg_duckdb" >/dev/null
extversion="$(psql_smoke -c "SELECT extversion FROM pg_extension WHERE extname = 'pg_duckdb'")"
if [[ -z "${extversion}" ]]; then
  echo "error: pg_duckdb extension not installed after CREATE EXTENSION" >&2
  exit 1
fi
echo "    pg_duckdb version: ${extversion}"

echo "==> duckdb.query() executes"
one="$(psql_smoke -c "SELECT * FROM duckdb.query('SELECT 1 AS smoke_ok')")"
if [[ "${one}" != "1" ]]; then
  echo "error: duckdb.query('SELECT 1') returned '${one}'" >&2
  exit 1
fi

echo "==> Local Parquet COPY + read_parquet round-trip"
psql_smoke -c "COPY (SELECT 42 AS x) TO '/tmp/smoke.parquet' (FORMAT parquet)" >/dev/null
# pg_duckdb >= 0.3 exposes read_parquet columns via the r['colname'] syntax.
roundtrip="$(psql_smoke -c "SELECT count(*)::text || ':' || min(r['x'])::text FROM read_parquet('/tmp/smoke.parquet') r")"
if [[ "${roundtrip}" != "1:42" ]]; then
  echo "error: read_parquet round-trip returned '${roundtrip}', expected '1:42'" >&2
  exit 1
fi

echo "==> PASS: ${IMAGE} boots with C collation, pg_duckdb ${extversion}, and Parquet round-trip works"
