## MODIFIED Requirements

### Requirement: High-volume append-only hypertables use TimescaleDB compression
The system SHALL enable TimescaleDB compression on `platform.ocsf_network_activity` and `platform.timeseries_metrics`, with a documented `compress_after`, `segmentby`, and `orderby` per table, so a freshly provisioned database receives it whether its schema was built by migration replay or bootstrapped from the schema baseline.

The ingest path for both tables is append-only (`ON CONFLICT DO NOTHING`). Compression SHALL NOT be enabled on update-prone hypertables as part of this requirement.

Policy:

- Schema migration first installs compression. Schema baselines generated before change `fix-baseline-replay-parity` were schema-only dumps that carried no TimescaleDB compression settings or policy jobs, so a database bootstrapped from one records the compression migration as applied without having compression. The current baseline carries compression and retention state. `DataRetentionWorker` SHALL therefore enable `timeseries_metrics` compression with the documented `segmentby` and `orderby` whenever it is off, and SHALL leave a table that already has compression enabled unchanged. It SHALL wait at most 10 seconds for the table lock and retry on its next run rather than hold ingestion behind the lock.
- `compress_after` for `timeseries_metrics` SHALL be operator-configurable through `core.observabilityRetention.timeseriesMetricsCompressAfterHours` (default 2 hours) and SHALL be reconciled by `DataRetentionWorker` on every run. The migration installs 6 days; the first worker run replaces it with the configured lag. The policy SHALL be re-registered only when the lag changed, and its job SHALL run hourly.
- The `timeseries_metrics` chunk interval SHALL be configurable through `core.observabilityRetention.timeseriesMetricsChunkIntervalHours` (default 4 hours), separately from the sysmon raw tables. Compressing a chunk sorts all of it through temp files on the data volume, so a day-long chunk at sweep volume needs tens of GB free and fails on a nearly full disk.
- `compress_after` for `ocsf_network_activity` is 32 days (behind the 31-day continuous aggregate refresh window and within 90-day retention).
- `timeseries_metrics` `segmentby`: `device_id, metric_type, metric_name`; `orderby`: `"timestamp" DESC, gateway_id, series_key`.
- `ocsf_network_activity` `segmentby`: `partition, protocol_num`; `orderby`: `"time" DESC, flow_uid`.

Compressing a raw `timeseries_metrics` chunk inside the hourly rollups' refresh window SHALL NOT prevent those rollups from refreshing over it.

The first compression of already-resident chunks SHALL run via the TimescaleDB background job, not as a blocking migration step.

#### Scenario: Fresh provision receives compression
- **GIVEN** a new database created from the current migrations with TimescaleDB available
- **WHEN** migrations complete
- **THEN** both hypertables report `compression_enabled = true`
- **AND** compression policies of 6 days (`timeseries_metrics`) and 32 days (`ocsf_network_activity`) exist

#### Scenario: Baseline-bootstrapped database receives timeseries_metrics compression
- **GIVEN** a database bootstrapped from a schema baseline generated before change `fix-baseline-replay-parity`, whose `timeseries_metrics` hypertable has compression disabled and no compression policy
- **WHEN** `DataRetentionWorker` runs
- **THEN** `timeseries_metrics` reports `compression_enabled = true` with `segmentby` `device_id, metric_type, metric_name` and `orderby` `"timestamp" DESC, gateway_id, series_key`
- **AND** its compression policy uses the configured lag
- **AND** a second run keeps the existing compression job

#### Scenario: Retention run applies the configured raw metrics lag
- **GIVEN** `timeseries_metrics` has a compression policy whose lag differs from the configured `timeseriesMetricsCompressAfterHours`
- **WHEN** `DataRetentionWorker` runs
- **THEN** the `timeseries_metrics` compression policy uses the configured lag

#### Scenario: Unchanged lag keeps the existing policy job
- **GIVEN** the `timeseries_metrics` compression policy already uses the configured lag
- **WHEN** `DataRetentionWorker` runs
- **THEN** the existing compression job is kept rather than re-registered

#### Scenario: Compression job runs hourly
- **GIVEN** the `timeseries_metrics` compression job runs on a schedule other than hourly
- **WHEN** `DataRetentionWorker` runs
- **THEN** the job is rescheduled to run hourly without being re-registered

#### Scenario: Raw metrics chunk interval is separate from the sysmon tables
- **GIVEN** `timeseriesMetricsChunkIntervalHours` is 4 and the shared raw metrics chunk interval is 24 hours
- **WHEN** `DataRetentionWorker` runs
- **THEN** new `timeseries_metrics` chunks span 4 hours
- **AND** the sysmon raw tables keep 24-hour chunks

#### Scenario: Hourly rollup refreshes over a compressed raw chunk
- **GIVEN** a compressed raw `timeseries_metrics` chunk inside the hourly rollups' refresh window
- **AND** a sample inserted into that chunk after it was compressed
- **WHEN** `timeseries_metrics_hourly` is refreshed over that range
- **THEN** the rollup materializes buckets for every sample, including the late one

#### Scenario: TimescaleDB absent is a no-op
- **GIVEN** a database without the TimescaleDB extension
- **WHEN** the migration runs
- **THEN** it completes without error and does not fail when TimescaleDB is absent

#### Scenario: Existing uncompressed chunks catch up in the background
- **GIVEN** a long-lived deployment whose eligible chunks are uncompressed
- **WHEN** the policy is installed
- **THEN** the TimescaleDB compression job becomes responsible for compressing those chunks
- **AND** the migration itself does not loop `compress_chunk`

#### Scenario: Recent chunks stay uncompressed
- **GIVEN** a chunk whose range ends less than the configured `compress_after` threshold
- **WHEN** the compression job runs
- **THEN** that chunk is not compressed
