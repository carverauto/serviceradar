---
title: CNPG Monitoring
---

# CNPG Monitoring and Dashboards

ServiceRadar now stores every telemetry signal (events, OTEL logs/metrics/traces, registry tables) inside the CloudNativePG (CNPG) cluster running TimescaleDB. This guide captures the dashboards and SQL checks operators should wire into Grafana or the toolbox so they can confirm ingestion, retention, and pgx pool health without relying on the retired CNPG parity checks.

## Data Source Setup

Add the CNPG reader as a PostgreSQL data source in Grafana (or any SQL-friendly dashboarding tool):

1. **Host / Port**: `cnpg-rw.<namespace>.svc.cluster.local:5432` (the CNPG RW service in your cluster).
2. **Database**: `telemetry`.
3. **User**: `postgres` (or a scoped read-only role).
4. **TLS**: enable `verify-full` with the CA/cert pair that ships in `/etc/serviceradar/certs` or the `cnpg-ca` secret.
5. **Connection pooling**: set the maximum concurrent connections to something small (≤5) so Grafana dashboards do not starve the application pool.

Grafana can query Timescale directly, so each panel below simply executes SQL against the hypertables. If you prefer Prometheus, re-export these queries through the `pg_prometheus` or `pgwatch2` exporters—the SQL is identical.

## Ingestion Dashboards

Use the following query to chart OTEL log throughput (works for metrics/traces by swapping the table name):

```sql
SELECT
  time_bucket('5 minutes', created_at) AS bucket,
  COUNT(*) AS rows_ingested
FROM logs
WHERE created_at >= now() - INTERVAL '24 hours'
GROUP BY bucket
ORDER BY bucket;
```

Create three panels that hit `logs`, `otel_metrics`, and `otel_traces`. Grafana’s stacked bar visualization makes pipeline gaps obvious—missing buckets mean `serviceradar-db-event-writer` is not keeping up. Keep a single-stat panel that runs `SELECT COUNT(*) FROM events WHERE created_at >= now() - INTERVAL '5 minutes';` to power an alert when ingestion drops to zero.

### db-event-writer Heatmap

Build a table panel from `pg_stat_activity` to watch the pgx consumers:

```sql
SELECT
  wait_event_type,
  wait_event,
  state,
  COUNT(*) AS sessions
FROM pg_stat_activity
WHERE application_name LIKE 'db-writer%'
  AND datname = current_database()
GROUP BY 1,2,3
ORDER BY sessions DESC;
```

Add a companion panel that counts `rows_processed` log entries via Loki or `kubectl logs` so operators can compare SQL volume against the application logs the moment a spike appears.

## Retention and Compression Health

Timescale registers background jobs for each hypertable. Surface their state with:

```sql
SELECT
  job_id,
  job_type,
  hypertable_name,
  last_run_duration,
  last_successful_finish
FROM timescaledb_information.job_stats
WHERE hypertable_name IN ('events', 'logs', 'otel_metrics', 'otel_traces')
ORDER BY hypertable_name, job_type;
```

Color the `last_successful_finish` column red if it is older than 15 minutes to catch stuck retention jobs. Pair this with the chunk/compression dashboard:

```sql
SELECT
  h.hypertable_name,
  round(h.total_bytes / 1024 / 1024, 2) AS mb,
  c.compression_enabled,
  c.compressed_chunks,
  c.uncompressed_chunks
FROM timescaledb_information.hypertable_detailed_size h
LEFT JOIN timescaledb_information.hypertable_compression_stats c
  ON h.hypertable_name = c.hypertable_name
WHERE h.hypertable_name IN ('events', 'logs', 'otel_metrics', 'otel_traces')
ORDER BY mb DESC;
```

Watching the compressed/uncompressed split helps explain PVC growth and ensures operators run `refresh_continuous_aggregate` after backfills.

## Query and pgx Error Watch

Enable `pg_stat_statements` (`CREATE EXTENSION IF NOT EXISTS pg_stat_statements;`) and add a “Top 10 Slow Queries” table:

```sql
SELECT
  round(mean_exec_time, 2) AS mean_ms,
  calls,
  rows,
  query
FROM pg_stat_statements
WHERE query ILIKE '%otel%' OR query ILIKE '%events%'
ORDER BY mean_exec_time DESC
LIMIT 10;
```

Tie this to an alert that fires if `mean_ms` exceeds your SLA for more than two consecutive scrapes. For connection pool health, track waiters using `pg_stat_activity`:

```sql
SELECT
  wait_event_type,
  wait_event,
  COUNT(*) AS blocked
FROM pg_stat_activity
WHERE wait_event_type IS NOT NULL
GROUP BY 1,2
ORDER BY blocked DESC;
```

Any sustained growth indicates the pgx pool is undersized or a migration locked a hypertable.

## PgBouncer Pooler Checks

When `cnpg.pooler.enabled=true`, the Helm chart deploys a CNPG `Pooler` resource
for PgBouncer. Demo also enables `cnpg.pooler.monitoring.podMonitor.enabled=true`
so Prometheus Operator scrapes every PgBouncer pod. Verify that the pooler exists
and has ready replicas:

```bash
kubectl get pooler -n <namespace>
kubectl get pods -n <namespace> -l cnpg.io/poolerName=cnpg-pooler-rw
kubectl get svc -n <namespace> cnpg-pooler-rw
kubectl get podmonitor -n <namespace> cnpg-pooler-rw-pgbouncer
```

Inspect pool saturation through the CNPG PgBouncer exporter metrics. The CNPG
operator exposes metrics with the `cnpg_pgbouncer_` prefix from each pooler pod:

```bash
kubectl port-forward -n <namespace> deploy/cnpg-pooler-rw 9127:9127
curl -s http://127.0.0.1:9127/metrics | rg 'cnpg_pgbouncer_(pools|lists|stats)'
```

Watch for sustained client waiters, server connections at the configured pool
limit, or high client connection counts. Those symptoms mean the pooler is
protecting Postgres backends but application/database budgets still need tuning.
For HA, the ServiceRadar chart defaults to three Pooler pods with preferred
same-pooler pod anti-affinity. Production multi-node clusters can make this
strict with `cnpg.pooler.ha.podAntiAffinity.type=required`.

Migration and bootstrap jobs should still connect to `cnpg-rw.<namespace>.svc.cluster.local`
directly. Do not troubleshoot DDL or extension setup through the transaction
pooler.

## Demo Slow-Query Triage Runbook

Use this flow for issue triage in `demo` when web-ng pages degrade.

1. Capture the current top query offenders from `pg_stat_statements`:

```sql
SELECT
  round(total_exec_time, 2) AS total_exec_ms,
  round(mean_exec_time, 2) AS mean_exec_ms,
  round(max_exec_time, 2) AS max_exec_ms,
  calls,
  rows,
  query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;
```

2. Check currently running and blocked statements:

```sql
SELECT
  pid,
  usename,
  application_name,
  state,
  wait_event_type,
  wait_event,
  now() - query_start AS runtime,
  query
FROM pg_stat_activity
WHERE datname = current_database()
  AND state <> 'idle'
ORDER BY runtime DESC
LIMIT 20;
```

3. Confirm lock contention hotspots:

```sql
SELECT
  locktype,
  relation::regclass AS relation,
  mode,
  granted,
  COUNT(*) AS lock_count
FROM pg_locks
GROUP BY 1,2,3,4
ORDER BY lock_count DESC
LIMIT 20;
```

4. Correlate with CNPG slow-query logs (`log_min_duration_statement=500ms` in demo):

```bash
kubectl logs -n demo cnpg-1 --since=15m | rg "duration:|statement:"
```

5. Optional sampling reset to isolate a fresh incident window:

```sql
SELECT pg_stat_statements_reset();
```

Record the reset timestamp and compare the next 10-15 minutes against web-ng request latency and service logs.

## Slow-Query Metric Schema (Demo)

Use these low-cardinality derived metrics from `pg_stat_statements` for dashboards and alerts:

- `cnpg_slow_query_total`: count of statements where `mean_exec_time >= 500ms`.
- `cnpg_slow_query_calls_total`: sum of `calls` for statements where `mean_exec_time >= 500ms`.
- `cnpg_slow_query_time_ms_total`: sum of `total_exec_time` for statements where `mean_exec_time >= 500ms`.
- `cnpg_query_latency_bucket`: bucketed statement counts by `mean_exec_time` range (`lt_100`, `100_500`, `500_1000`, `1000_5000`, `gte_5000`).
- `cnpg_query_error_proxy_total`: count of statements with `rows = 0` and high mean latency (proxy signal, not SQLSTATE-accurate).

Avoid raw query text as a label. Use normalized grouping (service, database, latency bucket).

## Slow-Query Metric Derivation Queries

Use these SQL panels in Grafana against CNPG:

```sql
-- Snapshot counters for slow-query load
SELECT
  COUNT(*) FILTER (WHERE mean_exec_time >= 500) AS cnpg_slow_query_total,
  COALESCE(SUM(calls) FILTER (WHERE mean_exec_time >= 500), 0) AS cnpg_slow_query_calls_total,
  COALESCE(ROUND((SUM(total_exec_time) FILTER (WHERE mean_exec_time >= 500))::numeric, 2), 0) AS cnpg_slow_query_time_ms_total
FROM pg_stat_statements;
```

```sql
-- Latency bucket distribution from statement means
SELECT
  CASE
    WHEN mean_exec_time < 100 THEN 'lt_100'
    WHEN mean_exec_time < 500 THEN '100_500'
    WHEN mean_exec_time < 1000 THEN '500_1000'
    WHEN mean_exec_time < 5000 THEN '1000_5000'
    ELSE 'gte_5000'
  END AS latency_bucket,
  COUNT(*) AS statement_count,
  COALESCE(SUM(calls), 0) AS call_count
FROM pg_stat_statements
GROUP BY 1
ORDER BY 1;
```

```sql
-- Top slow statements for drill-down panel
SELECT
  ROUND(mean_exec_time::numeric, 2) AS mean_ms,
  ROUND(max_exec_time::numeric, 2) AS max_ms,
  ROUND(total_exec_time::numeric, 2) AS total_ms,
  calls,
  rows,
  query
FROM pg_stat_statements
WHERE mean_exec_time >= 500
ORDER BY total_exec_time DESC
LIMIT 20;
```

## Validation Flow (Demo)

1. Run the three SQL queries above and save panel screenshots/results.
2. Generate a known slow query in a controlled window (for example, a high-cardinality SRQL page load).
3. Re-run the panels and verify:
   - `cnpg_slow_query_total` increases.
   - At least one row lands in `500_1000` or higher bucket.
   - Top statements panel includes the expected query family.
4. Confirm CNPG logs show matching slow entries:

```bash
kubectl logs -n demo cnpg-1 --since=10m | rg "duration:|statement:"
```

## Threshold Tuning and Rollback

Default demo threshold is `log_min_duration_statement=500ms`.

- Increase to reduce log volume/noise: `750ms` or `1000ms`.
- Decrease for deeper analysis windows: `200ms` or `100ms` (short-lived only).

Helm values location:
- `spire.postgres.postgresqlParameters.log_min_duration_statement` in `helm/serviceradar/values.yaml`.

Rollback path:
1. Revert threshold and related CNPG parameter edits in Helm/Kustomize.
2. Deploy updated manifests.
3. Verify CNPG restart/reload and confirm expected log volume.
4. Keep `pg_stat_statements` queries active so baseline visibility remains intact.

### Demo baseline snapshot (March 5, 2026 UTC)

After rollout in `demo`, we captured a 3-minute baseline sample window (12 samples, 15s interval):

- Slow query cardinality (`mean_exec_time >= 500ms`): stable at `0` after reset.
- Latency buckets: all observed statements in `lt_100` during baseline.
- Slow log verification: a controlled `SELECT pg_sleep(0.7)` test was logged as expected and then cleared with `pg_stat_statements_reset()`.

Use this baseline to tune alerts:
- Warning: `cnpg_slow_query_total > 5` for 10 minutes.
- Critical: `cnpg_slow_query_total > 20` for 10 minutes.
- Critical: any `latency_bucket = gte_5000` for 5 minutes.

## Alert Ideas

| Signal | Query/Metric | Suggested Threshold |
|--------|--------------|---------------------|
| Ingestion Stall | `SELECT COUNT(*) FROM logs WHERE created_at >= now() - INTERVAL '5 minutes'` | `< 1` row triggers paging |
| Retention Lag | `timescaledb_information.job_stats.last_successful_finish` | older than 15 minutes |
| PVC Growth | `hypertable_detailed_size.total_bytes` | >10% growth per hour |
| pgx Errors | `kubectl logs deploy/serviceradar-db-event-writer | grep "cnpg"` | any non-zero error rate should alert |
| Slow Query Load (Warning) | `cnpg_slow_query_total` | `> 5` statements for 10m |
| Slow Query Load (Critical) | `cnpg_slow_query_total` | `> 20` statements for 10m |
| Slow Query Time Burn | `cnpg_slow_query_time_ms_total` | sustained increase >2x baseline |
| Extreme Latency Bucket | `latency_bucket = gte_5000` | any non-zero for 5m |

Reuse your existing Prometheus stack to alert on pod restarts (`kube_pod_container_status_restarts_total`) and container CPU saturation (`container_cpu_usage_seconds_total`) for the CNPG and db-event-writer pods.

## Trigram Indexes for Text Search

ServiceRadar can enable the `pg_trgm` extension and add GIN trigram indexes to optimize `ILIKE` queries. When you add those indexes, define them in the Ash rebuild migration (`elixir/serviceradar_core/priv/repo/migrations/20260117090000_rebuild_schema.exs`) and keep the list below in sync.

### Indexed Columns

No trigram indexes are currently defined in the Ash rebuild migration. Add them when search latency requires it.

### Verifying Index Usage

For tables with more than ~100 rows, PostgreSQL should use trigram indexes for `ILIKE` queries:

```sql
EXPLAIN ANALYZE SELECT * FROM <table> WHERE <column> ILIKE '%pattern%';
```

Look for a `Bitmap Index Scan` on your trigram index. PostgreSQL may choose a sequential scan for very small tables where the overhead of using an index exceeds the cost of scanning all rows.

### Performance Characteristics

- **Read performance**: GIN trigram indexes provide fast lookups for `LIKE`, `ILIKE`, and similarity queries, including patterns with leading wildcards.
- **Write overhead**: GIN indexes are more expensive to maintain than B-tree indexes. Expect slightly slower `INSERT`/`UPDATE` operations on indexed columns.
- **Storage**: GIN trigram indexes are typically 1-3x the size of the indexed column data.

### Checking Index Health

```sql
-- List all trigram indexes
SELECT indexname, indexdef
FROM pg_indexes
WHERE indexname LIKE '%trgm%';

-- Check index size
SELECT pg_size_pretty(pg_relation_size('idx_unified_devices_hostname_trgm'));
```
