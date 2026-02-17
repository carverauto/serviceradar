## ADDED Requirements
### Requirement: Immutable source endpoint identifiers for topology evidence
The system SHALL preserve mapper/source endpoint identifiers as immutable evidence attributes during topology ingestion and reconciliation.

#### Scenario: Reconciliation does not rewrite source endpoint IDs
- **GIVEN** a topology observation with `source_uid` and `target_uid` from mapper evidence
- **WHEN** the identity engine resolves canonical device IDs
- **THEN** canonical IDs SHALL be linked as reconciliation metadata
- **AND** original `source_uid` and `target_uid` values SHALL remain unchanged in evidence storage

### Requirement: Unresolved endpoints remain explicit
The system SHALL represent unresolved topology endpoints explicitly and SHALL NOT merge them via presentation-layer hostname/IP guessing.

#### Scenario: Unknown endpoint is tracked as unresolved
- **GIVEN** a topology observation target cannot be resolved to a canonical device
- **WHEN** ingestion processes the observation
- **THEN** an unresolved endpoint record SHALL be persisted with the original evidence identifiers
- **AND** the unresolved endpoint MAY be reconciled later when additional strong identifiers arrive
