#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
METADATA_FILE="${ROOT_DIR}/elixir/serviceradar_core/priv/repo/baseline/metadata.json"
MIGRATIONS_DIR="${ROOT_DIR}/elixir/serviceradar_core/priv/repo/migrations"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

if [[ ! -f "${METADATA_FILE}" ]]; then
  echo "baseline metadata not found: ${METADATA_FILE}" >&2
  exit 1
fi

included_through="$(jq -r '.included_through // empty' "${METADATA_FILE}")"

if [[ ! "${included_through}" =~ ^[0-9]+$ ]]; then
  echo "baseline metadata missing numeric included_through" >&2
  exit 1
fi

allow_marker="serviceradar:allow-startup-maintenance"
blocked_pattern='refresh_continuous_aggregate|WITH[[:space:]]+DATA|pg_sleep|UPDATE[[:space:]]+platform\.|DELETE[[:space:]]+FROM[[:space:]]+platform\.|add_retention_policy|add_continuous_aggregate_policy|DROP[[:space:]]+MATERIALIZED[[:space:]]+VIEW|CREATE[[:space:]]+MATERIALIZED[[:space:]]+VIEW'
failures=0

while IFS= read -r migration; do
  name="$(basename "${migration}")"
  version="${name%%_*}"

  if [[ ! "${version}" =~ ^[0-9]+$ ]] || (( version <= included_through )); then
    continue
  fi

  if grep -Eiq "${blocked_pattern}" "${migration}" && ! grep -q "${allow_marker}" "${migration}"; then
    echo "startup-blocking maintenance pattern in ${migration#${ROOT_DIR}/}" >&2
    failures=$((failures + 1))
  fi
done < <(find "${MIGRATIONS_DIR}" -maxdepth 1 -type f -name '*.exs' | sort)

if (( failures > 0 )); then
  cat >&2 <<EOF

Migrations newer than baseline ${included_through} must not do synchronous
backfills, cleanup updates, continuous aggregate refreshes, retention policy
maintenance, sleeps, or materialized-view rebuilds on the first-boot path.

Move that work to an idempotent post-bootstrap job or operator task. If the
operation is genuinely schema-critical and bounded, add a reviewed comment
containing '${allow_marker}' that explains why it is safe.
EOF
  exit 1
fi

echo "Migration startup-safety check passed for migrations after ${included_through}"
