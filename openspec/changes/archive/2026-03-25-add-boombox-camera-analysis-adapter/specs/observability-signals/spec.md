## ADDED Requirements
### Requirement: Boombox-backed analysis preserves observability provenance
The system SHALL preserve relay session, analysis branch, and worker provenance when ingesting results from Boombox-backed analysis.

#### Scenario: Boombox-backed worker returns a derived finding
- **GIVEN** a relay-scoped analysis branch bridged through Boombox
- **WHEN** the downstream worker returns a valid analysis result
- **THEN** the platform SHALL ingest the result through the normal observability path
- **AND** SHALL preserve the originating relay session, branch, and worker identity
