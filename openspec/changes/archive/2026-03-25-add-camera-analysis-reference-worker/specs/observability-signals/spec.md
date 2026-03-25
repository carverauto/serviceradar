## ADDED Requirements
### Requirement: Reference analysis workers must preserve analysis provenance
The system SHALL provide at least one reference analysis worker implementation whose derived outputs preserve relay session, branch, and worker provenance through normal observability ingestion.

#### Scenario: Reference worker emits a derived finding
- **GIVEN** a relay-scoped analysis branch sends a normalized analysis input to the reference worker
- **WHEN** the worker returns a valid result payload
- **THEN** the platform SHALL ingest the derived result through the normal observability path
- **AND** SHALL preserve the originating relay session, analysis branch, and worker identity

### Requirement: Reference workers may return bounded no-op results
The system SHALL allow a reference analysis worker to return no derived findings for bounded unsupported or uninteresting inputs.

#### Scenario: Input does not produce a finding
- **GIVEN** a normalized analysis input that the reference worker intentionally treats as a no-op
- **WHEN** the worker processes the request
- **THEN** the worker MAY return an empty result set
- **AND** the platform SHALL treat that as a successful bounded analysis outcome rather than a relay failure
