## ADDED Requirements
### Requirement: Docker Compose BMP Collector Service
The Docker Compose stack SHALL provide a BMP collector service that publishes to the platform JetStream instance using the same operational patterns as other external collectors.

#### Scenario: Compose stack starts BMP collector with NATS connectivity
- **GIVEN** the default compose stack is started
- **WHEN** NATS and BMP collector services initialize
- **THEN** the BMP collector SHALL start successfully with configured NATS connectivity
- **AND** it SHALL be able to publish to `BMP_CAUSAL` subjects under `bmp.events.>`

#### Scenario: BMP collector failure is observable
- **GIVEN** BMP collector startup fails due to invalid config or NATS connectivity issues
- **WHEN** compose health/log inspection is performed
- **THEN** the failure SHALL be visible through container logs and service status
- **AND** operators SHALL be able to diagnose the failing dependency from compose diagnostics
