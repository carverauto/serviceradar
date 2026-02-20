## Context

SRQL supports `stats:` and `bucket:` aggregations but always queries raw hypertables. For short windows (last_15m, last_1h) this is fine — raw data is fresh and the scan is small. For long windows (last_7d, last_30d, last_1y) the scan becomes expensive and slow. TimescaleDB Continuous Aggregates pre-compute aggregations in materialized views with automatic refresh, making long-range queries orders of magnitude faster.

We already have CAGGs for logs (`logs_severity_stats_5m`) and OCSF flows (`ocsf_network_activity_*`) but nothing for sysmon metrics or generic timeseries_metrics. The routing to CAGGs is also manual (requires `rollup_stats:` keyword) instead of automatic based on time window.

## Goals / Non-Goals

- **Goals:**
  - Create hourly CAGGs for cpu_metrics, memory_metrics, disk_metrics, process_metrics, timeseries_metrics
  - Automatic transparent routing: SRQL chooses raw vs CAGG based on time window duration
  - Allow long-range queries (>90 days) when targeting CAGGs
  - Maintain exact same response shape — callers should not know which backend was used

- **Non-Goals:**
  - Changing the existing `rollup_stats:` pattern (it stays as-is for specialized KPI queries)
  - Adding 5-minute CAGGs (hourly granularity is sufficient for the auto-routing use case)
  - Real-time CAGG refresh (TimescaleDB refresh policies with ~10 minute lag are acceptable)
  - Routing non-aggregate queries (plain `in:cpu_metrics time:last_7d` without stats/bucket still hits raw)

## Decisions

### CAGG granularity: 1 hour

Hourly buckets strike the right balance:
- Small enough for useful dashboard resolution over days/weeks
- Large enough to dramatically reduce row counts (3600:1 compression for 1s metrics)
- Matches existing `ocsf_events_hourly_stats` pattern
- Alternative considered: 5-minute buckets — rejected because storage savings are smaller and we already have 5m CAGGs for logs/flows where sub-hour resolution matters more

### Routing threshold: 6 hours

Queries spanning ≥6 hours route to the CAGG; shorter queries hit raw data. Rationale:
- An hourly CAGG returns ≤6 points for a 6h window — still usable resolution
- Under 6h, raw data provides better granularity and the scan is manageable
- The threshold is a constant in the Rust code, easy to tune later
- Alternative considered: per-entity thresholds — rejected for simplicity

### Routing applies to `stats:` and `bucket:` queries only

Plain queries (no aggregation) always hit raw data regardless of time window, because users expect individual rows, not pre-aggregated summaries.

### CAGG column design

Each CAGG includes:
- `bucket TIMESTAMPTZ` — time_bucket output
- Dimension columns matching the entity's natural grouping (device_id, host_id, metric_name, etc.)
- `avg_<field>`, `max_<field>`, `min_<field>` — pre-computed aggregations
- `sample_count BIGINT` — row count per bucket (enables weighted averages across buckets)

### Refresh strategy

Use TimescaleDB's built-in `add_continuous_aggregate_policy()`:
- `start_offset = INTERVAL '32 days'`
- `end_offset = INTERVAL '10 minutes'`
- `schedule_interval = INTERVAL '10 minutes'`

This matches the existing OCSF flow CAGG pattern. No custom Oban worker needed — the built-in policy handles it. The 10-minute end_offset means the most recent 10 minutes always come from raw data (which is fine since short queries hit raw anyway).

### Retention

- Raw hypertable retention: unchanged (controlled by existing policies)
- CAGG retention: 395 days (slightly over 1 year) via `add_retention_policy()`
- This allows `time:last_1y` to work reliably

## Risks / Trade-offs

- **Slight staleness for CAGG queries** — up to 10 minutes of lag. Acceptable because long-range dashboards don't need real-time precision.
  → Mitigation: Auto-routing only kicks in for ≥6h windows where 10min lag is imperceptible.

- **Storage overhead** — each CAGG adds materialized view storage. Hourly granularity keeps this small (~1 row per device per hour).
  → Mitigation: Retention policies bound CAGG size to ~1 year.

- **Migration complexity** — creating CAGGs on tables with existing data can be slow.
  → Mitigation: Use `WITH NO DATA` and let the refresh policy backfill, or `WITH DATA` wrapped in `@disable_ddl_transaction true`.

## Migration Plan

1. Create Ecto migration with `@disable_ddl_transaction true`
2. CREATE MATERIALIZED VIEW ... WITH (timescaledb.continuous) for each CAGG
3. Add refresh policy and retention policy for each
4. Deploy migration (CAGGs backfill in background)
5. Deploy SRQL changes (auto-routing starts working once CAGGs have data)
6. Rollback: DROP MATERIALIZED VIEW CASCADE for each CAGG; SRQL routing falls back to raw tables

## Open Questions

- Should we add a `source:raw` / `source:cagg` SRQL keyword to let users force a specific backend? (Leaning no — keep it transparent.)
- Should the 6-hour threshold be configurable via environment variable? (Leaning no — keep it simple, tune in code.)
