#!/usr/bin/env bash
# End-to-end CORE seasonal proof against the srql-fixtures CNPG TimescaleDB.
#
#   raw timeseries_metrics  ->  REAL hourly continuous aggregate
#     ->  REAL SRQL profile_hour_of_week verb SQL  ->  REAL dispose_seasonal kernel
#
# Proves the F15 data feed end to end on real infrastructure (not just the kernel).
# Creates and DROPS its own scratch database. Reads the CNPG admin secret from the
# `srql-fixtures` namespace (never printed); see .claude/skills/srql-fixtures-db-tests.
set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root
HARNESS=tools/anomaly-proof
O="$HARNESS/out"; mkdir -p "$O"
BIN=target/debug/disposition-backtest
[ -x "$BIN" ] || { echo "build first: cargo build --manifest-path rust/anomaly-disposition/Cargo.toml --bin disposition-backtest"; exit 1; }

NS=srql-fixtures
NODEPORT=$(kubectl get svc srql-fixture-rw-ext -n "$NS" -o jsonpath='{.spec.ports[0].nodePort}')
ADMIN_USER=$(kubectl get secret srql-test-admin-credentials -n "$NS" -o jsonpath='{.data.username}' | base64 -d)
ADMIN_PASS=$(kubectl get secret srql-test-admin-credentials -n "$NS" -o jsonpath='{.data.password}' | base64 -d)

DB_HOST=""
for host in 192.168.10.31 192.168.10.96 $(kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{" "}{end}'); do
  if timeout 4 bash -c "PGPASSWORD=\"$ADMIN_PASS\" psql \"postgresql://${ADMIN_USER}@${host}:${NODEPORT}/postgres?sslmode=require\" -Atc 'select 1' >/dev/null 2>&1"; then
    DB_HOST="$host"; break
  fi
done
[ -n "$DB_HOST" ] || { echo "no reachable srql-fixtures NodePort host"; exit 1; }

base="postgresql://${ADMIN_USER}@${DB_HOST}:${NODEPORT}"
DB="anomaly_proof_$(date +%s)_$$"
q() { PGPASSWORD="$ADMIN_PASS" psql "$@"; }
cleanup() { q "${base}/postgres?sslmode=require" -qc "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1 && echo "dropped scratch db $DB"; }
trap cleanup EXIT

q "${base}/postgres?sslmode=require" -v ON_ERROR_STOP=1 -qc "CREATE DATABASE $DB"
URL="${base}/${DB}?sslmode=require"
echo "scratch db $DB on $DB_HOST:$NODEPORT (timescaledb $(q "$URL" -Atc "select extversion from pg_extension where extname='timescaledb'" 2>/dev/null || echo '?'))"

q "$URL" -v ON_ERROR_STOP=1 -qf "$HARNESS/db/schema.sql"
python3 "$HARNESS/gen_seasonal_db.py" >/dev/null
q "$URL" -v ON_ERROR_STOP=1 -q \
  -c "\copy timeseries_metrics(timestamp,device_id,metric_type,metric_name,value) FROM '$PWD/$O/timeseries_seed.csv' WITH (FORMAT csv, HEADER true)" \
  -c "CALL refresh_continuous_aggregate('timeseries_metrics_hourly', NULL, NULL);"
echo "loaded $(q "$URL" -Atc 'select count(*) from timeseries_metrics_hourly') hourly buckets"

echo "--- REAL profile_hour_of_week verb SQL over the CAGG ---"
q "$URL" --csv -t -f "$HARNESS/db/seasonal_verb.sql" > "$O/seasonal_db_rows.csv"
column -s, -t < "$O/seasonal_db_rows.csv"

echo "--- fed to the REAL dispose_seasonal kernel ---"
{ echo "series_key,dow,hod,sample_value,bucket_count,bucket_sum,bucket_sum_sq,center,mad,p05,p95,consecutive_anomalous,baseline_excludes_latest"
  cat "$O/seasonal_db_rows.csv"; } | "$BIN" --kind seasonal | column -s, -t
