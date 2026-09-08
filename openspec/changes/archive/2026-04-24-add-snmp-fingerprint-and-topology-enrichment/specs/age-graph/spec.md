## ADDED Requirements
### Requirement: Confidence-aware topology edge lifecycle
The system SHALL maintain topology edges in AGE with confidence-aware projection and observation freshness controls.

#### Scenario: Idempotent edge upsert with confidence metadata
- **GIVEN** a topology link candidate eligible for projection
- **WHEN** projection runs repeatedly for the same source/target/interface tuple
- **THEN** the AGE edge SHALL be upserted once
- **AND** edge confidence and last-observed timestamp SHALL be updated in place

#### Scenario: Stale projected edge is retired
- **GIVEN** a projected topology edge has not been observed for longer than the configured stale threshold
- **WHEN** topology reconciliation runs
- **THEN** the edge SHALL be removed or marked inactive based on configured retention policy
