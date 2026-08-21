---
title: CNPG Monitoring
---

# CNPG Monitoring and Dashboards

ServiceRadar stores every telemetry signal (events, OTEL logs/metrics/traces, registry tables) inside the CloudNativePG (CNPG) cluster running TimescaleDB. This guide captures the dashboards and SQL checks operators should wire into Grafana or the toolbox to confirm ingestion, retention, and pgx pool health.

## Data Source Setup

Add the CNPG reader as a PostgreSQL data source in Grafana (or any SQL-friendly dashboarding tool):

1. **Host / Port**: `cnpg-rw.<namespace>.svc.cluster.local:5432` (the CNPG RW service in your cluster).
2. **Database**: `serviceradar`.
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
FROM platform.logs
WHERE created_at >= now() - INTERVAL '24 hours'
GROUP BY bucket
ORDER BY bucket;
```

Create three panels that hit `platform.logs`, `platform.otel_metrics`, and `platform.otel_traces`. Grafana's stacked bar visualization makes pipeline gaps obvious; missing buckets mean the core-elx ingestion workers are not keeping up. Keep a single-stat panel that runs `SELECT COUNT(*) FROM platform.events WHERE created_at >= now() - INTERVAL '5 minutes';` to power an alert when ingestion drops to zero.

### Ingestion Heatmap

Build a table panel from `pg_stat_activity` to watch ingestion database work:

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
  AND hypertable_schema = 'platform'
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
WHERE h.hypertable_schema = 'platform'
  AND h.hypertable_name IN ('events', 'logs', 'otel_metrics', 'otel_traces')
ORDER BY mb DESC;
```

Watching the compressed/uncompressed split helps explain PVC growth and ensures operators run `refresh_continuous_aggregate` after backfills.

### Write-Flood Growth Tracking

After the anomaly/capacity/flow flood fixes land, track the actual write rate for
the hot tables called out in F46:

```bash
psql "$DATABASE_URL" -f scripts/db/write_flood_growth.sql
```

Run the query before deployment, immediately after deployment, and then hourly
for at least 24 hours. The output reports current table bytes plus 1-hour and
24-hour row rates for `platform.ocsf_events`, `platform.capacity_forecasts`, and
`platform.ocsf_network_activity`. The expected post-fix signal is a sustained
drop in `ocsf_events` and `capacity_forecasts` rows per hour; flow rows may stay
near the exporter packet rate, so use the flow row rate together with the
sampling-adjusted logical volume to confirm F39 is no longer undercounting
sampled traffic while retention bounds physical table growth.

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
for PgBouncer. Enabling `cnpg.pooler.monitoring.podMonitor.enabled=true` lets
Prometheus Operator scrape every PgBouncer pod. Verify that the pooler exists
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

## Slow-Query Triage

When web-ng pages degrade, triage slow queries against CNPG:

1. Capture the top offenders from `pg_stat_statements`, ordered by `total_exec_time`.
2. Check currently running and blocked statements in `pg_stat_activity`
   (`state <> 'idle'`, ordered by runtime).
3. Confirm lock contention hotspots in `pg_locks`.
4. Correlate with CNPG slow-query logs (`log_min_duration_statement=500ms`):

```bash
kubectl logs -n <namespace> <cnpg-pod> --since=15m | rg "duration:|statement:"
```

Optionally call `SELECT pg_stat_statements_reset();` to isolate a fresh incident
window, then compare the next 10-15 minutes against web-ng request latency.

## Slow-Query Dashboards

Surface slow-query load with these panels against `pg_stat_statements`. Avoid raw
query text as a label—group by latency bucket instead.

```sql
-- Snapshot counters for slow-query load
SELECT
  COUNT(*) FILTER (WHERE mean_exec_time >= 500) AS slow_query_total,
  COALESCE(SUM(calls) FILTER (WHERE mean_exec_time >= 500), 0) AS slow_query_calls_total,
  COALESCE(ROUND((SUM(total_exec_time) FILTER (WHERE mean_exec_time >= 500))::numeric, 2), 0) AS slow_query_time_ms_total
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

The slow-query log threshold is set in `helm/serviceradar/values.yaml`. Which key
applies depends on which CNPG cluster the install runs:

- `cnpg.postgresqlParameters.log_min_duration_statement` for a normal install.
- `spire.postgres.postgresqlParameters.log_min_duration_statement` when
  `spire.postgres.enabled` is true, because that template replaces the main CNPG
  cluster entirely.

A reasonable starting value is `500ms`; raise it to reduce log noise or lower it
for short deep-analysis windows. After enabling slow-query logging on a healthy
system, capture a baseline (most statements should land in `lt_100`) and use it
to tune alert thresholds.

### Bind parameters are deliberately not logged

Both blocks also pin `log_parameter_max_length: "0"`, which keeps bind parameters
out of the slow-query log. PostgreSQL defaults this to `-1` (unlimited), and on a
bulk-loading workload that is a real amplifier: a 2000-row insert logged roughly
742 KB of parameters for a single statement.

Do not "fix" this by setting a small positive value. The limit truncates **per
parameter** and there is no per-statement cap, so a 1000-row by 10-column insert
at 1 kB each still emits about 10 MB for one statement. Only `0` bounds it.

Little diagnostic value is lost: the parameterised statement text and its
duration are still logged, and normalised query text with timings comes from
`pg_stat_statements`, which this chart enables with `track=all`.

## Alert Ideas

| Signal | Query/Metric | Suggested Threshold |
|--------|--------------|---------------------|
| Ingestion Stall | `SELECT COUNT(*) FROM platform.logs WHERE created_at >= now() - INTERVAL '5 minutes'` | `< 1` row triggers paging |
| Retention Lag | `timescaledb_information.job_stats.last_successful_finish` | older than 15 minutes |
| PVC Growth | `hypertable_detailed_size.total_bytes` | >10% growth per hour |
| Ingestion Errors | `kubectl logs deploy/serviceradar-core | grep "cnpg"` | any non-zero error rate should alert |
| Slow Query Load (Warning) | `cnpg_slow_query_total` | `> 5` statements for 10m |
| Slow Query Load (Critical) | `cnpg_slow_query_total` | `> 20` statements for 10m |
| Slow Query Time Burn | `cnpg_slow_query_time_ms_total` | sustained increase >2x baseline |
| Extreme Latency Bucket | `latency_bucket = gte_5000` | any non-zero for 5m |

Reuse your existing Prometheus stack to alert on pod restarts (`kube_pod_container_status_restarts_total`) and container CPU saturation (`container_cpu_usage_seconds_total`) for the CNPG and core pods.

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
