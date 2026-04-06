#!/usr/bin/env bash

set -euo pipefail

namespace="${SRQL_FIXTURE_NAMESPACE:-srql-fixtures}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required to reset the srql fixture test database." >&2
  exit 1
fi

parser="$(command -v python3 || command -v python || true)"
if [ -z "${parser}" ]; then
  echo "python is required to reset the srql fixture test database." >&2
  exit 1
fi

db_url="${SERVICERADAR_TEST_DATABASE_URL:-${SRQL_TEST_DATABASE_URL:-}}"

if [ -z "${db_url}" ]; then
  echo "SERVICERADAR_TEST_DATABASE_URL or SRQL_TEST_DATABASE_URL is required." >&2
  exit 1
fi

db_name="$("${parser}" - "$db_url" <<'PY'
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

admin_user="$(kubectl get secret srql-test-admin-credentials -n "${namespace}" -o jsonpath='{.data.username}' | base64 -d)"
admin_pass="$(kubectl get secret srql-test-admin-credentials -n "${namespace}" -o jsonpath='{.data.password}' | base64 -d)"

primary_pod="$(kubectl get pod -n "${namespace}" -l cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')"

if [ -z "${primary_pod}" ]; then
  echo "could not find srql fixture primary pod in namespace ${namespace}" >&2
  exit 1
fi

sql="$("${parser}" - "$db_url" <<'PY'
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

extensions_sql='
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "citext";
CREATE EXTENSION IF NOT EXISTS "timescaledb";
CREATE EXTENSION IF NOT EXISTS "age";
CREATE EXTENSION IF NOT EXISTS "postgis";
CREATE EXTENSION IF NOT EXISTS "vector";
'

age_bootstrap_sql="$("${parser}" - "$app_user" <<'PY'
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

run_psql() {
  local database="$1"

  PGPASSWORD="${admin_pass}" kubectl exec -i -n "${namespace}" "${primary_pod}" -- \
    env PGPASSWORD="${admin_pass}" \
    psql -h 127.0.0.1 -U "${admin_user}" -d "${database}" -v ON_ERROR_STOP=1
}

printf "%s\n" "${sql}" | run_psql postgres
printf "%s\n" "${extensions_sql}" | run_psql "${db_name}"
printf "%s\n" "${age_bootstrap_sql}" | run_psql "${db_name}"
