## ADDED Requirements
### Requirement: Topology Evidence Must Not Drive Identity Equivalence
The system SHALL treat topology adjacency as relationship evidence only and SHALL NOT use topology links as sufficient proof that two observations represent the same device identity.

#### Scenario: Shared neighbor does not collapse identities
- **GIVEN** two discovered devices both report adjacency to the same gateway or subnet anchor
- **WHEN** identity reconciliation is evaluated for discovery output
- **THEN** the system SHALL keep device identities distinct unless identity proof requirements are met
- **AND** adjacency evidence SHALL be stored as topology relationship evidence only

#### Scenario: Inferred subnet evidence cannot force identity merge
- **GIVEN** inferred topology evidence derived from subnet, ARP, or gateway correlation
- **WHEN** identity reconciliation is evaluated
- **THEN** inferred topology evidence SHALL NOT trigger identity equivalence or device merges by itself

### Requirement: Deterministic Discovery Identity Anchors
The mapper discovery pipeline SHALL emit deterministic identity anchors and SHALL preserve source evidence fields used to justify identity and topology decisions.

#### Scenario: Multi-IP device observations converge to one anchored identity
- **GIVEN** a physical device is observed via multiple management or interface IP addresses across discovery paths
- **WHEN** discovery results are published
- **THEN** the observations SHALL reference one deterministic identity anchor
- **AND** the payload SHALL retain source evidence fields needed for reconciliation audits
