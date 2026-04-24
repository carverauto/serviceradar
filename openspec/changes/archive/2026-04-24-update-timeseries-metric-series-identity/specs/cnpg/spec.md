## MODIFIED Requirements
### Requirement: Timeseries metrics preserve per-series uniqueness
The system SHALL store `platform.timeseries_metrics` samples with a per-series identity that allows multiple devices, interfaces, or checks to emit the same `metric_name` at the same timestamp through the same gateway without conflicting. The uniqueness contract SHALL use a stable `series_key` together with `timestamp` and `gateway_id`, and SHALL support idempotent replay of the same sample.

#### Scenario: Distinct interface counters coexist in one timestamp bucket
- **GIVEN** an SNMP ingest batch contains two `ifInOctets` samples from different interfaces at the same timestamp and gateway
- **WHEN** the batch is written to `platform.timeseries_metrics`
- **THEN** both rows SHALL be stored as distinct samples
- **AND** the write SHALL NOT fail with an `ON CONFLICT` cardinality violation

#### Scenario: Exact replay remains idempotent
- **GIVEN** a metric sample has already been stored with the same timestamp, gateway, and series identity
- **WHEN** the same sample is replayed
- **THEN** the system SHALL upsert it without creating a duplicate row
