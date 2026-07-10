#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/db/test-database-url-guard.sh
source "${SCRIPT_DIR}/db/test-database-url-guard.sh"

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <admin_url> <db_url>" >&2
  exit 1
fi

admin_url="$1"
db_url="$2"

serviceradar_assert_test_database_url "${db_url}"

if ! command -v psql >/dev/null 2>&1; then
  echo "psql is required to drop the integration database." >&2
  exit 1
fi

parser="$(command -v python3 || command -v python || true)"
if [ -z "${parser}" ]; then
  echo "python is required to drop the integration database." >&2
  exit 1
fi

database_name="$(serviceradar_database_name_from_url "${db_url}")"

sql="$("${parser}" - "${database_name}" <<'PY'
import sys
dbname = sys.argv[1]

if not dbname:
    raise SystemExit("test database URL must include a database name")


def quote_ident(value: str) -> str:
    return '"' + value.replace('"', '""') + '"'


def quote_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


print(
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
    "WHERE datname = {} AND pid <> pg_backend_pid();".format(quote_literal(dbname))
)
print("DROP DATABASE IF EXISTS {} WITH (FORCE);".format(quote_ident(dbname)))
PY
)"

printf "%s\n" "${sql}" | psql "${admin_url}" -v ON_ERROR_STOP=1
