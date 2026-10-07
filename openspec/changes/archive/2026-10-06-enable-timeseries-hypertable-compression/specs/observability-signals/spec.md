## ADDED Requirements

### Requirement: High-volume append-only hypertables use TimescaleDB compression
The system SHALL enable TimescaleDB compression on `platform.ocsf_network_activity` and `platform.timeseries_metrics`, with a documented `compress_after`, `segmentby`, and `orderby` per table installed by schema migration so a freshly provisioned database receives the policy from migrations.

The ingest path for both tables is append-only (`ON CONFLICT DO NOTHING`). Compression SHALL NOT be enabled on update-prone hypertables as part of this requirement.

Policy:

- `compress_after`: 6 days for `timeseries_metrics` (behind the 5-day continuous aggregate refresh window and within 7-day retention) and 32 days for `ocsf_network_activity` (behind the 31-day continuous aggregate refresh window and within 90-day retention).
- `timeseries_metrics` `segmentby`: `device_id, metric_type, metric_name`; `orderby`: `"timestamp" DESC, gateway_id, series_key`.
- `ocsf_network_activity` `segmentby`: `partition, protocol_num`; `orderby`: `"time" DESC, flow_uid`.

The first compression of already-resident chunks SHALL run via the TimescaleDB background job, not as a blocking migration step.

#### Scenario: Fresh provision receives compression
- **GIVEN** a new database created from the current migrations with TimescaleDB available
- **WHEN** migrations complete
- **THEN** both hypertables report `compression_enabled = true`
- **AND** compression policies of 6 days (`timeseries_metrics`) and 32 days (`ocsf_network_activity`) exist

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
