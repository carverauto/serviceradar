# health-events Specification

## Purpose
Track internal component health, record lifecycle transitions as durable health events in CNPG, mirror telemetry transitions to JetStream, and promote core health state changes into actionable alerts.

## Requirements

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

### Requirement: Internal health updates use Phoenix PubSub for live UI
Internal health events SHALL be broadcast via Phoenix PubSub for live UI updates.

#### Scenario: Live UI update after state change
- **GIVEN** a user is viewing the infrastructure dashboard
- **WHEN** a poller transitions to `:offline`
- **THEN** the UI SHALL receive a PubSub event for the tenant
- **AND** the UI SHALL update without polling NATS

### Requirement: Internal health events are mirrored into OCSF events
Internal health state transitions SHALL produce an OCSF event through JetStream so they appear in the Events UI and in every telemetry backend.

#### Scenario: State change produces an OCSF event
- **GIVEN** a gateway transitions from `:healthy` to `:offline`
- **WHEN** the transition is recorded
- **THEN** an OCSF event SHALL be published to JetStream and stored by EventWriter
- **AND** the OCSF event SHALL include the entity type, entity ID, and new state

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

### Requirement: Core health transitions are promoted and alert
The internal health log SHALL carry a structured `health` attribute block (entity type, entity id, old state, new state, reason). A seeded event rule SHALL promote every core health transition into a `health.core.state_change` event, and a seeded managed stateful rule SHALL open one critical incident per core check when it becomes unhealthy and SHALL recover it when the check becomes healthy again.

#### Scenario: A dead baseline producer pages
- **GIVEN** the seasonal-baseline freshness check records unhealthy
- **WHEN** the health log is promoted
- **THEN** a critical alert opens for the check id `seasonal-baseline-freshness`

#### Scenario: Recovery resolves the incident
- **GIVEN** an open incident for a core check
- **WHEN** the check records healthy
- **THEN** the incident recovers and no new incident opens

#### Scenario: Checks are independent incidents
- **GIVEN** two core checks unhealthy at once
- **WHEN** the rule evaluates both transitions
- **THEN** two incidents exist, one per check id
