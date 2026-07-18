## ADDED Requirements

### Requirement: Source Identity Conflict Diagnostics
The inventory data layer SHALL persist or expose source identity conflicts so operators can distinguish unreachable devices from devices whose identity evidence is unsafe.

#### Scenario: Conflict is recorded for source identity drift
- **GIVEN** identity reconciliation detects that an active device has conflicting source-authoritative identifiers
- **WHEN** the conflict is detected
- **THEN** inventory diagnostics SHALL include the device UID, source type, source identifier values, current IP, current MAC, conflict category, first detected time, and last detected time
- **AND** the conflict SHALL remain visible until repaired or explicitly dismissed

#### Scenario: Conflict diagnostics are not silently purged
- **GIVEN** an unresolved source identity conflict exists
- **WHEN** routine retention or cleanup workers run
- **THEN** the conflict SHALL NOT be silently deleted solely because it is older than 30 days
- **AND** automated workflows SHALL continue treating the affected identity as unsafe until the conflict is resolved

### Requirement: Inventory Repair Audit Trail
The inventory data layer SHALL record audit information for automated or operator-approved repairs of source identity drift.

#### Scenario: Automated metadata repair
- **GIVEN** a device has one typed Armis identifier and stale metadata with a different Armis ID
- **WHEN** repair tooling updates the stale metadata to match the typed identifier
- **THEN** the system SHALL record the prior value, repaired value, repair actor, repair time, and repair reason

#### Scenario: Ambiguous conflict remains unresolved
- **GIVEN** a conflict involves multiple active devices or multiple plausible source identifiers
- **WHEN** repair tooling cannot prove a safe correction
- **THEN** the tool SHALL leave the conflict unresolved
- **AND** it SHALL record why automatic repair was skipped
