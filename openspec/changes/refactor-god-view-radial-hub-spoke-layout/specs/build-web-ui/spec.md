## ADDED Requirements
### Requirement: Default God-View overview uses deterministic radial hub-and-spoke layout
The default God-View topology overview SHALL render infrastructure transport topology as a deterministic radial hub-and-spoke layout centered on a bounded, infrastructure-derived hub/root.

#### Scenario: Infrastructure overview centers on a deterministic hub
- **GIVEN** a topology snapshot containing a core transport node, multiple infrastructure peers, and endpoint fanout
- **WHEN** the default overview layout is computed
- **THEN** the system SHALL select the same infrastructure hub/root for identical topology inputs
- **AND** infrastructure peers SHALL be placed in radial depth tiers around that hub instead of arbitrary layered or ring fallback placement

#### Scenario: Endpoint fanout does not replace the overview layout family
- **GIVEN** a topology snapshot containing endpoint-summary or endpoint-member nodes
- **WHEN** the default overview layout is computed
- **THEN** the presence of those endpoint nodes SHALL NOT switch the overview into a different primary layout regime
- **AND** the overview SHALL remain a radial hub-and-spoke infrastructure layout

### Requirement: Backbone coordinate solving ignores non-backbone relations
The default God-View backbone coordinate solve SHALL use only promotable infrastructure transport relations; endpoint-attachment and diagnostic-only relations SHALL NOT influence backbone coordinates.

#### Scenario: Endpoint attachments do not distort backbone placement
- **GIVEN** a topology snapshot where one access node has large endpoint fanout
- **WHEN** the default overview layout is computed
- **THEN** endpoint-attachment edges SHALL NOT alter hub selection or backbone tier placement
- **AND** the backbone SHALL remain readable regardless of endpoint count

#### Scenario: Diagnostic relations do not become backbone geometry drivers
- **GIVEN** a topology snapshot containing inferred, observed-only, or unresolved diagnostic relations
- **WHEN** the default overview layout is computed
- **THEN** those relations SHALL NOT drive backbone coordinates unless they are explicitly promoted into the infrastructure transport set

### Requirement: Endpoint expansion is a local anchored decoration
God-View SHALL render collapsed endpoint summaries and expanded endpoint members as anchored spoke decorations around their owning infrastructure node rather than as peers in the backbone layout solve.

#### Scenario: Expanding a cluster preserves backbone stability
- **GIVEN** a rendered topology overview with a collapsed endpoint cluster attached to an infrastructure node
- **WHEN** the operator expands that cluster
- **THEN** the backbone node positions SHALL remain stable
- **AND** the expanded members SHALL appear as bounded local spoke decorations around the owning anchor

#### Scenario: Expanded members do not trigger overview-scale relayout
- **GIVEN** a topology overview with a stable backbone arrangement
- **WHEN** endpoint members are added to or removed from one expanded cluster
- **THEN** the system SHALL limit geometry updates to that anchored neighborhood
- **AND** SHALL NOT recompute the entire overview as if the members were backbone peers

### Requirement: Default overview geometry is not post-distorted
The default God-View overview SHALL present the geometry produced by its chosen overview algorithm directly and SHALL NOT apply a secondary global distortion pass that changes the shape after layout.

#### Scenario: Overview geometry matches the selected layout algorithm
- **GIVEN** a topology overview layout result
- **WHEN** the graph is rendered
- **THEN** the visible node geometry SHALL correspond to the chosen overview placement algorithm
- **AND** the system SHALL NOT apply a second global normalization pass that compresses one axis after placement
