## ADDED Requirements
### Requirement: Boombox sidecar findings preserve observability provenance
The system SHALL preserve relay session, analysis branch, and worker provenance when ingesting normalized results from a Boombox-backed sidecar worker.

#### Scenario: Sidecar worker returns a derived finding
- **GIVEN** a relay-scoped Boombox-backed sidecar worker path
- **WHEN** the sidecar returns a valid normalized analysis result
- **THEN** the platform SHALL ingest the result through the normal observability path
- **AND** SHALL preserve the originating relay session, branch, and worker identity
