## ADDED Requirements

### Requirement: Internal health events are persisted directly in CNPG
The system SHALL persist internal state/health transitions as `HealthEvent` records in CNPG without routing them through NATS.

#### Scenario: State transition creates a HealthEvent record
- **GIVEN** an agent transitions from `:connected` to `:degraded`
- **WHEN** the transition action completes
- **THEN** a `HealthEvent` record SHALL be inserted for the agent
- **AND** no NATS publish is required for the internal transition

#### Scenario: Heartbeat timeout records a HealthEvent
- **GIVEN** a gateway misses its heartbeat deadline
- **WHEN** the health monitor records the timeout
- **THEN** a `HealthEvent` record SHALL be inserted for the gateway
- **AND** the event SHALL be available for timeline queries

### Requirement: Internal health updates use Phoenix PubSub for live UI
Internal health events SHALL be broadcast via Phoenix PubSub for live UI updates.

#### Scenario: Live UI update after state change
- **GIVEN** a user is viewing the infrastructure dashboard
- **WHEN** a poller transitions to `:offline`
- **THEN** the UI SHALL receive a PubSub event for the tenant
- **AND** the UI SHALL update without polling NATS

### Requirement: NATS remains for external ingestion only
NATS JetStream SHALL continue to ingest external/edge streams and SHALL NOT be required for internal health persistence.

#### Scenario: External ingestion continues via NATS
- **GIVEN** a collector publishes `tenant-a.logs.>`
- **WHEN** EventWriter is running
- **THEN** the logs SHALL be ingested via NATS and written to CNPG

#### Scenario: Internal health persists even if NATS is unavailable
- **GIVEN** NATS is unreachable
- **WHEN** a checker transitions to `:failing`
- **THEN** the `HealthEvent` record SHALL still be persisted
- **AND** the transition SHALL not fail due to NATS connectivity
