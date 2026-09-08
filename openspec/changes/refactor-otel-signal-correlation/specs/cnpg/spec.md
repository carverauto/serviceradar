## RENAMED Requirements

- FROM: `### Requirement: CNPG provides pre-computed trace summaries via materialized view`
- TO: `### Requirement: CNPG provides pre-computed trace summaries via maintained table`

- FROM: `### Requirement: Trace summaries materialized view is refreshed periodically`
- TO: `### Requirement: Trace summaries table is maintained incrementally`

## MODIFIED Requirements

### Requirement: CNPG provides pre-computed trace summaries via maintained table

The CNPG database MUST maintain a plain table `otel_trace_summaries` (one row
per `trace_id`) that pre-aggregates span data, enabling fast trace listing
without on-the-fly aggregation. Root-span attribution MUST use
`parent_span_id IS NULL`; `error_count` MUST count spans with
`status_code = 2` (OTLP STATUS_ERROR) only. Summary retention MUST NOT exceed
raw span retention by more than an explicitly configured window, and the UI
contract for traces older than raw retention is the trace detail "spans no
longer retained" notice, not an empty page.

#### Scenario: Table exists with required columns

- **GIVEN** the trace summaries migrations have run
- **WHEN** `\d otel_trace_summaries` is run
- **THEN** the table contains columns: `trace_id` (primary key), `timestamp`,
  `root_span_id`, `root_span_name`, `root_service_name`, `root_span_kind`,
  `start_time_unix_nano`, `end_time_unix_nano`, `duration_ms`, `status_code`,
  `status_message`, `service_set`, `span_count`, `error_count`, `refreshed_at`

#### Scenario: Error counting uses OTLP error status only

- **GIVEN** spans with status_code values 0 (UNSET), 1 (OK), and 2 (ERROR)
- **WHEN** summaries are computed
- **THEN** `error_count` SHALL equal the number of status_code=2 spans
- **AND** previously-written summary rows computed under older semantics SHALL
  be recomputed or expired by retention

#### Scenario: Root attribution matches NULL parents

- **GIVEN** spans whose `parent_span_id` is NULL for roots
- **WHEN** summaries are computed
- **THEN** `root_*` columns SHALL be populated from the `parent_span_id IS NULL`
  span of each trace

#### Scenario: Time-range and service queries are index-backed

- **WHEN** `EXPLAIN ANALYZE` runs a `timestamp` range query or
  `root_service_name` filtered query ordered by `timestamp DESC`
- **THEN** the plan uses index scans, not sequential scans

### Requirement: Trace summaries table is maintained incrementally

The system MUST incrementally upsert `otel_trace_summaries` from new span rows
using an INGEST-TIME watermark (`created_at`-based), so spans that arrive late
relative to their event time are still summarized; maintenance MUST use Oban
peer leader election so multi-node deployments do not enqueue duplicate jobs;
and summary pruning MUST drain to the retention target rather than deleting a
single fixed-size batch per run.

#### Scenario: Late-arriving spans are summarized

- **GIVEN** a span whose event `timestamp` is 30 minutes old arrives now
- **WHEN** the next summary maintenance run executes
- **THEN** the span's trace summary SHALL be created or updated

#### Scenario: Worker downtime does not lose traces

- **GIVEN** the maintenance worker was down for 1 hour
- **WHEN** it resumes
- **THEN** it SHALL process the entire backlog from its last ingest-time
  watermark, not only the most recent fixed lookback window

#### Scenario: Pruning keeps up with write pressure

- **GIVEN** summary rows older than retention exceed one delete batch
- **WHEN** the cleanup job runs
- **THEN** it SHALL iterate batches until the retention target is met or a
  bounded time budget expires, and report remaining backlog

#### Scenario: Multi-node cron scheduling does not duplicate refresh jobs

- **GIVEN** web-ng and core nodes are running against the same CNPG cluster
- **WHEN** the Oban cron leader schedules maintenance jobs for 5 minutes
- **THEN** the number of jobs recorded in `oban_jobs` matches the expected
  cadence without duplicates

## ADDED Requirements

### Requirement: OTel identifier storage constraints

OTel tables MUST enforce the canonical identifier contract at the schema
level: new ingest paths write `trace_id` as 32-char lowercase hex, `span_id`
and `parent_span_id` as 16-char lowercase hex or NULL, validated by CHECK
constraints (created NOT VALID and validated after backfill); and a one-time
backfill MUST rewrite legacy `logs` rows whose `trace_id`/`span_id` are
double-hex-encoded (64/32 chars) back to canonical form.

#### Scenario: Double-hex legacy rows are backfilled

- **GIVEN** `logs` rows with 64-character `trace_id` values that decode to
  32-character hex strings
- **WHEN** the backfill migration runs
- **THEN** those rows SHALL hold the decoded 32-character lowercase hex value
- **AND** a `trace_id` equality join between `logs` and `otel_traces` SHALL
  match for spans whose logs were ingested before the fix

#### Scenario: Non-canonical insert is rejected

- **GIVEN** the validated CHECK constraints are in place
- **WHEN** a writer attempts to insert a 64-character `trace_id` into `logs`
- **THEN** the insert SHALL fail rather than silently storing an unjoinable id

### Requirement: OTel retention and chunk alignment

Retention MUST be explicitly configured for `otel_traces`,
`otel_trace_summaries`, `otel_metrics`, and `logs`, mutually consistent
(documented relative ordering), and operationally effective: hypertable chunk
intervals MUST be sized so the retention policy actually drops chunks within
one policy period, and retention job failures MUST surface as
operator-visible health signals.

#### Scenario: Retention actually fires

- **GIVEN** `otel_traces` retention of 1 day and a 1-hour chunk interval
- **WHEN** the retention job runs
- **THEN** chunks older than the cutoff SHALL be dropped within one scheduling
  period

#### Scenario: Misaligned retention is detectable

- **GIVEN** `logs` holds rows older than its configured retention
- **WHEN** the observability health check runs
- **THEN** a warning SHALL identify the table whose retention is not being
  enforced

### Requirement: Span RED rollups derive from the full span stream

Span RED rollups (request counts, error counts, duration percentiles) MUST be
derived from the complete span stream (`otel_traces`), not from the slow-span
sample table, so totals, error rates, and percentiles are unbiased. Slow-span
samples remain available as exemplars linked by `trace_id`/`span_id`.

#### Scenario: Percentiles reflect all spans

- **GIVEN** spans with p95 duration of ~13ms across the full stream
- **WHEN** the RED rollup for the window is queried
- **THEN** the reported p95 SHALL reflect the full stream (~13ms), not the
  slow-sample-only distribution

### Requirement: OTLP metric points are stored with metric identity

OTLP sum/gauge/histogram data points MUST be stored in a dedicated structure
keyed by metric name, type, unit, and attributes hash (hypertable with
retention), distinct from span-derived samples, sufficient to render counters
as rates and histograms with buckets.

#### Scenario: Counter point round-trips with identity

- **WHEN** an OTLP sum data point for `falcosecurity_falcosidekick_outputs` is
  ingested
- **THEN** its stored row SHALL include metric name, type `sum`,
  monotonicity/temporality, unit, value, and attributes
- **AND** the metrics pane SHALL be able to compute a rate over consecutive
  points
