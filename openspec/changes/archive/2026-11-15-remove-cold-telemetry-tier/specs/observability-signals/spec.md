## MODIFIED Requirements

### Requirement: Migration-only CNPG hypertables have reconciled retention

`DataRetentionWorker` SHALL reconcile the TimescaleDB retention policy of `adhoc_scan_results`, `service_status`, `events`, `endpoint_inventory_scan_history`, `endpoint_inventory_package_events`, `endpoint_inventory_package_count_history`, `endpoint_inventory_cpe_count_history`, `spans_red_1h`, `traces_stats_5m`, and `otel_metrics_hourly_stats` on every run, using operator-configured values whose defaults equal the retention intervals the migrations install today (30, 14, 14, 395, 395, 395, 395, 90, 14, and 90 days respectively).

Reconciliation covers retention only: chunk intervals and compression policies for these tables remain migration-owned and the worker SHALL NOT alter them. The values SHALL be set through `core.observabilityRetention` (`adhocScanResultsDays`, `serviceStatusDays` covering `service_status` and `events`, `endpointInventoryHistoryDays` covering `endpoint_inventory_scan_history`, `endpoint_inventory_package_events`, `endpoint_inventory_package_count_history`, and `endpoint_inventory_cpe_count_history`, `spansRedDays`, `tracesStatsDays`, `otelMetricsHourlyStatsDays`) and read identically by the `serviceradar_core` and `serviceradar_core_elx` release runtime configs. The `defaultDays` ceiling SHALL apply to every new key except `endpointInventoryHistoryDays` and `tracesStatsDays`, which keep their own horizons like capacity forecasts. The worker's target for `traces_stats_5m` is the explicit `tracesStatsDays` when set, otherwise the 14-day migration default, floored at the clamped refresh window. The worker SHALL set `traces_stats_5m` to that target whatever window is installed, and SHALL install it when no policy exists. An installed `drop_after` that already equals that target SHALL stay at that value on a later run, including 14 days and shorter. Before that retention is applied, the worker SHALL clamp refresh `start_offset` strictly under the retention about to be applied, through the existing continuous-aggregate refresh specs: `endpoint_inventory_package_counts_hourly` and `endpoint_inventory_cpe_counts_hourly` from the effective `endpointInventoryHistoryDays`; `services_availability_5m` from the effective `serviceStatusDays`, after the `defaultDays` ceiling; and `otel_metrics_hourly_stats` from the shorter of raw otel metrics retention and the effective `otelMetricsHourlyStatsDays`. `end_offset` and `schedule_interval` stay as installed. A continuous aggregate's own retention SHALL then be floored at that already-clamped refresh window, and that floor SHALL NOT keep `drop_after` above the configured value. A table or aggregate that does not exist (for example TimescaleDB absent) SHALL be skipped without failing the run.

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

#### Scenario: The ceiling does not cap traces stats

- **GIVEN** `traces_stats_5m` is on its 14-day migration interval, `tracesStatsDays` is unset, and `defaultDays` is 7
- **WHEN** `DataRetentionWorker` runs
- **THEN** `traces_stats_5m` stays at 14 days

#### Scenario: An explicit traces stats value replaces any installed window

- **GIVEN** `traces_stats_5m` retention is 90 days and `defaultDays` is 7
- **WHEN** `DataRetentionWorker` runs with `tracesStatsDays` set to 30, or to 120
- **THEN** `drop_after` is 30 days, or 120 days
- **AND** a later run with the same `tracesStatsDays` leaves `drop_after` at that value

#### Scenario: An installed explicit traces stats window stays on the next run

- **GIVEN** `defaultDays` is 7 and `traces_stats_5m` `drop_after` already equals `tracesStatsDays` of 10 or of 14
- **WHEN** `DataRetentionWorker` runs again
- **THEN** `drop_after` stays at that explicit value

#### Scenario: An unset traces stats window returns to the migration default

- **GIVEN** `traces_stats_5m` retention is 7 days or 90 days, `tracesStatsDays` is unset, and `defaultDays` is 7
- **WHEN** `DataRetentionWorker` runs
- **THEN** `traces_stats_5m` `drop_after` is 14 days

#### Scenario: A missing traces stats policy is installed

- **GIVEN** `traces_stats_5m` has no retention policy
- **WHEN** `DataRetentionWorker` runs
- **THEN** `drop_after` is 14 days when `tracesStatsDays` is unset, or the explicit value when it is set

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

## ADDED Requirements

### Requirement: Continuous-aggregate refresh hazards are reported on every deployment

`DataRetentionWorker` SHALL, on every run and on every deployment, report each continuous aggregate in the `platform` schema whose refresh policy `start_offset` reaches at or past its source hypertable's retention, because a refresh that covers a dropped-chunk region recomputes those buckets from absent raw rows and deletes materialized history. The source retention SHALL be the source's in-database retention policy when one exists, and otherwise the window the worker itself drops that raw telemetry hypertable's chunks by. A source with neither SHALL NOT be reported. The report SHALL be an error log naming each aggregate, its source, its refresh start and the source retention, and it SHALL NOT change any policy. A catalog that cannot be read SHALL produce no report rather than fail the run.

#### Scenario: A refresh window reaching the source retention is reported

- **GIVEN** a continuous aggregate whose refresh `start_offset` is 30 days over a source with a 30-day retention policy
- **WHEN** `DataRetentionWorker` runs
- **THEN** an error log names that aggregate, its source, `30 days` refresh start and `30 days` source retention
- **AND** neither policy is changed

#### Scenario: Clamped shipped aggregates are not reported

- **GIVEN** the worker has clamped every shipped refresh window strictly inside its source retention
- **WHEN** the hazard check runs
- **THEN** no aggregate is reported

#### Scenario: A worker-dropped source without a policy is compared with its configured window

- **GIVEN** a raw telemetry hypertable with no in-database retention policy, a configured worker retention of 3 days, and an aggregate over it that refreshes from 5 days back
- **WHEN** `DataRetentionWorker` runs
- **THEN** the aggregate is reported with the configured 3-day window as its source retention
