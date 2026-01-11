#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <admin_url> <db_url>" >&2
  exit 1
fi

admin_url="$1"
db_url="$2"

if ! command -v psql >/dev/null 2>&1; then
  echo "psql is required to reset the integration database." >&2
  exit 1
fi

parser="$(command -v python3 || command -v python || true)"
if [ -z "$parser" ]; then
  echo "python is required to reset the integration database." >&2
  exit 1
fi

sql="$("$parser" - "$db_url" <<'PY'
import sys
from urllib.parse import urlparse

u = urlparse(sys.argv[1])
dbname = (u.path or "/")[1:]
user = u.username

def quote_ident(value: str) -> str:
    return '"' + value.replace('"', '""') + '"'

def quote_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"

if not dbname or not user:
    raise SystemExit("SERVICERADAR_TEST_DATABASE_URL must include user and database name")

print(
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
    "WHERE datname = {} AND pid <> pg_backend_pid();".format(quote_literal(dbname))
)
print("DROP DATABASE IF EXISTS {};".format(quote_ident(dbname)))
print("CREATE DATABASE {} OWNER {};".format(quote_ident(dbname), quote_ident(user)))
PY
)"

printf "%s\n" "$sql" | psql "$admin_url" -v ON_ERROR_STOP=1
