#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="${TMPDIR:-/tmp}/serviceradar-baseline-compare.$$"

cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

if ! command -v pg_dump >/dev/null 2>&1; then
  echo "pg_dump is required" >&2
  exit 1
fi

if [[ -z "${BASELINE_DATABASE_URL:-}" || -z "${REPLAY_DATABASE_URL:-}" ]]; then
  echo "BASELINE_DATABASE_URL and REPLAY_DATABASE_URL are required" >&2
  exit 1
fi

mkdir -p "${WORK_DIR}"

dump_schema() {
  local url="$1"
  local out="$2"

  pg_dump "${url}" --schema-only --no-owner --no-privileges |
    sed -E \
      -e '/^-- Dumped from database version /d' \
      -e '/^-- Dumped by pg_dump version /d' \
      -e '/^\\\\restrict /d' \
      -e '/^\\\\unrestrict /d' \
      >"${out}"
}

dump_schema "${BASELINE_DATABASE_URL}" "${WORK_DIR}/baseline.sql"
dump_schema "${REPLAY_DATABASE_URL}" "${WORK_DIR}/replay.sql"

if diff -u "${WORK_DIR}/baseline.sql" "${WORK_DIR}/replay.sql"; then
  echo "Baseline schema matches migration replay schema"
else
  echo "Baseline schema differs from migration replay schema" >&2
  exit 1
fi
