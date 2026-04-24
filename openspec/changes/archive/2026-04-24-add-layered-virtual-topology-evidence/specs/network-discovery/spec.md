## ADDED Requirements
### Requirement: Layered topology evidence classification
The system SHALL normalize discovery topology evidence into explicit evidence classes so physical adjacency, logical peer relationships, virtualization placement, inferred segment attachment, and observational sightings are not treated as interchangeable.

#### Scenario: LLDP neighbor normalizes as direct physical evidence
- **GIVEN** mapper discovery publishes an LLDP or CDP neighbor relation between two devices
- **WHEN** the topology evidence is normalized
- **THEN** the relation SHALL be classified as `direct-physical`
- **AND** it SHALL be eligible for physical backbone promotion and recursive discovery

#### Scenario: WireGuard tunnel normalizes as direct logical evidence
- **GIVEN** mapper discovery publishes a deterministic WireGuard tunnel match between two devices
- **WHEN** the topology evidence is normalized
- **THEN** the relation SHALL be classified as `direct-logical`
- **AND** it SHALL be eligible for logical-topology promotion and recursive discovery

#### Scenario: Weak ARP-only sighting remains observational
- **GIVEN** mapper discovery publishes a `candidate_only` or one-sided ARP/FDB sighting without strong neighbor identity
- **WHEN** the topology evidence is normalized
- **THEN** the relation SHALL be classified as `observed-only` or `inferred-segment`
- **AND** it SHALL NOT be eligible for physical backbone promotion or recursive discovery

### Requirement: Virtual and hosted device topology handling
The system SHALL model virtual routers and other hosted network appliances through strong logical or hosted evidence when available and SHALL NOT require weak L2 inference to place them in topology.

#### Scenario: Hosted virtual router has authoritative host evidence
- **GIVEN** a virtualization collector reports that a virtual router guest runs on a specific hypervisor host
- **WHEN** the topology evidence is normalized
- **THEN** the relation SHALL be classified as `hosted-virtual`
- **AND** the topology pipeline SHALL preserve that host/guest relationship for canonical projection

#### Scenario: Virtual router has no strong placement evidence
- **GIVEN** inventory contains a managed router or firewall device
- **AND** the current discovery window has no `direct-physical`, `direct-logical`, or `hosted-virtual` evidence for it
- **WHEN** topology results are ingested
- **THEN** the device SHALL remain discoverable in inventory
- **AND** it SHALL be marked topology-unplaced rather than attached through fabricated physical adjacency

### Requirement: Strong-evidence recursive discovery
Recursive mapper discovery SHALL expand from topology-eligible strong evidence instead of from every observed address or weak segment sighting.

#### Scenario: Recursive discovery follows strong physical or logical neighbor
- **GIVEN** a discovery job reaches a router or switch with a new `direct-physical` or `direct-logical` neighbor
- **WHEN** recursive discovery evaluates new targets
- **THEN** the neighbor SHALL be eligible for expansion

#### Scenario: Recursive discovery skips endpoint-like ARP/FDB noise
- **GIVEN** a discovery job observes new IP or MAC sightings through ARP/FDB evidence only
- **WHEN** recursive discovery evaluates new targets
- **THEN** those observational or inferred-segment targets SHALL NOT be added solely on that basis
