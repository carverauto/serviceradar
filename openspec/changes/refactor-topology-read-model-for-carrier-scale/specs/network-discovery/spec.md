## ADDED Requirements
### Requirement: Canonical atlas acquisition uses bounded consistent source pages
The topology read model SHALL acquire Dgraph Device vertices and admitted topology-view relations through bounded pages in one read-only transaction. The view SHALL include the canonical backbone plus fresh, non-stale `ATTACHED_TO`, `INFERRED_TO` and `HOSTED_ON` evidence already admitted by projection, preserving relation kind and evidence class. Canonical telemetry eligibility SHALL survive persistence; non-canonical view relations and old rows without eligibility SHALL remain telemetry-ineligible. The canonical graph API used by traversal consumers SHALL remain backbone-only. Source acquisition SHALL enforce transport limits independently of the tile and bounded-detail budgets used for inventory enrichment and client delivery.

#### Scenario: Canonical source exceeds one transport response
- **GIVEN** the complete canonical vertex or relation set exceeds one permitted gRPC response
- **WHEN** the atlas refresh reads the source
- **THEN** it SHALL retrieve UID-ordered pages with a validated advancing cursor
- **AND** all vertex and relation pages SHALL use the same Dgraph read timestamp
- **AND** the complete source SHALL be assembled before a replacement atlas index is published

#### Scenario: A later source page cannot be accepted
- **GIVEN** earlier pages were read successfully
- **WHEN** a later page fails, has a malformed or non-advancing cursor, has missing required response fields, wrong field types, an invalid snapshot timestamp, or cannot fit the transport limit even as a single row
- **THEN** the refresh SHALL fail without publishing a partial source
- **AND** the last successfully published atlas index SHALL remain available

#### Scenario: Existing domain admission still advances raw source pages
- **GIVEN** a successfully decoded raw relation page contains only orphan or no-identity endpoint rows excluded by the existing canonical admission converter
- **WHEN** the reader processes that page
- **THEN** those rows SHALL remain excluded under the existing domain rule
- **AND** their raw row count and last UID SHALL still control pagination so later admitted relations remain reachable
- **AND** domain exclusion SHALL NOT be confused with a malformed wire response or claimed as new quarantine diagnostics

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
- **AND** it SHALL select only the requested stable member page before inventory enrichment and encoding
- **AND** continuation metadata SHALL keep every omitted member reachable without embedding the full member list

#### Scenario: Attachment telemetry does not change geometry identity
- **GIVEN** attachment membership remains unchanged while telemetry values change
- **WHEN** the read model publishes a telemetry overlay or refreshes bounded detail content
- **THEN** the attachment aggregate, member-detail, and parent identifiers SHALL remain stable
- **AND** the detail structural signature and geometry tile revisions SHALL remain unchanged

### Requirement: Topology quality regressions are surfaced explicitly
The topology discovery and projection pipeline SHALL emit explicit quality counters for conditions that would otherwise pollute topology readability or trust.

#### Scenario: Quality counters include unresolved and dropped attachment conditions
- **GIVEN** topology ingestion processes raw discovery relations
- **WHEN** the read model is exported
- **THEN** the pipeline SHALL report counts for unresolved identities, null-neighbor relations, duplicate identity collisions, and dropped attachment rows
- **AND** those counters SHALL be available to the God-View pipeline and operator diagnostics
