#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASELINE_DIR="${ROOT_DIR}/elixir/serviceradar_core/priv/repo/baseline"
METADATA_FILE="${BASELINE_DIR}/metadata.json"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

schema_file="$(jq -r '.schema_file // empty' "${METADATA_FILE}")"
expected_sha="$(jq -r '.schema_sha256 // empty' "${METADATA_FILE}")"
included_through="$(jq -r '.included_through // empty' "${METADATA_FILE}")"

if [[ -z "${schema_file}" || -z "${expected_sha}" || ! "${included_through}" =~ ^[0-9]+$ ]]; then
  echo "baseline metadata is missing schema_file, schema_sha256, or included_through" >&2
  exit 1
fi

schema_path="${BASELINE_DIR}/${schema_file}"

if [[ ! -f "${schema_path}" ]]; then
  echo "baseline schema file not found: ${schema_path}" >&2
  exit 1
fi

actual_sha="$(sha256sum "${schema_path}" | awk '{print $1}')"

if [[ "${actual_sha}" != "${expected_sha}" ]]; then
  echo "baseline checksum mismatch for ${schema_file}" >&2
  echo "expected: ${expected_sha}" >&2
  echo "actual:   ${actual_sha}" >&2
  exit 1
fi

if ! find "${ROOT_DIR}/elixir/serviceradar_core/priv/repo/migrations" \
  -maxdepth 1 -type f -name "${included_through}_*.exs" | grep -q .; then
  echo "included_through migration ${included_through} does not exist" >&2
  exit 1
fi

echo "Baseline metadata check passed for ${schema_file}"
