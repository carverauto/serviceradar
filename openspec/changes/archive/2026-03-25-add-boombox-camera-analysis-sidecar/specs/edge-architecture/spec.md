## ADDED Requirements
### Requirement: Boombox-backed sidecar workers remain relay-attached
The system SHALL allow a relay-scoped Boombox-backed sidecar worker path to consume bounded relay-derived media without requiring another upstream camera pull or direct camera session from the worker.

#### Scenario: Relay-derived media is consumed by a sidecar
- **GIVEN** an active relay session with an attached sidecar worker path
- **WHEN** the platform enables a sidecar worker for that branch
- **THEN** the worker SHALL consume media derived from the platform relay path
- **AND** SHALL NOT open a separate session to the edge agent or camera

### Requirement: Boombox sidecar workers remain optional
The system SHALL treat the Boombox-backed sidecar worker as an optional analysis path alongside the existing HTTP worker adapter.

#### Scenario: Deployment uses another analysis adapter
- **GIVEN** a deployment that uses the existing HTTP analysis adapter
- **WHEN** the Boombox-backed sidecar worker is not enabled
- **THEN** the platform SHALL continue to support analysis without the Boombox sidecar path
