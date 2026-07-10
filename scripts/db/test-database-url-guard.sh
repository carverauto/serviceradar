#!/usr/bin/env bash

serviceradar_database_name_from_url() {
  local url="$1"
  local parser

  parser="$(command -v python3 || command -v python || true)"

  if [ -z "${parser}" ]; then
    echo "python is required to validate the test database URL" >&2
    return 1
  fi

  "${parser}" - "${url}" <<'PY'
import sys
from urllib.parse import unquote, urlparse

parsed = urlparse(sys.argv[1])
path = unquote(parsed.path)

if parsed.scheme not in {"postgres", "postgresql"} or not parsed.hostname:
    raise SystemExit(1)

if not path.startswith("/") or path == "/":
    raise SystemExit(1)

name = path[1:]

if not name or "/" in name:
    raise SystemExit(1)

print(name)
PY
}

serviceradar_assert_test_database_url() {
  local url="$1"
  local database_name
  local database_name_lower

  if ! database_name="$(serviceradar_database_name_from_url "${url}")"; then
    echo "refusing destructive database operation: URL has an empty or malformed database name" >&2
    return 1
  fi

  database_name_lower="$(printf '%s' "${database_name}" | LC_ALL=C tr '[:upper:]' '[:lower:]')"

  if [[ "${database_name_lower}" =~ (^|_)test(_|$) ]]; then
    return 0
  fi

  if [ "${SERVICERADAR_ALLOW_NON_TEST_INTEGRATION_DATABASE:-0}" = "1" ]; then
    echo "warning: allowing destructive operation against non-test database '${database_name}' via SERVICERADAR_ALLOW_NON_TEST_INTEGRATION_DATABASE" >&2
    return 0
  fi

  echo "refusing destructive operation against non-test database '${database_name}'" >&2
  echo "use 'test' as an underscore-delimited database-name token, or set SERVICERADAR_ALLOW_NON_TEST_INTEGRATION_DATABASE=1 only for an isolated disposable database" >&2
  return 1
}
