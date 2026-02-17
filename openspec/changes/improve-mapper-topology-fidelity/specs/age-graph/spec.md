## ADDED Requirements
### Requirement: Device-level topology edge semantics
The system SHALL reserve `CONNECTS_TO` for device-to-device adjacency and SHALL derive those edges from ingested interface-level observations.

#### Scenario: Device adjacency projection
- **GIVEN** interface-level LLDP/CDP/SNMP link evidence between two devices
- **WHEN** topology projection runs
- **THEN** a `CONNECTS_TO` edge SHALL exist between the corresponding Device nodes
- **AND** repeated observations SHALL update freshness/confidence metadata without creating duplicate effective edges

#### Scenario: Interface evidence preservation
- **GIVEN** interface-level observations are used to derive device adjacency
- **WHEN** topology is projected
- **THEN** interface-level evidence SHALL remain queryable in graph storage
- **AND** interface evidence SHALL map back to parent device adjacency

### Requirement: Topology edge freshness lifecycle
The system SHALL retire stale topology edges that are no longer observed within configured freshness windows.

#### Scenario: Stale edge retirement
- **GIVEN** a projected device adjacency edge has not been observed past the configured stale threshold
- **WHEN** topology reconciliation runs
- **THEN** the edge SHALL be removed or marked inactive according to retention policy
