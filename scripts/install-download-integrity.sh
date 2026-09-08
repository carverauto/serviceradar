#!/usr/bin/env bash

set -euo pipefail

sr_sha256_file() {
  local file="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
    return
  fi

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
    return
  fi

  echo "error: sha256sum or shasum is required for download verification" >&2
  return 1
}

sr_require_sha256() {
  local expected="$1"
  local label="$2"

  if [[ -z "$expected" ]]; then
    echo "error: no SHA256 configured for ${label}; set the matching *_SHA256 override when changing versions" >&2
    return 1
  fi
}

sr_verify_sha256() {
  local file="$1"
  local expected="$2"
  local label="$3"
  local actual

  sr_require_sha256 "$expected" "$label"

  actual="$(sr_sha256_file "$file")"
  if [[ "$actual" != "$expected" ]]; then
    echo "error: SHA256 mismatch for ${label}" >&2
    echo "expected: ${expected}" >&2
    echo "actual:   ${actual}" >&2
    return 1
  fi
}

sr_download_verified() {
  local url="$1"
  local output="$2"
  local expected="$3"
  local label="$4"

  sr_require_sha256 "$expected" "$label"
  curl -fsSL "$url" -o "$output"
  sr_verify_sha256 "$output" "$expected" "$label"
}
