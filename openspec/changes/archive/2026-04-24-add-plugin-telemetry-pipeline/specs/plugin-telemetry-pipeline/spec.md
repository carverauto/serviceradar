# plugin-telemetry-pipeline Specification

## Purpose
Provide a first-class pipeline for plugin-originated events and logs from edge agents to core‑elx so they are ingested into OCSF events and OTEL-style logs for analytics and UI.

## ADDED Requirements
### Requirement: Plugin telemetry batch transport
The system SHALL transport plugin telemetry (events and logs) from agents to gateways and from gateways to core‑elx using a dedicated telemetry batch payload.

#### Scenario: Agent submits telemetry batch
- **GIVEN** a plugin emits events or logs
- **WHEN** the agent submits a `PluginTelemetryBatch`
- **THEN** the gateway receives the batch separately from plugin results

#### Scenario: Gateway forwards telemetry batch
- **GIVEN** the gateway receives a `PluginTelemetryBatch`
- **WHEN** it forwards telemetry to core‑elx
- **THEN** the batch is delivered without altering payload fields

### Requirement: OCSF event mapping
The system SHALL ingest plugin events as OCSF Event Log Activity objects and publish them to `events.ocsf.processed` for db‑event‑writer ingestion.

#### Scenario: Plugin event becomes OCSF event
- **GIVEN** a plugin emits an OCSF Event Log Activity entry
- **WHEN** core‑elx processes the telemetry batch
- **THEN** the event is published on `events.ocsf.processed`
- **AND** an `ocsf_events` row is written by db‑event‑writer

### Requirement: OTEL-aligned log mapping
The system SHALL ingest plugin logs as OTEL‑aligned log records and publish them to the logs subject used by the OTEL/logs pipeline.

#### Scenario: Plugin log becomes OTEL log
- **GIVEN** a plugin emits a log record
- **WHEN** core‑elx processes the telemetry batch
- **THEN** the log is published to the configured OTEL/logs subject
- **AND** it is persisted by the existing log ingestion pipeline

### Requirement: Payload validation and limits
The system SHALL validate plugin telemetry batches and enforce size limits per batch and per record.

#### Scenario: Oversized batch rejected
- **GIVEN** a plugin telemetry batch exceeds configured limits
- **WHEN** the agent or gateway processes the batch
- **THEN** the batch is rejected with an error
- **AND** the plugin receives a failure signal

### Requirement: SDK telemetry helpers
The SDKs SHALL provide helpers to emit OCSF events and OTEL‑style logs in a way that maps directly to the telemetry batch payload.

#### Scenario: SDK emits OCSF event
- **GIVEN** a plugin uses the SDK event helper
- **WHEN** it emits a new event
- **THEN** the telemetry batch contains an OCSF Event Log Activity entry with required fields

#### Scenario: SDK emits OTEL log
- **GIVEN** a plugin uses the SDK log helper
- **WHEN** it emits a log record
- **THEN** the telemetry batch contains an OTEL‑aligned log record with severity and body
