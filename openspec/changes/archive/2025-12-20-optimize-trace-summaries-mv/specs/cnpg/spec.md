# cnpg Specification Delta

## ADDED Requirements

### Requirement: CNPG provides pre-computed trace summaries via materialized view

The CNPG database MUST maintain a materialized view `otel_trace_summaries` that pre-aggregates span data by trace_id, enabling fast trace listing queries without on-the-fly aggregation.

#### Scenario: Materialized view exists after migration

- **GIVEN** the migration `00000000000007_trace_summaries_mv.up.sql` in `pkg/db/cnpg/migrations/`
- **WHEN** the migration runs against a CNPG cluster with existing trace data
- **THEN** `SELECT count(*) FROM otel_trace_summaries;` returns a non-zero count matching the number of unique trace_ids in the last 7 days.

#### Scenario: Materialized view has required columns

- **GIVEN** the `otel_trace_summaries` materialized view exists
- **WHEN** `\d otel_trace_summaries` is run
- **THEN** the view contains columns: `trace_id`, `timestamp`, `root_span_id`, `root_span_name`, `root_service_name`, `root_span_kind`, `start_time_unix_nano`, `end_time_unix_nano`, `duration_ms`, `status_code`, `status_message`, `service_set`, `span_count`, `error_count`.

#### Scenario: Materialized view has unique index for concurrent refresh

- **GIVEN** the `otel_trace_summaries` materialized view exists
- **WHEN** `\di idx_trace_summaries_trace_id` is run
- **THEN** a unique index on `trace_id` is shown, enabling `REFRESH MATERIALIZED VIEW CONCURRENTLY`.

#### Scenario: Materialized view has timestamp index for time-range queries

- **GIVEN** the `otel_trace_summaries` materialized view exists
- **WHEN** `EXPLAIN ANALYZE SELECT * FROM otel_trace_summaries WHERE timestamp > NOW() - INTERVAL '1 hour' ORDER BY timestamp DESC LIMIT 100;` runs
- **THEN** the query plan shows an Index Scan on `idx_trace_summaries_timestamp` instead of a sequential scan.

#### Scenario: Materialized view has service index for filtered queries

- **GIVEN** the `otel_trace_summaries` materialized view exists
- **WHEN** `EXPLAIN ANALYZE SELECT * FROM otel_trace_summaries WHERE root_service_name = 'my-service' ORDER BY timestamp DESC LIMIT 100;` runs
- **THEN** the query plan shows an Index Scan on `idx_trace_summaries_service_timestamp`.

### Requirement: Trace summaries materialized view is refreshed periodically

The CNPG database MUST automatically refresh the `otel_trace_summaries` materialized view at regular intervals using pg_cron, ensuring dashboard queries see recent trace data without manual intervention.

#### Scenario: pg_cron job exists for MV refresh

- **GIVEN** the pg_cron extension is available in the CNPG cluster
- **WHEN** `SELECT * FROM cron.job WHERE command LIKE '%otel_trace_summaries%';` runs
- **THEN** a job is returned with schedule `*/2 * * * *` (every 2 minutes) that executes `REFRESH MATERIALIZED VIEW CONCURRENTLY otel_trace_summaries`.

#### Scenario: MV refresh completes without blocking reads

- **GIVEN** the pg_cron refresh job is running
- **WHEN** a query `SELECT * FROM otel_trace_summaries LIMIT 10;` is executed during refresh
- **THEN** the query returns results without waiting for the refresh to complete.

#### Scenario: MV refresh handles missing pg_cron gracefully

- **GIVEN** a CNPG cluster without the pg_cron extension installed
- **WHEN** the migration runs
- **THEN** the materialized view is created but no cron job is scheduled, and a notice is logged indicating manual refresh is required.
