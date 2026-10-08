## MODIFIED Requirements

### Requirement: High-volume append-only hypertables use TimescaleDB compression
The system SHALL enable TimescaleDB compression on `platform.ocsf_network_activity` and `platform.timeseries_metrics`, with a documented `compress_after`, `segmentby`, and `orderby` per table installed by schema migration so a freshly provisioned database receives the policy from migrations.

The ingest path for both tables is append-only (`ON CONFLICT DO NOTHING`). Compression SHALL NOT be enabled on update-prone hypertables as part of this requirement.

Policy:

- `compress_after` for `timeseries_metrics` SHALL be operator-configurable through `core.observabilityRetention.timeseriesMetricsCompressAfterHours` (default 24 hours) and SHALL be reconciled by `DataRetentionWorker` on every run. The migration installs 6 days; the first worker run replaces it with the configured lag. The policy SHALL be re-registered only when the lag changed.
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

#### Scenario: Retention run applies the configured raw metrics lag
- **GIVEN** `timeseries_metrics` has a compression policy whose lag differs from the configured `timeseriesMetricsCompressAfterHours`
- **WHEN** `DataRetentionWorker` runs
- **THEN** the `timeseries_metrics` compression policy uses the configured lag

#### Scenario: Unchanged lag keeps the existing policy job
- **GIVEN** the `timeseries_metrics` compression policy already uses the configured lag
- **WHEN** `DataRetentionWorker` runs
- **THEN** the existing compression job is kept rather than re-registered

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
