## ADDED Requirements
### Requirement: Staged Discovery Pipeline Execution
The mapper discovery engine SHALL execute discovery in explicit stages with deterministic ordering and isolation between identity and topology resolution.

#### Scenario: Identity stage precedes topology stage
- **GIVEN** a discovery job is executing
- **WHEN** the pipeline transitions through stages
- **THEN** identity reconciliation SHALL complete before topology relationship resolution begins
- **AND** topology evidence SHALL not mutate identity stage decisions in the same execution pass

### Requirement: Structured Discovery Payload Contracts
The mapper SHALL emit structured discovery payload contracts and SHALL NOT rely on untyped raw payload maps for cross-service semantics.

#### Scenario: Discovery payload is contract-typed
- **GIVEN** discovery results are published
- **WHEN** downstream ingestion consumes the payload
- **THEN** identity, topology, and enrichment fields SHALL be represented in typed contract fields
- **AND** payload interpretation SHALL not depend on untyped key guessing
