## ADDED Requirements

### Requirement: High-volume append-only hypertables use TimescaleDB compression
The system SHALL enable TimescaleDB compression on `platform.ocsf_network_activity` and `platform.timeseries_metrics`, with a documented `compress_after`, `segmentby`, and `orderby` per table, installed by migration and re-asserted by the observability retention worker so a freshly provisioned database receives the same policy as a long-lived one.

The ingest path for both tables is append-only (`ON CONFLICT DO NOTHING`). Compression SHALL NOT be enabled on update-prone hypertables as part of this requirement.

Default policy:

- `compress_after`: 2 days on both tables (open chunk plus one closed chunk stay uncompressed).
- `timeseries_metrics` `segmentby`: `metric_type, metric_name, device_id`; `orderby`: `timestamp DESC`.
- `ocsf_network_activity` `segmentby`: `partition, protocol_name`; `orderby`: `time DESC`.

The first compression of already-resident chunks SHALL run via the TimescaleDB background job, not as a blocking migration step.

#### Scenario: Fresh provision receives compression
- **GIVEN** a new database created from the current migrations with TimescaleDB available
- **WHEN** migrations complete and the retention worker has run once
- **THEN** both hypertables report `compression_enabled = true`
- **AND** a compression policy of 2 days exists on each

#### Scenario: TimescaleDB absent is a no-op
- **GIVEN** a database without the TimescaleDB extension
- **WHEN** the migration and retention worker run
- **THEN** both complete without error and do not require compression

#### Scenario: Existing uncompressed chunks catch up in the background
- **GIVEN** a long-lived deployment whose eligible chunks are uncompressed
- **WHEN** the policy is installed
- **THEN** the TimescaleDB compression job becomes responsible for compressing those chunks
- **AND** the migration itself does not loop `compress_chunk`

#### Scenario: Recent chunks stay uncompressed
- **GIVEN** a chunk whose range ends less than 2 days ago
- **WHEN** the compression job runs
- **THEN** that chunk is not compressed
