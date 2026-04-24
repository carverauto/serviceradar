## ADDED Requirements

### Requirement: Falco messages follow dual-path ingestion
The system SHALL consume Falco runtime events from JetStream subjects matching `falco.>` (default stream `falco_events`) through the Elixir Broadway EventWriter pipeline. Every valid Falco payload SHALL be persisted into `logs`, and only higher-severity Falco payloads SHALL be promoted into `ocsf_events`.

#### Scenario: Notice payload is stored as raw log only
- **GIVEN** a Falco message with `priority` equal to `Notice`
- **WHEN** EventWriter receives the message on a `falco.*` subject
- **THEN** one row SHALL be inserted into `logs`
- **AND** no row SHALL be inserted into `ocsf_events`

#### Scenario: Warning payload is promoted to event
- **GIVEN** a Falco message with `priority` equal to `Warning`
- **WHEN** EventWriter receives the message on a `falco.*` subject
- **THEN** one row SHALL be inserted into `logs`
- **AND** one row SHALL be inserted into `ocsf_events`
- **AND** the event row SHALL use OCSF Event Log Activity identifiers (`class_uid=1008`, `category_uid=1`, `activity_id=3`)

#### Scenario: Falco stream naming is configurable
- **GIVEN** an environment where Falco events are published to a non-default JetStream stream name
- **WHEN** operators configure EventWriter with that stream and subject filter
- **THEN** the Broadway consumer SHALL read from the configured stream without code changes

### Requirement: Falco priority mapping is deterministic
The system SHALL map Falco `priority` values to OCSF severity and status values using a fixed, case-insensitive policy.

#### Scenario: Warning priority maps to medium-failure
- **GIVEN** a Falco payload with `priority` equal to `Warning`
- **WHEN** the payload is mapped
- **THEN** `severity_id` SHALL be `3` and `severity` SHALL be `Medium`
- **AND** `status_id` SHALL be `2` and `status` SHALL be `Failure`

#### Scenario: Notice priority maps to low-success
- **GIVEN** a Falco payload with `priority` equal to `Notice`
- **WHEN** the payload is mapped
- **THEN** `severity_id` SHALL be `2` and `severity` SHALL be `Low`
- **AND** `status_id` SHALL be `1` and `status` SHALL be `Success`

#### Scenario: Unknown priority maps to unknown-other
- **GIVEN** a Falco payload with missing or unrecognized `priority`
- **WHEN** the payload is mapped
- **THEN** `severity_id` SHALL be `0` and `severity` SHALL be `Unknown`
- **AND** `status_id` SHALL be `99` and `status` SHALL be `Other`

### Requirement: Falco critical severities auto-create alerts
The system SHALL auto-create alerts from Falco-promoted OCSF events when severity is critical or fatal.

#### Scenario: Critical payload is escalated to alert
- **GIVEN** a Falco payload with `priority` equal to `Critical`
- **WHEN** the payload is promoted into `ocsf_events`
- **THEN** the alert generator SHALL be invoked for the inserted event
- **AND** the resulting alert SHALL reference that OCSF event

### Requirement: Falco context and provenance are preserved
The system SHALL preserve original Falco payload context in both storage paths and SHALL maintain event-to-log provenance for promoted rows.

#### Scenario: Promoted event links to source log
- **GIVEN** a Falco payload containing `rule`, `output_fields`, `tags`, `hostname`, and source subject
- **WHEN** the payload is promoted to an OCSF event
- **THEN** the raw Falco JSON SHALL be stored in the event `raw_data`
- **AND** Falco context SHALL be retained in event metadata/unmapped fields
- **AND** metadata SHALL include `source_log_id` linking to the corresponding `logs` row

### Requirement: Falco ingestion is idempotent and non-blocking
The system SHALL avoid duplicate rows from redelivery and SHALL NOT let malformed Falco payloads block Broadway consumption.

#### Scenario: Duplicate Falco redelivery does not create duplicate rows
- **GIVEN** the same Falco event is delivered more than once with the same identity key
- **WHEN** EventWriter processes the redelivered message
- **THEN** at most one corresponding `logs` row SHALL exist
- **AND** at most one corresponding promoted `ocsf_events` row SHALL exist
- **AND** the duplicate delivery SHALL be acknowledged without pipeline failure

#### Scenario: Malformed Falco payload is dropped safely
- **GIVEN** a message on `falco.*` that is invalid JSON or missing required mapping fields
- **WHEN** EventWriter attempts normalization
- **THEN** the message SHALL be acknowledged and excluded from `logs` and `ocsf_events`
- **AND** the system SHALL emit telemetry/logging for the drop reason

### Requirement: Falco-promoted events participate in existing event workflows
Falco-promoted OCSF events SHALL participate in the same downstream workflows as other `ocsf_events` entries.

#### Scenario: Event workflows run for promoted Falco event
- **GIVEN** a Falco-derived OCSF event is inserted
- **WHEN** post-insert hooks run
- **THEN** the Events PubSub update SHALL be broadcast
- **AND** stateful event rules SHALL evaluate the inserted event
