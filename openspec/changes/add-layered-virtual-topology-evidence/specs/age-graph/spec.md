## ADDED Requirements
### Requirement: Layered canonical topology relations
The system SHALL project canonical topology into Apache AGE using relation families that preserve physical, logical, hosted, attachment, and observational semantics instead of forcing all relations through one adjacency type.

#### Scenario: Physical, logical, and hosted relations project separately
- **GIVEN** ingested topology evidence includes `direct-physical`, `direct-logical`, and `hosted-virtual` observations
- **WHEN** canonical projection runs
- **THEN** physical adjacency SHALL project as `CONNECTS_TO`
- **AND** logical adjacency SHALL project as `LOGICAL_PEER`
- **AND** host/guest placement SHALL project as `HOSTED_ON`

#### Scenario: Endpoint attachment remains separate from backbone
- **GIVEN** ingested topology evidence includes endpoint-like `inferred-segment` observations
- **WHEN** canonical projection runs
- **THEN** those relations SHALL project as `ATTACHED_TO`
- **AND** they SHALL NOT be promoted to `CONNECTS_TO` without qualifying strong evidence

### Requirement: Weak observations do not fabricate virtual-device backbone edges
The system SHALL NOT promote weak observational or segment-inferred evidence into physical backbone placement for virtual routers or other managed appliances.

#### Scenario: Virtual router observed only through FDB does not become physical peer
- **GIVEN** a router-class device is present in inventory
- **AND** its only current topology evidence is `snmp-arp-fdb` or other weak observational evidence
- **WHEN** canonical projection runs
- **THEN** the system SHALL NOT create a `CONNECTS_TO` edge solely from that evidence
- **AND** the device SHALL remain available for logical, hosted, or unplaced rendering paths
