## ADDED Requirements
### Requirement: God-View default topology is a bounded backbone projection
The God-View default topology canvas SHALL render a bounded, infrastructure-first backbone projection rather than an unbounded graph of every discovered relation.

#### Scenario: Dense endpoint environments remain bounded
- **GIVEN** topology source data contains infrastructure devices plus many endpoint attachments
- **WHEN** an operator opens the default God-View surface
- **THEN** the surface SHALL render the transport backbone and anchored endpoint summary affordances
- **AND** it SHALL NOT attempt to render every endpoint attachment as a first-class default graph node

#### Scenario: Unresolved topology sightings do not appear as backbone peers
- **GIVEN** the topology source includes unresolved `sr:*` identities, null-neighbor rows, or duplicate identity fragments
- **WHEN** the default God-View backbone snapshot is rendered
- **THEN** those identities SHALL NOT appear as first-class infrastructure peers in the default graph
- **AND** the surface SHALL instead expose them through diagnostics or attachment-detail workflows

### Requirement: God-View geometry has a single frontend authority
The God-View frontend SHALL be the only authority for visible topology geometry, and the system SHALL NOT combine backend-authored layout with additional frontend backbone or endpoint projection passes.

#### Scenario: Backbone geometry is computed once in the frontend
- **GIVEN** a God-View snapshot includes bounded backbone topology and the metadata required for layout
- **WHEN** the frontend renders that snapshot
- **THEN** it SHALL compute backbone geometry through the configured frontend layout path
- **AND** the system SHALL NOT apply any backend-authored backbone coordinates to that same visible graph

#### Scenario: Expanded neighborhoods do not trigger a second projection pass
- **GIVEN** an operator expands an endpoint summary or attachment neighborhood
- **WHEN** the expanded detail view is rendered
- **THEN** the frontend SHALL lay out that bounded visible set through the same single geometry authority used for the visible topology
- **AND** it SHALL NOT run an additional projection or post-layout expansion algorithm on top of the primary layout result

### Requirement: God-View bootstraps from HTTP snapshot before streaming
The God-View surface SHALL support reliable first paint by loading the latest HTTP snapshot before or while joining streaming updates.

#### Scenario: First load succeeds without waiting for a stream snapshot
- **GIVEN** the page exposes a latest-snapshot HTTP endpoint and a topology stream channel
- **WHEN** an operator opens the topology page
- **THEN** the UI SHALL request the latest HTTP snapshot for initial paint
- **AND** it SHALL render that snapshot even if no stream snapshot has arrived yet

#### Scenario: Stream disruption preserves the last good topology view
- **GIVEN** the topology page has already rendered a valid snapshot
- **WHEN** the stream disconnects or channel join fails
- **THEN** the UI SHALL preserve the last good snapshot on screen
- **AND** it SHALL retry streaming updates without blanking the surface

### Requirement: God-View enforces label and neighborhood density budgets
The God-View renderer SHALL enforce zoom-tier label budgets, suppress edge labels by default, and bound expanded endpoint neighborhoods so readability does not collapse under fanout.

#### Scenario: Zoomed-out view suppresses dense labels
- **GIVEN** a topology view with many visible nodes
- **WHEN** the operator is at a low or mid zoom tier
- **THEN** the renderer SHALL limit node labels to the configured priority budget
- **AND** it SHALL suppress edge labels unless the view is sufficiently focused

#### Scenario: Endpoint expansion exceeds visible budget
- **GIVEN** an anchor has more endpoint members than the configured visible neighborhood budget
- **WHEN** the operator expands that endpoint group
- **THEN** the UI SHALL render a bounded visible subset or a paged/summary drill-down
- **AND** it SHALL NOT draw an unbounded overlapping fan-out on the shared canvas

### Requirement: God-View distinguishes local health from evidence-backed impact
The God-View surface SHALL render `Affected` or equivalent impact states only when supported by qualifying causal evidence, and SHALL NOT infer a blast radius solely from graph proximity to an unhealthy node.

#### Scenario: Unhealthy nodes without causal evidence do not paint blast radius
- **GIVEN** one or more nodes are unhealthy from availability state alone
- **AND** no qualifying causal evidence path is present
- **WHEN** the topology surface renders status overlays
- **THEN** only the unhealthy or unknown local node state SHALL be shown
- **AND** neighboring nodes SHALL NOT be marked `Affected` solely because they are within a hop budget

#### Scenario: Evidence-backed impact path renders affected state
- **GIVEN** qualifying causal evidence identifies an impact path through the visible topology
- **WHEN** the topology surface renders status overlays
- **THEN** nodes on that evidence-backed path SHALL render as impacted
- **AND** the UI SHALL preserve operator-visible attribution for why those nodes are marked impacted
