#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: $0 <admin_url> [max_age_seconds]" >&2
  exit 1
fi

admin_url="$1"
max_age_seconds="${2:-86400}"
now_epoch="${SERVICERADAR_TEST_DATABASE_SWEEP_NOW_EPOCH:-$(date +%s)}"

if [[ ! "${max_age_seconds}" =~ ^[0-9]{1,9}$ ]] || [ "${max_age_seconds}" -eq 0 ]; then
  echo "max_age_seconds must be a positive integer of at most 9 digits" >&2
  exit 1
fi

if [[ ! "${now_epoch}" =~ ^[0-9]{10,11}$ ]]; then
  echo "SERVICERADAR_TEST_DATABASE_SWEEP_NOW_EPOCH must be a 10- or 11-digit epoch" >&2
  exit 1
fi

if ! command -v psql >/dev/null 2>&1; then
  echo "psql is required to sweep stale integration databases." >&2
  exit 1
fi

parser="$(command -v python3 || command -v python || true)"
if [ -z "${parser}" ]; then
  echo "python is required to sweep stale integration databases." >&2
  exit 1
fi

cutoff_epoch=$((now_epoch - max_age_seconds))
if [ "${cutoff_epoch}" -lt 0 ]; then
  exit 0
fi

database_names="$(
  psql "${admin_url}" -v ON_ERROR_STOP=1 -Atc \
    "SELECT datname FROM pg_database WHERE datname ~ '^sr_core_test_[0-9]{10,11}_[0-9]+_[0-9]+$' ORDER BY datname"
)"

while IFS= read -r database_name; do
  if [ -z "${database_name}" ]; then
    continue
  fi

  if [[ ! "${database_name}" =~ ^sr_core_test_([0-9]{10,11})_([0-9]+)_([0-9]+)$ ]]; then
    echo "refusing to sweep unexpected database name '${database_name}'" >&2
    exit 1
  fi

  created_epoch="${BASH_REMATCH[1]}"
  if [ "${created_epoch}" -gt "${cutoff_epoch}" ]; then
    continue
  fi

  database_url="$("${parser}" - "${admin_url}" "${database_name}" <<'PY'
import sys
from urllib.parse import quote, urlparse, urlunparse

parsed = urlparse(sys.argv[1])
database_name = sys.argv[2]

if parsed.scheme not in {"postgres", "postgresql"} or not parsed.hostname:
    raise SystemExit("admin URL is not a valid PostgreSQL URL")

print(
    urlunparse(
        (
            parsed.scheme,
            parsed.netloc,
            "/" + quote(database_name, safe=""),
            parsed.params,
            parsed.query,
            parsed.fragment,
        )
    )
)
PY
)"

  echo "dropping stale Core integration database ${database_name}"
  "${SCRIPT_DIR}/drop-test-db.sh" "${admin_url}" "${database_url}"
done <<<"${database_names}"
