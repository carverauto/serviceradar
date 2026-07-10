#!/usr/bin/env bash
set -euo pipefail

# Self-verifying schema-baseline gate.
#
# Proves the committed baseline
#   elixir/serviceradar_core/priv/repo/baseline/platform_schema.sql
# is identical to the schema produced by replaying every migration up to and
# including `included_through` (from baseline/metadata.json). This is the exact
# invariant a fresh install depends on: it loads the baseline, then runs only
# migrations newer than the marker. If the baseline drifts from the migrations
# it claims to summarise, fresh installs get a wrong schema. That is how a
# baseline missing 77 tables shipped and bricked new installs.
#
# The replay needs a TimescaleDB + Apache AGE capable PostgreSQL 18 server: the
# first migrations `CREATE EXTENSION timescaledb` (requires it in the cluster's
# shared_preload_libraries) and `CREATE EXTENSION age`. A stock postgres image
# cannot do this and cannot be preloaded through a GitHub/Forgejo Actions
# `services:` block, so we borrow the same CloudNativePG (Timescale+AGE) cluster
# the rest of the DB-backed CI already uses, via an admin DSN. Two disposable
# scratch databases are created and always dropped; nothing else on the cluster
# is touched.
#
# Required environment:
#   BASELINE_ADMIN_URL   admin/superuser DSN able to CREATE/DROP DATABASE and
#                        CREATE EXTENSION on the Timescale+AGE cluster. In CI
#                        this is the existing SRQL_TEST_ADMIN_URL secret.
#
# Optional environment:
#   PGSSLROOTCERT                          CA cert file for TLS (also honoured by
#                                          pg_dump/psql automatically).
#   CNPG_CA_FILE / SERVICERADAR_TEST_DATABASE_CA_CERT_FILE
#                                          CA cert file the Elixir migrate step
#                                          uses (config/test.exs).
#   BASELINE_DB_PREFIX                     scratch-db name prefix.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CORE_DIR="${ROOT_DIR}/elixir/serviceradar_core"
BASELINE_DIR="${CORE_DIR}/priv/repo/baseline"
SCHEMA_FILE="${BASELINE_DIR}/platform_schema.sql"
METADATA_FILE="${BASELINE_DIR}/metadata.json"
COMPARE_SCRIPT="${ROOT_DIR}/scripts/db/compare-platform-baseline.sh"

for bin in pg_dump psql jq python3; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "${bin} is required" >&2
    exit 1
  fi
done

# Keep the CI gate bounded. Without these settings a bad fixture DSN, password
# prompt, or lock on a scratch database can leave the job silent until the
# workflow-level timeout.
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-20}"
export PGOPTIONS="${PGOPTIONS:-} -c statement_timeout=${BASELINE_PG_STATEMENT_TIMEOUT:-300000} -c lock_timeout=${BASELINE_PG_LOCK_TIMEOUT:-30000}"

if [[ -z "${BASELINE_ADMIN_URL:-}" ]]; then
  echo "BASELINE_ADMIN_URL is required (admin DSN to the Timescale+AGE cluster)" >&2
  exit 1
fi

if [[ ! -f "${SCHEMA_FILE}" ]]; then
  echo "baseline schema not found: ${SCHEMA_FILE}" >&2
  exit 1
fi

included_through="$(jq -r '.included_through // empty' "${METADATA_FILE}")"
if [[ ! "${included_through}" =~ ^[0-9]+$ ]]; then
  echo "baseline metadata missing numeric included_through" >&2
  exit 1
fi

# Unique, collision-free scratch database names (two concurrent CI runs must not
# clash). PostgreSQL identifiers are capped at 63 bytes, so keep the suffix tight.
prefix="${BASELINE_DB_PREFIX:-sr_baseline_ci}"
suffix="${GITHUB_RUN_ID:-$$}_${GITHUB_RUN_ATTEMPT:-0}"
baseline_db="${prefix}_base_${suffix}"
replay_db="${prefix}_replay_${suffix}"

# Derive per-database DSNs (URL-encoded) and connection parts from the admin URL.
eval "$(
  BASELINE_ADMIN_URL="${BASELINE_ADMIN_URL}" \
  BASE_DB="${baseline_db}" \
  REPLAY_DB="${replay_db}" \
  python3 - <<'PY'
import os
from urllib.parse import urlparse, parse_qs, urlencode

u = urlparse(os.environ["BASELINE_ADMIN_URL"])
qs = parse_qs(u.query)
sslmode = (qs.get("sslmode") or ["require"])[0] or "require"
qs["sslmode"] = [sslmode]
for key in ("sslrootcert", "sslcert", "sslkey"):
    qs.pop(key, None)
host = u.hostname or ""
admin_db = (u.path or "/").lstrip("/") or "postgres"

if not host or not u.username:
    raise SystemExit("BASELINE_ADMIN_URL must include host and username")


def dsn(db):
    # Rebuild by swapping only the database path (and normalising sslmode).
    # Keep the original netloc verbatim so already-percent-encoded credentials
    # are never re-encoded.
    return u._replace(path="/" + db, query=urlencode(qs, doseq=True)).geturl()


def sh(name, value):
    return "%s=%s" % (name, "'" + str(value).replace("'", "'\\''") + "'")


print(sh("SR_SSLMODE", sslmode))
print(sh("SR_DB_HOST", host))
print(sh("SR_ADMIN_DSN", dsn(admin_db)))
print(sh("SR_BASELINE_DSN", dsn(os.environ["BASE_DB"])))
print(sh("SR_REPLAY_DSN", dsn(os.environ["REPLAY_DB"])))
PY
)"

admin_psql() {
  # Connect to the maintenance database for CREATE/DROP DATABASE.
  psql -w "${SR_ADMIN_DSN}" -v ON_ERROR_STOP=1 -q -X "$@"
}

drop_scratch_dbs() {
  local quiet="${1:-false}"

  if [[ "${quiet}" != "true" ]]; then
    echo "==> Dropping any prior scratch databases"
  fi

  # WITH (FORCE) terminates any lingering backends so the drop cannot hang.
  admin_psql -c "DROP DATABASE IF EXISTS \"${baseline_db}\" WITH (FORCE)" >/dev/null 2>&1 || true
  admin_psql -c "DROP DATABASE IF EXISTS \"${replay_db}\" WITH (FORCE)" >/dev/null 2>&1 || true
}
trap 'drop_scratch_dbs true' EXIT

echo "==> Creating scratch databases on ${SR_DB_HOST} (sslmode=${SR_SSLMODE})"
drop_scratch_dbs
echo "==> Creating baseline scratch database ${baseline_db}"
admin_psql -c "CREATE DATABASE \"${baseline_db}\""
echo "==> Creating replay scratch database ${replay_db}"
admin_psql -c "CREATE DATABASE \"${replay_db}\""

echo "==> Loading committed baseline into ${baseline_db}"
psql -w "${SR_BASELINE_DSN}" -v ON_ERROR_STOP=1 -q -X -f "${SCHEMA_FILE}" >/dev/null

echo "==> Replaying migrations (through ${included_through}) into ${replay_db}"
# Ecto stores its migration ledger in the `platform` prefix
# (config/test.exs: migration_default_prefix), so the schema must exist before
# the first migration runs. Startup does the same via ensure_platform_schema!.
psql -w "${SR_REPLAY_DSN}" -v ON_ERROR_STOP=1 -q -X -c "CREATE SCHEMA IF NOT EXISTS platform" >/dev/null

(
  cd "${CORE_DIR}"
  MIX_ENV=test \
  SERVICERADAR_TEST_DATABASE_URL="${SR_REPLAY_DSN}" \
  CNPG_SSL_MODE="${SR_SSLMODE}" \
  CNPG_TLS_SERVER_NAME="${SR_DB_HOST}" \
    mix ecto.migrate --to "${included_through}"
)

echo "==> Comparing baseline schema against migration replay"
BASELINE_DATABASE_URL="${SR_BASELINE_DSN}" \
REPLAY_DATABASE_URL="${SR_REPLAY_DSN}" \
  "${COMPARE_SCRIPT}"
