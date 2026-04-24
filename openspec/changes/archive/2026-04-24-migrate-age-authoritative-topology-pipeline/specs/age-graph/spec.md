## ADDED Requirements
### Requirement: AGE-authoritative topology read model
The system SHALL treat canonical Apache AGE topology edges as the authoritative source for topology rendering and downstream graph consumers.

#### Scenario: Renderer consumes canonical AGE edges
- **GIVEN** canonical topology edges are projected in AGE
- **WHEN** web topology views are generated
- **THEN** edge construction SHALL use canonical AGE adjacency
- **AND** rendering SHALL NOT require additional identity-fusion heuristics in the UI layer

### Requirement: Evidence-backed stale-edge lifecycle
The system SHALL expire inferred AGE edges when supporting evidence has aged beyond configured freshness windows.

#### Scenario: Stale inferred edge is retracted
- **GIVEN** an inferred edge has no supporting observations within the freshness window
- **WHEN** topology reconciliation runs
- **THEN** the inferred edge SHALL be marked stale and removed from canonical AGE adjacency
- **AND** direct evidence-backed edges SHALL remain unless they are also stale

### Requirement: Deterministic topology reset and rebuild
The system SHALL provide an operator-safe workflow to clear polluted topology evidence and deterministically rebuild AGE topology from fresh observations.

#### Scenario: Cleanup and rebuild produces bounded graph state
- **GIVEN** topology evidence and AGE edges are reset using the documented workflow
- **WHEN** fresh discovery jobs run and ingestion completes
- **THEN** rebuilt AGE adjacency SHALL be derived only from post-reset evidence
- **AND** validation queries SHALL report pre/post counts and unresolved endpoint totals
