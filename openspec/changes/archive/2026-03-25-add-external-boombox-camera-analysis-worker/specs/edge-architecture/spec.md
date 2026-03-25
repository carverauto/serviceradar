## ADDED Requirements
### Requirement: External Boombox workers remain relay-attached
The system SHALL allow a relay-scoped analysis branch to feed an external Boombox-backed worker without requiring another upstream camera pull or direct camera session from that worker.

#### Scenario: Relay-derived media is handed to an external worker
- **GIVEN** an active relay session with an attached analysis branch
- **WHEN** the platform enables an external Boombox-backed worker for that branch
- **THEN** the worker SHALL consume media derived from the platform relay path
- **AND** SHALL NOT open a separate session to the edge agent or camera

### Requirement: External workers remain optional
The system SHALL treat the external Boombox-backed worker as an optional analysis path alongside existing in-process and HTTP-based adapters.

#### Scenario: Deployment uses another analysis adapter
- **GIVEN** a deployment that uses another supported analysis adapter
- **WHEN** the external Boombox-backed worker is not enabled
- **THEN** the platform SHALL continue to support analysis without the external worker path
