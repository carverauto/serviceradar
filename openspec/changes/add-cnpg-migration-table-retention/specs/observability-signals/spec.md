## ADDED Requirements

### Requirement: Migration-only CNPG hypertables have reconciled retention

`DataRetentionWorker` SHALL reconcile the TimescaleDB retention policy of `adhoc_scan_results`, `service_status`, `events`, `endpoint_inventory_scan_history`, `endpoint_inventory_package_events`, `endpoint_inventory_package_count_history`, `endpoint_inventory_cpe_count_history`, `spans_red_1h`, `traces_stats_5m`, and `otel_metrics_hourly_stats` on every run, using operator-configured values whose defaults equal the retention intervals the migrations install today (30, 14, 14, 395, 395, 395, 395, 90, 14, and 90 days respectively).

Reconciliation covers retention only: chunk intervals and compression policies for these tables remain migration-owned and the worker SHALL NOT alter them. The values SHALL be set through `core.observabilityRetention` (`adhocScanResultsDays`, `serviceStatusDays` covering `service_status` and `events`, `endpointInventoryHistoryDays` covering `endpoint_inventory_scan_history`, `endpoint_inventory_package_events`, `endpoint_inventory_package_count_history`, and `endpoint_inventory_cpe_count_history`, `spansRedDays`, `tracesStatsDays`, `otelMetricsHourlyStatsDays`) and read identically by the `serviceradar_core` and `serviceradar_core_elx` release runtime configs. The `defaultDays` ceiling SHALL apply to every new key except `endpointInventoryHistoryDays` and `tracesStatsDays`. `endpointInventoryHistoryDays` keeps its own horizon like capacity forecasts. `tracesStatsDays` stays off that ceiling because the cold-tier fence is a second owner of `traces_stats_5m`. The worker's target for `traces_stats_5m` is the explicit `tracesStatsDays` when set, otherwise the 14-day migration default, floored at the clamped refresh window. A failed read of the installed `drop_after` SHALL skip the write. While the cold tier is enabled, the worker SHALL NOT write a target shorter than `RetentionFence.cagg_cold_window_days/1` for `traces_stats_5m`, whether or not a policy is already installed, so it does not drop chunks the fence will only re-widen the policy over. When no policy is installed and that skip does not apply, the worker SHALL write the target. While the cold tier is disabled, an unset `tracesStatsDays` SHALL leave a window already at or above that fence target unchanged. Otherwise the worker writes the target, so an explicit value may narrow or raise the window, including above the fence target. An installed `drop_after` that already equals that target SHALL stay at that value on a later run, including 14 days and shorter. The fence stays widen-only (cold-tier runbook, Rollup retention widening): an unset `tracesStatsDays` SHALL NOT shrink a widened window, and this requirement SHALL NOT stop the fence from widening a shorter window while the cold tier is enabled. Before that retention is applied, the worker SHALL clamp refresh `start_offset` strictly under the retention about to be applied, through the existing continuous-aggregate refresh specs: `endpoint_inventory_package_counts_hourly` and `endpoint_inventory_cpe_counts_hourly` from the effective `endpointInventoryHistoryDays`; `services_availability_5m` from the effective `serviceStatusDays`, after the `defaultDays` ceiling; and `otel_metrics_hourly_stats` from the shorter of raw otel metrics retention and the effective `otelMetricsHourlyStatsDays`. `end_offset` and `schedule_interval` stay as installed. A continuous aggregate's own retention SHALL then be floored at that already-clamped refresh window, and that floor SHALL NOT keep `drop_after` above the configured value. A table or aggregate that does not exist (for example TimescaleDB absent) SHALL be skipped without failing the run.

#### Scenario: Operator shortens migration-only retention through values

- **GIVEN** `core.observabilityRetention.adhocScanResultsDays` is 7 and `serviceStatusDays` is 7
- **WHEN** `DataRetentionWorker` runs
- **THEN** `timescaledb_information.jobs` shows `drop_after = 7 days` for `adhoc_scan_results`, `service_status`, and `events`
- **AND** a later worker run leaves those policies at 7 days

#### Scenario: Operator shortens endpoint inventory history retention

- **GIVEN** `core.observabilityRetention.endpointInventoryHistoryDays` is 7
- **WHEN** `DataRetentionWorker` runs
- **THEN** `timescaledb_information.jobs` shows `drop_after = 7 days` for `endpoint_inventory_scan_history`, `endpoint_inventory_package_events`, `endpoint_inventory_package_count_history`, and `endpoint_inventory_cpe_count_history`
- **AND** the refresh `start_offset` of `endpoint_inventory_package_counts_hourly` and `endpoint_inventory_cpe_counts_hourly` is strictly under 7 days, clamped before those retentions are applied

#### Scenario: Defaults preserve migration values

- **GIVEN** none of the new values are set and `traces_stats_5m` is still on its migration retention interval
- **WHEN** `DataRetentionWorker` runs
- **THEN** retention stays 30 days for `adhoc_scan_results`, 14 days for `service_status`, `events`, and `traces_stats_5m`, 395 days for `endpoint_inventory_scan_history`, `endpoint_inventory_package_events`, `endpoint_inventory_package_count_history`, and `endpoint_inventory_cpe_count_history`, and 90 days for `spans_red_1h` and `otel_metrics_hourly_stats`

#### Scenario: Ceiling skips the endpoint inventory history horizon

- **GIVEN** `core.observabilityRetention.defaultDays` is 7 and `endpointInventoryHistoryDays` is unset
- **WHEN** `DataRetentionWorker` runs
- **THEN** `endpoint_inventory_scan_history`, `endpoint_inventory_package_events`, `endpoint_inventory_package_count_history`, and `endpoint_inventory_cpe_count_history` keep 395-day retention
- **AND** `adhoc_scan_results` is capped at 7 days

#### Scenario: Ceiling and unset traces stats leave a widened window

- **GIVEN** `traces_stats_5m` retention is 90 days because the cold-tier fence widened it, `tracesStatsDays` is unset, and `defaultDays` is 7
- **WHEN** `DataRetentionWorker` runs
- **THEN** `traces_stats_5m` stays at 90 days
- **AND** a later run with the cold tier disabled still leaves it at 90 days

#### Scenario: Explicit traces stats retention narrows a widened window only while the cold tier is disabled

- **GIVEN** `traces_stats_5m` retention is 90 days because the cold-tier fence widened it and `tracesStatsDays` is 30
- **WHEN** `DataRetentionWorker` runs while the cold tier is enabled
- **THEN** `traces_stats_5m` stays at 90 days
- **AND** a run after the cold tier is disabled sets `drop_after` to 30 days
- **AND** a later run with `tracesStatsDays` still 30 and `defaultDays` 7 leaves `drop_after` at 30 days

#### Scenario: An installed explicit traces stats window stays on the next run

- **GIVEN** the cold tier is disabled, `defaultDays` is 7, and `traces_stats_5m` `drop_after` already equals `tracesStatsDays` of 10 or of 14
- **WHEN** `DataRetentionWorker` runs again
- **THEN** `drop_after` stays at that explicit value

#### Scenario: The ceiling does not cap traces stats

- **GIVEN** `traces_stats_5m` is on its 14-day migration interval, `tracesStatsDays` is unset, and `defaultDays` is 7
- **WHEN** `DataRetentionWorker` runs
- **THEN** `traces_stats_5m` stays at 14 days

#### Scenario: The cold tier does not drop traces stats to a shorter target first

- **GIVEN** `traces_stats_5m` retention is 14 days, the cold tier is enabled, `tracesStatsDays` is 30, and `defaultDays` is 7
- **WHEN** `DataRetentionWorker` runs
- **THEN** the worker leaves `traces_stats_5m` at 14 days for the fence to widen

#### Scenario: A missing traces stats policy stays missing while the cold tier is enabled

- **GIVEN** `traces_stats_5m` has no retention policy and the cold tier is enabled
- **WHEN** `DataRetentionWorker` runs with `tracesStatsDays` unset, or set to 30
- **THEN** no `traces_stats_5m` retention policy is installed
- **AND** a run with the cold tier disabled and no policy installs 14 days when `tracesStatsDays` is unset, or the explicit value when it is set

#### Scenario: An explicit traces stats value above the fence target is written

- **GIVEN** the cold tier is disabled, `traces_stats_5m` retention is 90 days, `tracesStatsDays` is 120, and `defaultDays` is 7
- **WHEN** `DataRetentionWorker` runs
- **THEN** `drop_after` is 120 days

#### Scenario: An unset traces stats window below 14 days returns to the migration default

- **GIVEN** `traces_stats_5m` retention is 7 days, `tracesStatsDays` is unset, and `defaultDays` is 7
- **WHEN** `DataRetentionWorker` runs
- **THEN** `traces_stats_5m` `drop_after` is 14 days

#### Scenario: One-day service status retention clamps its availability refresh

- **GIVEN** `core.observabilityRetention.defaultDays` is 1 and `serviceStatusDays` is unset
- **WHEN** `DataRetentionWorker` runs
- **THEN** `service_status` and `events` have `drop_after = 1 day`
- **AND** the `services_availability_5m` refresh `start_offset` is strictly under 1 day, clamped before that retention is applied

#### Scenario: Hourly otel stats retention clamps its own refresh window

- **GIVEN** `otelMetricsHourlyStatsDays` is 7 and raw otel metrics retention is left at 30 days
- **WHEN** `DataRetentionWorker` runs
- **THEN** the `otel_metrics_hourly_stats` refresh `start_offset` is clamped strictly under 7 days before its retention is applied
- **AND** `drop_after` for `otel_metrics_hourly_stats` is 7 days

#### Scenario: Missing TimescaleDB objects are skipped

- **GIVEN** a database without TimescaleDB, or without one of the listed tables
- **WHEN** `DataRetentionWorker` runs
- **THEN** the run completes without error and the remaining tables are still reconciled
