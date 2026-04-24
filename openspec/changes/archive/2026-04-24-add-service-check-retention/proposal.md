# Change: Add TimescaleDB retention policies for observability hypertables

## Why
The observability hypertables accumulate time-series data indefinitely, consuming storage and slowing down historical queries. Currently only `discovered_interfaces` has a retention policy (3 days). The remaining 12 hypertables grow unbounded:

| Hypertable | Data Type | Retention Needed |
|------------|-----------|------------------|
| `events` | CloudEvents activity log | Yes - operational logs |
| `logs` | OpenTelemetry logs | Yes - observability data |
| `service_status` | Service check results | Yes - monitoring data |
| `otel_traces` | OpenTelemetry traces | Yes - APM data |
| `otel_metrics` | Trace-derived metrics | Yes - APM data |
| `timeseries_metrics` | Generic time-series | Yes - telemetry |
| `cpu_metrics` | CPU utilization | Yes - telemetry |
| `disk_metrics` | Disk utilization | Yes - telemetry |
| `memory_metrics` | Memory utilization | Yes - telemetry |
| `process_metrics` | Process stats | Yes - telemetry |
| `device_updates` | Device history log | Yes - audit log |
| `otel_metrics_hourly_stats` | Pre-computed rollups | Longer - aggregated data |

The project already uses TimescaleDB's `add_retention_policy()` for `discovered_interfaces`. Applying consistent retention policies ensures bounded storage growth and predictable query performance.

## What Changes
- Add a migration that attaches TimescaleDB retention policies to all observability hypertables.
- Use tiered retention intervals based on data type:
  - **7 days**: High-volume telemetry (`cpu_metrics`, `disk_metrics`, `memory_metrics`, `process_metrics`, `timeseries_metrics`)
  - **14 days**: Monitoring data (`service_status`, `events`)
  - **30 days**: APM data (`otel_traces`, `otel_metrics`, `logs`)
  - **90 days**: Aggregated data (`otel_metrics_hourly_stats`)
  - **30 days**: Audit data (`device_updates`)
- Follow the existing idempotent pattern from `20260120021558_ensure_discovered_interfaces_hypertable.exs`.
- Update the CNPG spec to document retention policy requirements.

## Scope Decisions
- **In scope**: All time-series hypertables without retention policies
- **Out of scope**: `service_state` table (current-state registry, not time-series)
- **Out of scope**: `service_checks` table (configuration data, not time-series)
- **Out of scope**: `discovered_interfaces` (already has 3-day retention)

## Impact
- Affected specs: `cnpg`
- Affected code: Ecto migration in `elixir/serviceradar_core/priv/repo/migrations/`
- Storage: Automatic pruning of observability data older than retention periods
- Queries: Faster queries on bounded datasets
