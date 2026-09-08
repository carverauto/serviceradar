## ADDED Requirements
### Requirement: LLDP-First Topology Evidence Classification
The system SHALL classify mapper topology evidence into explicit classes: `direct`, `inferred`, and `endpoint-attachment`.

#### Scenario: Direct LLDP adjacency observed
- **GIVEN** a mapper observation sourced from LLDP or CDP with local interface and neighbor identity fields
- **WHEN** the mapper emits topology evidence
- **THEN** the evidence SHALL be classified as `direct`
- **AND** it SHALL include protocol, local interface identity, neighbor identity, confidence, and observation timestamp

#### Scenario: ARP/FDB-only observation observed
- **GIVEN** a mapper observation sourced from ARP/FDB correlation without direct neighbor protocol evidence
- **WHEN** the mapper emits topology evidence
- **THEN** the evidence SHALL be classified as `inferred` or `endpoint-attachment`
- **AND** it SHALL NOT be promoted to `direct`

### Requirement: Optional Agent LLDP Frame Collection
The agent SHALL support an optional host-level LLDP frame collection mode for environments that allow required capture privileges.

#### Scenario: LLDP frame collection enabled with privileges
- **GIVEN** LLDP frame collection is enabled for an agent
- **AND** required capture capabilities are available
- **WHEN** LLDP frames are received on monitored interfaces
- **THEN** the agent SHALL parse and publish LLDP neighbor evidence with interface binding

#### Scenario: LLDP frame collection enabled without privileges
- **GIVEN** LLDP frame collection is enabled for an agent
- **AND** required capture capabilities are unavailable
- **WHEN** discovery runs
- **THEN** the agent SHALL continue SNMP/controller discovery paths
- **AND** SHALL emit explicit diagnostics that frame collection is disabled by capability constraints

### Requirement: Route Snapshot Collection for Path Analysis
The system SHALL collect route snapshots for managed routing devices in a format compatible with longest-prefix-match and recursive next-hop analysis.

#### Scenario: Route snapshot captured from router
- **GIVEN** a managed routing device with reachable route telemetry
- **WHEN** mapper discovery executes route collection
- **THEN** route entries SHALL be stored with destination prefix, administrative preference/metric, and one or more next-hops
- **AND** each snapshot SHALL include a source device identity and timestamp
