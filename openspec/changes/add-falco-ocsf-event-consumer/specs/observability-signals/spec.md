## ADDED Requirements

### Requirement: Falco JetStream events are persisted as OCSF events
The system SHALL consume Falco runtime events from JetStream subjects matching `falco.>` (default stream `falco_events`) through the Elixir Broadway EventWriter pipeline and SHALL persist valid messages as OCSF Event Log Activity records in `ocsf_events`.

#### Scenario: Falco message is normalized and inserted
- **GIVEN** a Falco message with fields `uuid`, `time`, `rule`, `priority`, and `output`
- **WHEN** the EventWriter Broadway consumer receives the message on a `falco.*` subject
- **THEN** one row SHALL be inserted into `ocsf_events`
- **AND** the row SHALL use OCSF Event Log Activity identifiers (`class_uid=1008`, `category_uid=1`, `activity_id=3`)
- **AND** `severity_id` SHALL be derived from Falco `priority`
- **AND** `status_id` SHALL be derived from Falco `priority`

#### Scenario: Falco stream naming is configurable
- **GIVEN** an environment where Falco events are published to a non-default JetStream stream name
- **WHEN** operators configure EventWriter with that stream and subject filter
- **THEN** the Broadway consumer SHALL read from the configured stream without code changes

### Requirement: Falco priority mapping is deterministic
The system SHALL map Falco `priority` values to OCSF severity and status values using a fixed, case-insensitive policy.

#### Scenario: Warning priority maps to failure
- **GIVEN** a Falco payload with `priority` equal to `Warning`
- **WHEN** the payload is persisted as an OCSF event
- **THEN** `severity_id` SHALL be `3` and `severity` SHALL be `Medium`
- **AND** `status_id` SHALL be `2` and `status` SHALL be `Failure`

#### Scenario: Notice priority maps to low-success
- **GIVEN** a Falco payload with `priority` equal to `Notice`
- **WHEN** the payload is persisted as an OCSF event
- **THEN** `severity_id` SHALL be `2` and `severity` SHALL be `Low`
- **AND** `status_id` SHALL be `1` and `status` SHALL be `Success`

#### Scenario: Unknown priority maps to unknown-other
- **GIVEN** a Falco payload with missing or unrecognized `priority`
- **WHEN** the payload is persisted as an OCSF event
- **THEN** `severity_id` SHALL be `0` and `severity` SHALL be `Unknown`
- **AND** `status_id` SHALL be `99` and `status` SHALL be `Other`

### Requirement: Falco forensic context is preserved in OCSF rows
The system SHALL preserve original Falco payload context so investigators can reconstruct the source detection from each persisted event.

#### Scenario: Raw payload and fields are retained
- **GIVEN** a Falco payload containing `output_fields`, `tags`, `hostname`, and `source`
- **WHEN** the payload is persisted to `ocsf_events`
- **THEN** the full input JSON SHALL be stored in `raw_data`
- **AND** Falco-specific context SHALL be retained in `metadata` and/or `unmapped`
- **AND** the source subject SHALL be stored in `log_name`

### Requirement: Falco ingestion is idempotent and non-blocking
The system SHALL avoid duplicate rows from redelivery and SHALL NOT let malformed Falco payloads block Broadway consumption.

#### Scenario: Duplicate Falco redelivery does not create duplicate rows
- **GIVEN** the same Falco event is delivered more than once with the same identity key
- **WHEN** EventWriter processes the redelivered message
- **THEN** at most one corresponding `ocsf_events` row SHALL exist
- **AND** the duplicate delivery SHALL be acknowledged without pipeline failure

#### Scenario: Malformed Falco payload is dropped safely
- **GIVEN** a message on `falco.*` that is invalid JSON or missing required mapping fields
- **WHEN** EventWriter attempts normalization
- **THEN** the message SHALL be acknowledged and excluded from `ocsf_events`
- **AND** the system SHALL emit telemetry/logging for the drop reason

### Requirement: Falco-backed events participate in existing event workflows
Falco-derived OCSF events SHALL participate in the same downstream workflows as other `ocsf_events` entries.

#### Scenario: UI and alert workflows receive Falco events
- **GIVEN** a Falco-derived OCSF event is inserted
- **WHEN** post-insert hooks run
- **THEN** the Events PubSub update SHALL be broadcast
- **AND** stateful event rules SHALL evaluate the inserted event
