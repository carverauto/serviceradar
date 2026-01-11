# Design: Observability Timescale rollups

## Goals
- Make Observability KPI queries fast and stable by querying pre-aggregated rollups instead of raw hypertables.
- Align KPI semantics with the legacy UI where possible:
  - Metrics: total, errors, slow, avg duration, p95 duration
  - Traces: total traces, errors, avg duration, p95 duration
  - Logs: counts by severity (error/warn/info/debug)

## Data Sources
From `pkg/db/cnpg/migrations/00000000000001_schema.up.sql`:
- `logs` hypertable:
  - `timestamp`, `severity_text`, `service_name`, `trace_id`, `span_id`, ...
- `otel_metrics` hypertable:
  - `timestamp`, `duration_ms`, `http_status_code` (TEXT), `grpc_status_code` (TEXT), `is_slow` (BOOLEAN), `level` (TEXT), ...
- `otel_traces` hypertable:
  - `timestamp`, `trace_id`, `span_id`, `parent_span_id`, `status_code` (INTEGER), `start_time_unix_nano`, `end_time_unix_nano`, ...

## KPI Semantics

### Metrics KPIs (from `otel_metrics`)
- **Total metrics**: `count(*)`
- **Errors**: count where any of these are true:
  - `level` indicates error (case-insensitive match for `error`)
  - `http_status_code` is one of the legacy “error” codes (commonly `400, 404, 500, 503`)
  - `grpc_status_code` indicates non-success (implementation should confirm actual encoded values in data)
- **Slow spans**: `count(*) FILTER (WHERE is_slow)`
- **Avg duration**: `avg(duration_ms)`
- **P95 duration**: Prefer `percentile_cont(0.95) WITHIN GROUP (ORDER BY duration_ms)` per bucket. If this proves too expensive, evaluate `timescaledb_toolkit` (tdigest/approx percentiles) as an extension in a follow-up.

### Traces KPIs (from `otel_traces`)
The raw `otel_traces` hypertable stores spans. For “trace count” KPIs we need a trace-like 1-row-per-trace representation.

**Proposed definition:** treat “root spans” as trace representatives:
- A “root span” is a span with `parent_span_id IS NULL` (or empty string; validate ingestion behavior).
- Assumption: there is exactly one root span per trace. This yields a trace-like count via `count(*)` over root spans.

Traces KPIs per bucket:
- **Total traces**: `count(*)` over root spans
- **Errors**: count of root spans where `status_code = 2` (OTel status error)
- **Avg duration (ms)**: `avg((end_time_unix_nano - start_time_unix_nano) / 1e6)`
- **P95 duration (ms)**: `percentile_cont(0.95)` over the computed duration

If the “single root span” assumption does not hold in practice, a follow-up design should introduce a trace summary hypertable keyed by `(trace_id)` and time-bucket rollups on top of it.

### Log KPIs (from `logs`)
- Roll up by normalized level:
  - Normalize `severity_text` to lowercase, and map common variants (`warn`/`warning`) to `warn`.
- Counts per bucket and level: `count(*) FILTER (WHERE normalized_level = 'error')`, etc.

## Rollup Grain & Policies
- Bucket size: **5 minutes** (matches other ServiceRadar telemetry rollups).
- Refresh policy: run every 5 minutes with an end offset to avoid late-arriving data (exact offsets to be tuned during implementation).
- Retention: unchanged for base hypertables; rollup retention may match the base retention window (commonly 3 days) when enabled.

## Compatibility & Resilience
- Continuous aggregates can break after TimescaleDB extension OID changes; migrations should favor:
  - Idempotent creation
  - Explicit policy definitions
  - An operator runbook for recreating rollups if refresh jobs fail
- This change should be compatible with (and not conflict with) the existing CAGG recovery work tracked in `fix-cnpg-continuous-aggregate-cache-error`.

