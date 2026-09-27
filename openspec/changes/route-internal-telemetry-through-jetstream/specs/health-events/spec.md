## MODIFIED Requirements

### Requirement: Internal health events are persisted directly in CNPG
The system SHALL persist internal state/health transitions as `HealthEvent` records in CNPG without routing them through NATS.
`HealthEvent` is current-state history owned by the control plane. The OCSF event and internal
log that mirror a transition are telemetry and travel through JetStream (see "NATS carries
internal telemetry").

#### Scenario: State transition creates a HealthEvent record
- **GIVEN** an agent transitions from `:connected` to `:degraded`
- **WHEN** the transition action completes
- **THEN** a `HealthEvent` record SHALL be inserted for the agent
- **AND** no NATS publish is required for the `HealthEvent` record itself

#### Scenario: Heartbeat timeout records a HealthEvent
- **GIVEN** a gateway misses its heartbeat deadline
- **WHEN** the health monitor records the timeout
- **THEN** a `HealthEvent` record SHALL be inserted for the gateway
- **AND** the event SHALL be available for timeline queries

### Requirement: NATS carries internal telemetry
The system SHALL publish internal OCSF events, internal logs and internally produced analytics signals to NATS JetStream, and EventWriter SHALL be their only writer to telemetry storage.
External and edge streams continue to be ingested through NATS as before. When NATS is
unreachable, the telemetry is retained durably and published once NATS returns; the producing
operation does not fail.

#### Scenario: External ingestion continues via NATS
- **GIVEN** a collector publishes `logs.>`
- **WHEN** EventWriter is running
- **THEN** the logs SHALL be ingested via NATS and written to telemetry storage

#### Scenario: Internal health persists even if NATS is unavailable
- **GIVEN** NATS is unreachable
- **WHEN** a checker transitions to `:failing`
- **THEN** the `HealthEvent` record SHALL still be persisted
- **AND** the transition's OCSF event and internal log SHALL be retained durably and published when NATS is reachable again
- **AND** the transition SHALL not fail due to NATS connectivity

### Requirement: Internal health events are mirrored into OCSF events
Internal health state transitions SHALL produce an OCSF event through JetStream so they appear in the Events UI and in every telemetry backend.

#### Scenario: State change produces an OCSF event
- **GIVEN** a gateway transitions from `:healthy` to `:offline`
- **WHEN** the transition is recorded
- **THEN** an OCSF event SHALL be published to JetStream and stored by EventWriter
- **AND** the OCSF event SHALL include the entity type, entity ID, and new state

## RENAMED Requirements

- FROM: `### Requirement: NATS remains for external ingestion only`
- TO: `### Requirement: NATS carries internal telemetry`
