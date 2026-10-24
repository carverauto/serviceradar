# Change: Reconcile retention for migration-only CNPG hypertables

## Why

On installs without StarRocks, several CNPG hypertables and continuous aggregates receive a TimescaleDB retention policy only from migrations. There is no Helm value to change them and `DataRetentionWorker` does not reconcile them, so an operator cannot durably cap them: the migration value is the only value. This is proposal 2 of #5556; the core-elx wiring fix and the global ceiling from that issue already landed.

## What Changes

- `DataRetentionWorker` reconciles retention (only retention — chunk intervals and compression stay migration-owned) for:
  - `adhoc_scan_results` (new key, default 30 days)
  - `service_status` and `events` (one key, default 14 days — the migration tier groups them)
  - `endpoint_inventory_scan_history`, `endpoint_inventory_package_events`, `endpoint_inventory_package_count_history`, and `endpoint_inventory_cpe_count_history` (one key, default 395 days)
  - continuous aggregates `spans_red_1h` (90 days), `traces_stats_5m` (14 days), `otel_metrics_hourly_stats` (90 days), each its own key so every default preserves today's migration value
- New `core.observabilityRetention` values: `adhocScanResultsDays`, `serviceStatusDays`, `endpointInventoryHistoryDays`, `spansRedDays`, `tracesStatsDays`, `otelMetricsHourlyStatsDays`, rendered as env on the core Deployment, read identically by both release runtime configs.
- The new keys join the `defaultDays` ceiling set except `endpointInventoryHistoryDays`, which stays on its own horizon like capacity forecasts.
- Before those retentions are applied, the existing continuous-aggregate refresh specs clamp `start_offset` strictly under the retention about to be applied: `endpoint_inventory_package_counts_hourly` and `endpoint_inventory_cpe_counts_hourly` from `endpointInventoryHistoryDays`, `services_availability_5m` from effective `serviceStatusDays` (after the `defaultDays` ceiling), and `otel_metrics_hourly_stats` from the shorter of raw otel metrics retention and `otelMetricsHourlyStatsDays`. Each aggregate's own retention is then floored at that clamped window, so the floor does not hold `drop_after` above the configured value.
- Guard tests extended: every rendered retention env var is read by both runtime configs, and the two `DataRetentionWorker` config blocks keep identical key sets.
- `netflow_metrics` and `flow_traffic_1d` are excluded: both were dropped with the CNPG flow path.
- Defaults equal the current migration values. No install changes retention unless an operator sets a value.

## Impact

- Affected specs: `observability-signals` (one ADDED requirement)
- Affected code: `elixir/serviceradar_core/lib/serviceradar/observability/data_retention_worker.ex`, `elixir/serviceradar_core/config/runtime.exs`, `elixir/serviceradar_core_elx/config/runtime.exs`, `helm/serviceradar/{values.yaml,README.md,templates/core.yaml,tests/cnpg_telemetry_retention_env_test.yaml}`, `elixir/serviceradar_core/test/serviceradar/observability/data_retention_runtime_config_test.exs`
