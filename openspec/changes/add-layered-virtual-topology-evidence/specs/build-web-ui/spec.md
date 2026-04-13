## ADDED Requirements
### Requirement: Layered topology surface for physical, logical, hosted, and unplaced devices
The topology UI SHALL distinguish physical backbone topology from logical peers, hosted relationships, and discovered-but-unplaced devices.

#### Scenario: Default topology view remains physical-first
- **GIVEN** the topology surface loads a mixed environment containing physical links, logical peers, and hosted virtual devices
- **WHEN** the default operational view renders
- **THEN** the primary canvas SHALL emphasize physical backbone topology
- **AND** logical and hosted relationships SHALL be available without changing the physical contract into fabricated adjacency

#### Scenario: Unplaced virtual router remains operator-visible
- **GIVEN** a discovered router-class device exists in inventory without strong physical, logical, or hosted placement evidence
- **WHEN** the topology UI renders device topology context
- **THEN** the device SHALL appear in an explicit unplaced state
- **AND** the UI SHALL NOT draw a fabricated physical edge to force it into the backbone

### Requirement: Layered relation semantics do not pollute endpoint rendering
The topology UI SHALL keep physical backbone, logical/hosted relations, and endpoint attachment semantics separate so virtual-router handling does not reintroduce endpoint explosions or false attachment groups.

#### Scenario: Logical or hosted relation does not create endpoint bubble
- **GIVEN** a virtual router is present through `LOGICAL_PEER` or `HOSTED_ON`
- **WHEN** the topology snapshot is rendered
- **THEN** the UI SHALL render that relation according to its layer semantics
- **AND** it SHALL NOT count the device as an endpoint-cluster member solely because it is not physically placed
