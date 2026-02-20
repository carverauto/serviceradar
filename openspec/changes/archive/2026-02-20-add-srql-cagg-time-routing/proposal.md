# Change: Add automatic SRQL time-based CAGG routing and missing metric CAGGs

## Why

SRQL currently queries raw hypertables for all metric entities regardless of the time window requested. A query like `in:cpu_metrics time:last_1y stats:avg(usage)` hits the raw table (and is actually rejected — max range is 90 days). TimescaleDB Continuous Aggregates (CAGGs) exist for logs and OCSF flows but are missing entirely for sysmon metrics (CPU, memory, disk, process) and timeseries_metrics. There is no routing logic that transparently directs queries to CAGGs when the time window is large enough. This forces dashboards to either scan massive raw tables or avoid long-range queries altogether.

## What Changes

1. **Create missing CAGGs** for every sysmon metric entity and timeseries_metrics:
   - `cpu_metrics_hourly` — AVG/MAX(usage_percent) bucketed hourly
   - `memory_metrics_hourly` — AVG/MAX(usage_percent), AVG(used_bytes, available_bytes) bucketed hourly
   - `disk_metrics_hourly` — AVG/MAX(usage_percent), AVG(used_bytes, available_bytes) bucketed hourly
   - `process_metrics_hourly` — AVG/MAX(cpu_usage, memory_usage) bucketed hourly
   - `timeseries_metrics_hourly` — AVG/MIN/MAX(value) bucketed hourly, grouped by metric_name + device_id

2. **Add automatic time-based routing in SRQL**: When a `stats:` or `bucket:` query spans longer than a configurable threshold (default: 6 hours), SRQL transparently queries the hourly CAGG instead of the raw hypertable. Queries under the threshold continue hitting raw data.

3. **Lift the 90-day max time range cap** for queries that route to CAGGs, allowing `time:last_1y` and similar long-range queries against pre-aggregated data.

4. **Create Ash resources** (`migrate?: false`, read-only) for each new CAGG so the Elixir layer can reference them if needed.

5. **Add Oban refresh workers** (or TimescaleDB refresh policies) for each new CAGG.

## Impact

- Affected specs: `srql`
- Affected code:
  - `rust/srql/src/query/cpu_metrics.rs`, `memory_metrics.rs`, `disk_metrics.rs`, `process_metrics.rs`, `timeseries_metrics.rs` — add CAGG routing
  - `rust/srql/src/query/downsample.rs` — route to CAGG for large windows
  - `rust/srql/src/query/mod.rs` — time-window routing decision logic
  - `rust/srql/src/time.rs` — lift 90-day cap when CAGG-eligible
  - `elixir/serviceradar_core/priv/repo/migrations/` — new migration creating CAGGs
  - `elixir/serviceradar_core/lib/serviceradar/` — Ash resources + refresh workers
