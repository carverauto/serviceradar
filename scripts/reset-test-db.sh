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

db_name="$("$parser" - "$db_url" <<'PY'
import sys
from urllib.parse import urlparse

parsed = urlparse(sys.argv[1])
dbname = (parsed.path or "/")[1:]
user = parsed.username

if not dbname or not user:
    raise SystemExit("SERVICERADAR_TEST_DATABASE_URL must include user and database name")

print(dbname)
print(user)
PY
)"

app_user="$(printf '%s\n' "$db_name" | sed -n '2p')"
db_name="$(printf '%s\n' "$db_name" | sed -n '1p')"

admin_db_url="$("$parser" - "$admin_url" "$db_name" <<'PY'
import sys
from urllib.parse import quote, urlparse, urlunparse

admin_url, dbname = sys.argv[1], sys.argv[2]

if admin_url.startswith(("postgres://", "postgresql://")):
    parsed = urlparse(admin_url)
    print(
        urlunparse(
            (
                parsed.scheme,
                parsed.netloc,
                "/" + quote(dbname, safe=""),
                parsed.params,
                parsed.query,
                parsed.fragment,
            )
        )
    )
else:
    escaped = dbname.replace("\\", "\\\\").replace("'", "\\'")
    print(f"dbname='{escaped}' {admin_url}")
PY
)"

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

extensions_sql='
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "citext";
CREATE EXTENSION IF NOT EXISTS "timescaledb";
CREATE EXTENSION IF NOT EXISTS "age";
CREATE EXTENSION IF NOT EXISTS "postgis";
CREATE EXTENSION IF NOT EXISTS "vector";
'

printf "%s\n" "$extensions_sql" | psql "$admin_db_url" -v ON_ERROR_STOP=1

age_bootstrap_sql="$("$parser" - "$app_user" <<'PY'
import sys

app_user = sys.argv[1]
graphs = ["serviceradar_topology", "serviceradar", "platform_graph"]

def quote_ident(value: str) -> str:
    return '"' + value.replace('"', '""') + '"'

def quote_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"

app_user_ident = quote_ident(app_user)
graph_literals = ", ".join(quote_literal(graph) for graph in graphs)

print(f"GRANT USAGE ON SCHEMA ag_catalog TO {app_user_ident};")
print(f"GRANT ALL ON ALL TABLES IN SCHEMA ag_catalog TO {app_user_ident};")
print(f"GRANT ALL ON ALL SEQUENCES IN SCHEMA ag_catalog TO {app_user_ident};")
print(f"GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA ag_catalog TO {app_user_ident};")
print("LOAD 'age';")
print("SET search_path = ag_catalog, pg_catalog, \"$user\", public;")
print(
    "DO $$\n"
    "DECLARE\n"
    "  graph_name text;\n"
    "  relname text;\n"
    "BEGIN\n"
    f"  FOREACH graph_name IN ARRAY ARRAY[{graph_literals}] LOOP\n"
    "    BEGIN\n"
    "      PERFORM ag_catalog.create_graph(graph_name);\n"
    "    EXCEPTION\n"
    "      WHEN duplicate_object OR duplicate_schema THEN\n"
    "        NULL;\n"
    "    END;\n"
    "\n"
    "    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = graph_name) THEN\n"
    f"      EXECUTE format('GRANT USAGE, CREATE ON SCHEMA %I TO {app_user_ident}', graph_name);\n"
    f"      EXECUTE format('GRANT ALL ON ALL TABLES IN SCHEMA %I TO {app_user_ident}', graph_name);\n"
    f"      EXECUTE format('GRANT ALL ON ALL SEQUENCES IN SCHEMA %I TO {app_user_ident}', graph_name);\n"
    f"      EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT ALL ON TABLES TO {app_user_ident}', graph_name);\n"
    f"      EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT ALL ON SEQUENCES TO {app_user_ident}', graph_name);\n"
    f"      EXECUTE format('ALTER SCHEMA %I OWNER TO {app_user_ident}', graph_name);\n"
    "\n"
    "      FOR relname IN\n"
    "        SELECT c.relname\n"
    "        FROM pg_class c\n"
    "        JOIN pg_namespace n ON n.oid = c.relnamespace\n"
    "        WHERE n.nspname = graph_name\n"
    "          AND c.relkind IN ('r', 'p')\n"
    "      LOOP\n"
    f"        EXECUTE format('ALTER TABLE %I.%I OWNER TO {app_user_ident}', graph_name, relname);\n"
    "      END LOOP;\n"
    "\n"
    "      FOR relname IN\n"
    "        SELECT c.relname\n"
    "        FROM pg_class c\n"
    "        JOIN pg_namespace n ON n.oid = c.relnamespace\n"
    "        WHERE n.nspname = graph_name\n"
    "          AND c.relkind = 'S'\n"
    "          AND NOT EXISTS (\n"
    "            SELECT 1 FROM pg_depend d\n"
    "            WHERE d.objid = c.oid\n"
    "              AND d.deptype = 'a'\n"
    "          )\n"
    "      LOOP\n"
    f"        EXECUTE format('ALTER SEQUENCE %I.%I OWNER TO {app_user_ident}', graph_name, relname);\n"
    "      END LOOP;\n"
    "    END IF;\n"
    "  END LOOP;\n"
    "END\n"
    "$$;"
)
PY
)"

printf "%s\n" "$age_bootstrap_sql" | psql "$admin_db_url" -v ON_ERROR_STOP=1
