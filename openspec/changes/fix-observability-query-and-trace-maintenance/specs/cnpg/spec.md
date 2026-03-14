## ADDED Requirements
### Requirement: Logs effective timestamp queries are index-backed
The CNPG schema SHALL provide an index-backed execution path for log queries that filter and order on `COALESCE(observed_timestamp, timestamp)` so default observability log views do not require sequential scans across recent hypertable chunks.

#### Scenario: Default logs query uses the effective timestamp index
- **GIVEN** the `platform.logs` hypertable contains production-like recent volume
- **WHEN** an operator runs `EXPLAIN ANALYZE` for `SELECT ... FROM platform.logs WHERE COALESCE(observed_timestamp, timestamp) BETWEEN <start> AND <end> ORDER BY COALESCE(observed_timestamp, timestamp) DESC LIMIT 20`
- **THEN** the plan SHALL use an index-backed path on the effective timestamp expression
- **AND** the plan SHALL NOT rely on a parallel sequential scan across every recent chunk in the requested window

## RENAMED Requirements
- FROM: `### Requirement: CNPG provides pre-computed trace summaries via materialized view`
- TO: `### Requirement: CNPG provides pre-computed trace summaries via maintained table`

- FROM: `### Requirement: Trace summaries materialized view is refreshed periodically`
- TO: `### Requirement: Trace summaries table maintenance remains fresh and recoverable`

## MODIFIED Requirements
### Requirement: CNPG provides pre-computed trace summaries via maintained table
The CNPG database SHALL maintain a regular table `platform.otel_trace_summaries` that stores one incrementally refreshed row per trace for the supported trace summary retention window, enabling fast trace listing queries without on-the-fly aggregation.

#### Scenario: Trace summary table exists with the required shape
- **GIVEN** the observability schema migrations have been applied
- **WHEN** an operator inspects `platform.otel_trace_summaries`
- **THEN** the table SHALL contain columns `trace_id`, `timestamp`, `root_span_id`, `root_span_name`, `root_service_name`, `root_span_kind`, `start_time_unix_nano`, `end_time_unix_nano`, `duration_ms`, `status_code`, `status_message`, `service_set`, `span_count`, `error_count`, and `refreshed_at`

#### Scenario: Trace summary table enforces one row per trace
- **GIVEN** `platform.otel_trace_summaries` exists
- **WHEN** an operator inspects its indexes and constraints
- **THEN** `trace_id` SHALL be unique
- **AND** the table SHALL have indexes that support `ORDER BY timestamp DESC` and `WHERE root_service_name = ... ORDER BY timestamp DESC`

#### Scenario: Trace summaries older than the supported window are pruned
- **GIVEN** trace summary rows older than the supported summary retention window exist
- **WHEN** trace summary maintenance runs
- **THEN** rows older than that window SHALL be removed from `platform.otel_trace_summaries`

### Requirement: Trace summaries table maintenance remains fresh and recoverable
The system SHALL maintain `platform.otel_trace_summaries` through incremental background refresh and cleanup, and the maintenance path SHALL recover after database restarts, node restarts, or orphaned worker state.

#### Scenario: Incremental maintenance refreshes recent traces
- **GIVEN** new spans arrive in `platform.otel_traces`
- **WHEN** the trace summary maintenance job runs
- **THEN** it SHALL upsert refreshed summary rows for affected trace ids into `platform.otel_trace_summaries`

#### Scenario: Orphaned worker state does not leave stale summaries indefinitely
- **GIVEN** a prior trace summary maintenance run was interrupted and left scheduler state behind
- **WHEN** the scheduler resumes in a healthy deployment
- **THEN** a later maintenance run SHALL still be enqueued and executed
- **AND** operators SHALL not need to delete stale `executing` rows manually just to restore steady-state scheduling

### Requirement: Traces summary continuous aggregate
The system SHALL create a TimescaleDB continuous aggregate `platform.traces_stats_5m` with 5-minute buckets that pre-computes trace statistics from root spans in the `platform.otel_traces` hypertable for SRQL traces summary rollups.

#### Scenario: CAGG exists after migration
- **GIVEN** the observability rollup migrations have been applied
- **WHEN** an operator queries `timescaledb_information.continuous_aggregates`
- **THEN** a continuous aggregate named `traces_stats_5m` SHALL exist in `platform`

#### Scenario: CAGG filters to root spans only
- **GIVEN** traces with multiple spans per trace
- **WHEN** the CAGG aggregates the data
- **THEN** only spans with `parent_span_id IS NULL` or empty SHALL contribute to `total_count`

#### Scenario: CAGG has a refresh policy
- **GIVEN** `platform.traces_stats_5m` exists
- **WHEN** an operator queries `timescaledb_information.jobs`
- **THEN** the CAGG SHALL have a refresh policy that runs on a recurring schedule suitable for the traces summary cards
