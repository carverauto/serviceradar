## ADDED Requirements
### Requirement: Canonical transport backbone excludes non-promotable identities
The topology discovery and projection pipeline SHALL distinguish promotable transport-backbone identities from unresolved or low-trust attachment sightings before exporting data to the default topology read model.

#### Scenario: Unresolved topology sightings are quarantined
- **GIVEN** topology ingestion receives a relation whose endpoint identity is unresolved, null-neighbored, or represented only by a topology-sighting fragment
- **WHEN** the canonical topology read model is produced for the default God-View backbone
- **THEN** that relation SHALL NOT be exported as a first-class backbone peer relation
- **AND** the unresolved identity SHALL be preserved only in diagnostics or attachment-detail data until it is promotable

#### Scenario: Duplicate identity fragments do not create multiple backbone peers
- **GIVEN** discovery data contains multiple identity fragments that resolve to the same effective device or management IP
- **WHEN** the canonical topology read model is built
- **THEN** the system SHALL avoid exporting those fragments as separate backbone peers
- **AND** it SHALL surface an identity-collision quality signal for reconciliation

### Requirement: Endpoint attachments are exported as bounded attachment census data
The topology discovery and projection pipeline SHALL preserve endpoint attachment evidence for operator drill-down without requiring the default topology graph to render every attachment as a peer node.

#### Scenario: Dense endpoint fanout becomes anchored summary data
- **GIVEN** an access or edge infrastructure device has many downstream endpoint attachments
- **WHEN** the default topology read model is exported
- **THEN** the pipeline SHALL emit anchored attachment summary data for that device
- **AND** the default backbone export SHALL remain bounded regardless of the raw endpoint count

#### Scenario: Endpoint detail is available on demand
- **GIVEN** endpoint attachment evidence exists for a backbone anchor
- **WHEN** an operator requests attachment drill-down for that anchor
- **THEN** the pipeline SHALL provide a bounded endpoint neighborhood payload for that anchor
- **AND** that payload SHALL retain enough identity and evidence metadata for diagnostics

### Requirement: Topology quality regressions are surfaced explicitly
The topology discovery and projection pipeline SHALL emit explicit quality counters for conditions that would otherwise pollute topology readability or trust.

#### Scenario: Quality counters include unresolved and dropped attachment conditions
- **GIVEN** topology ingestion processes raw discovery relations
- **WHEN** the read model is exported
- **THEN** the pipeline SHALL report counts for unresolved identities, null-neighbor relations, duplicate identity collisions, and dropped attachment rows
- **AND** those counters SHALL be available to the God-View pipeline and operator diagnostics
