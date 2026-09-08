## ADDED Requirements
### Requirement: External Boombox worker findings preserve observability provenance
The system SHALL preserve relay session, analysis branch, and worker provenance when ingesting normalized results from an external Boombox-backed worker.

#### Scenario: External worker returns a derived finding
- **GIVEN** a relay-scoped analysis branch with an attached external Boombox-backed worker
- **WHEN** the worker returns a valid normalized analysis result
- **THEN** the platform SHALL ingest the result through the normal observability path
- **AND** SHALL preserve the originating relay session, branch, and worker identity
