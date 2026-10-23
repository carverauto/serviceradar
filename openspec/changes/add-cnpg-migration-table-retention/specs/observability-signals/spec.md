## ADDED Requirements

### Requirement: Migration-only CNPG hypertables have reconciled retention

`DataRetentionWorker` SHALL reconcile the TimescaleDB retention policy of `adhoc_scan_results`, `service_status`, `events`, `endpoint_inventory_scan_history`, `endpoint_inventory_package_events`, `spans_red_1h`, `traces_stats_5m`, and `otel_metrics_hourly_stats` on every run, using operator-configured values whose defaults equal the retention intervals the migrations install today (30, 14, 14, 395, 395, 90, 14, and 90 days respectively).

Reconciliation covers retention only: chunk intervals and compression policies for these tables remain migration-owned and the worker SHALL NOT alter them. The values SHALL be set through `core.observabilityRetention` (`adhocScanResultsDays`, `serviceStatusDays` covering `service_status` and `events`, `endpointInventoryHistoryDays` covering both endpoint inventory history tables, `spansRedDays`, `tracesStatsDays`, `otelMetricsHourlyStatsDays`) and read identically by the `serviceradar_core` and `serviceradar_core_elx` release runtime configs. The `defaultDays` ceiling SHALL apply to every new key except `endpointInventoryHistoryDays`, which keeps its own horizon like capacity forecasts. A continuous aggregate's retention SHALL be floored at its refresh window, and refresh-window clamping SHALL run before retention is applied. A table or aggregate that does not exist (for example TimescaleDB absent) SHALL be skipped without failing the run.

#### Scenario: Operator shortens migration-only retention through values

- **GIVEN** `core.observabilityRetention.adhocScanResultsDays` is 7 and `serviceStatusDays` is 7
- **WHEN** `DataRetentionWorker` runs
- **THEN** `timescaledb_information.jobs` shows `drop_after = 7 days` for `adhoc_scan_results`, `service_status`, and `events`
- **AND** a later worker run leaves those policies at 7 days

#### Scenario: Defaults preserve migration values

- **GIVEN** none of the new values are set
- **WHEN** `DataRetentionWorker` runs
- **THEN** retention stays 30 days for `adhoc_scan_results`, 14 days for `service_status`, `events`, and `traces_stats_5m`, 395 days for both endpoint inventory history tables, and 90 days for `spans_red_1h` and `otel_metrics_hourly_stats`

#### Scenario: Ceiling skips the endpoint inventory history horizon

- **GIVEN** `core.observabilityRetention.defaultDays` is 7 and `endpointInventoryHistoryDays` is unset
- **WHEN** `DataRetentionWorker` runs
- **THEN** the endpoint inventory history tables keep 395-day retention
- **AND** `adhoc_scan_results` is capped at 7 days

#### Scenario: CAGG retention cannot undercut its refresh window

- **GIVEN** `tracesStatsDays` is set below the `traces_stats_5m` refresh window
- **WHEN** `DataRetentionWorker` runs
- **THEN** the refresh window is clamped first
- **AND** the applied retention is no shorter than the clamped refresh window

#### Scenario: Missing TimescaleDB objects are skipped

- **GIVEN** a database without TimescaleDB, or without one of the listed tables
- **WHEN** `DataRetentionWorker` runs
- **THEN** the run completes without error and the remaining tables are still reconciled
