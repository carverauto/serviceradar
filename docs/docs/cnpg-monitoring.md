---
title: CNPG Monitoring
---

# CNPG Monitoring and Dashboards

ServiceRadar now stores every telemetry signal (events, OTEL logs/metrics/traces, registry tables) inside the CloudNativePG (CNPG) cluster running TimescaleDB. This guide captures the dashboards and SQL checks operators should wire into Grafana or the toolbox so they can confirm ingestion, retention, and pgx pool health without relying on the retired Proton parity checks.

## Data Source Setup

Add the CNPG reader as a PostgreSQL data source in Grafana (or any SQL-friendly dashboarding tool):

1. **Host / Port**: `cnpg-rw.<namespace>.svc.cluster.local:5432` (the RW service from the demo manifests).
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

## Alert Ideas

| Signal | Query/Metric | Suggested Threshold |
|--------|--------------|---------------------|
| Ingestion Stall | `SELECT COUNT(*) FROM logs WHERE created_at >= now() - INTERVAL '5 minutes'` | `< 1` row triggers paging |
| Retention Lag | `timescaledb_information.job_stats.last_successful_finish` | older than 15 minutes |
| PVC Growth | `hypertable_detailed_size.total_bytes` | >10% growth per hour |
| pgx Errors | `kubectl logs deploy/serviceradar-db-event-writer | grep "cnpg"` | any non-zero error rate should alert |

Reuse your existing Prometheus stack to alert on pod restarts (`kube_pod_container_status_restarts_total`) and container CPU saturation (`container_cpu_usage_seconds_total`) for the CNPG and db-event-writer pods. Use this doc in tandem with the **Timescale Retention & Compression Checks** section in `agents.md` for the CLI-based playbook.
