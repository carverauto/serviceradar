## 1. Worker

- [ ] 1.1 Add a retention-only reconciliation list to `DataRetentionWorker` for `adhoc_scan_results`, `service_status`, `events`, `endpoint_inventory_scan_history`, `endpoint_inventory_package_events`, `endpoint_inventory_package_count_history`, `endpoint_inventory_cpe_count_history` (no chunk-interval or compression changes)
- [ ] 1.2 Reconcile CAGG retention for `spans_red_1h`, `traces_stats_5m`, `otel_metrics_hourly_stats` after refresh-window clamping, floored at the refresh window
- [ ] 1.3 Join the new keys to the `defaultDays` ceiling set, excluding `endpointInventoryHistoryDays`

## 2. Release config and chart

- [ ] 2.1 Read the six new env vars identically in `serviceradar_core/config/runtime.exs` and `serviceradar_core_elx/config/runtime.exs`
- [ ] 2.2 Add `core.observabilityRetention` values (`adhocScanResultsDays`, `serviceStatusDays`, `endpointInventoryHistoryDays`, `spansRedDays`, `tracesStatsDays`, `otelMetricsHourlyStatsDays`) with comments, rendered on the core Deployment
- [ ] 2.3 Document every key, its default, and the CAGG constraint in the chart README

## 3. Tests

- [ ] 3.1 Extend `helm/serviceradar/tests/cnpg_telemetry_retention_env_test.yaml` and `data_retention_runtime_config_test.exs` so every rendered env var is read by both runtime configs and both worker config blocks keep identical key sets
- [ ] 3.2 Add a guarded DB test proving a synthetic configured value lands as `drop_after` on a migration-only table and survives a second run (fail-before: no reconciliation before this change)
