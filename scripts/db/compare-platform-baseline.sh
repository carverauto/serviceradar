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

  # Strip lines that vary between two dumps of the same logical schema:
  #   * "-- Dumped from/by ... version" banners (harmless, but noise).
  #   * psql \restrict / \unrestrict guards. pg_dump (PG 16.6+/17+/18) emits
  #     these with a RANDOM per-dump token, e.g.
  #       \restrict p5xTOvA5q7mbAM7Gf1wUJGeBF4dOW4o6BsAPpW8nf1Z6lHKMmi2XYC296j4biOU
  #     so a byte diff of two dumps ALWAYS differs on that token unless the
  #     line is removed. The pg_dump line has a SINGLE leading backslash, so
  #     the sed address needs exactly one literal backslash: in an ERE address
  #     `\\` matches one `\`. (The previous `\\\\` matched *two* backslashes,
  #     never stripped these lines, and produced a permanent false-positive
  #     diff — masking real drift once the comparison was ever enabled.)
  pg_dump -w "${url}" --schema-only --no-owner --no-privileges |
    sed -E \
      -e '/^-- Dumped from database version /d' \
      -e '/^-- Dumped by pg_dump version /d' \
      -e '/^\\restrict/d' \
      -e '/^\\unrestrict/d' \
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
