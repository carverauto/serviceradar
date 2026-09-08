## ADDED Requirements

### Requirement: End-to-End Streaming Ingestion Release Gate
The system SHALL provide a release-gate validation command or documented runbook that proves large sync payloads travel through the same agent, agent-gateway, and core ingestion path used in production.

#### Scenario: Release candidate touches ingestion code
- **GIVEN** a release candidate changes integration sync, agent streaming, gateway routing, identity reconciliation, or inventory ingestion code
- **WHEN** the release gate is run
- **THEN** it SHALL stream a large faker-backed payload through agent to agent-gateway to core
- **AND** it SHALL verify chunk counts, ordering, final inventory counts, and absence of ingestion constraint errors.

#### Scenario: Gateway or core restarts during validation
- **GIVEN** a large sync validation run is active
- **WHEN** agent-gateway or core restarts during the run
- **THEN** validation SHALL either prove graceful recovery or fail with a clear diagnostic identifying the lost or duplicated chunk boundary.
