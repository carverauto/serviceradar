#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/db/test-database-url-guard.sh
source "${SCRIPT_DIR}/db/test-database-url-guard.sh"

expect_pass() {
  local database_name="$1"

  serviceradar_assert_test_database_url \
    "postgres://user:secret@database.example/${database_name}" >/dev/null
}

expect_fail() {
  local url="$1"

  if serviceradar_assert_test_database_url "${url}" >/dev/null 2>&1; then
    echo "expected database URL validation to fail: ${url}" >&2
    exit 1
  fi
}

expect_entrypoint_guard() {
  local output

  if output="$("$@" 2>&1)"; then
    echo "expected destructive entry point to reject a non-test database: $*" >&2
    exit 1
  fi

  if [[ "${output}" != *"refusing destructive operation against non-test database 'serviceradar'"* ]]; then
    echo "entry point failed before applying the shared database guard: $*" >&2
    echo "${output}" >&2
    exit 1
  fi
}

expect_pass "serviceradar_web_ng_test"
expect_pass "test"
expect_pass "test_core"
expect_pass "core_test"
expect_pass "core_test_db"

expect_fail "postgres://user:secret@database.example/serviceradar"
expect_fail "postgres://user:secret@database.example/contest"
expect_fail "postgres://user:secret@database.example/"
expect_fail "postgres:///test"

SERVICERADAR_ALLOW_NON_TEST_INTEGRATION_DATABASE=1 \
  serviceradar_assert_test_database_url \
  "postgres://user:secret@database.example/disposable" >/dev/null

if SERVICERADAR_ALLOW_NON_TEST_INTEGRATION_DATABASE=1 \
  serviceradar_assert_test_database_url \
  "postgres://database.example/" >/dev/null 2>&1; then
  echo "explicit override must not allow an empty database name" >&2
  exit 1
fi

unsafe_url="postgres://user:secret@database.example/serviceradar"

expect_entrypoint_guard \
  env ENV_FILE=/dev/null SERVICERADAR_TEST_DATABASE_URL="${unsafe_url}" \
  "${SCRIPT_DIR}/test-integration.sh"

expect_entrypoint_guard \
  "${SCRIPT_DIR}/reset-test-db.sh" \
  "postgres://admin:secret@database.example/postgres" \
  "${unsafe_url}"

expect_entrypoint_guard \
  env SERVICERADAR_TEST_DATABASE_URL="${unsafe_url}" \
  "${SCRIPT_DIR}/reset-srql-fixture-test-db.sh"
