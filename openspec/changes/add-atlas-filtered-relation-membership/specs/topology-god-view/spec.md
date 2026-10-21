## ADDED Requirements

### Requirement: Exact Filtered Atlas Relation Membership
The system SHALL preserve connections between matching canonical devices across Atlas zoom levels by projecting exact authorized relation counts into admitted edge rows, including partially matched aggregates, without inventing connections or attributing excluded traffic to the filter.

#### Scenario: Partial aggregate retains a matching connection
- **GIVEN** an aggregate represents matching and excluded devices
- **AND** a canonical relation joins a matching member to another matching device
- **WHEN** the renderer displays the aggregate under the same filter
- **THEN** the corresponding edge SHALL remain visible and pickable with its exact matching count
- **AND** zoom refinement SHALL preserve that connection whenever its geometry is admitted

#### Scenario: Matching endpoint populations do not imply a connection
- **GIVEN** both endpoint aggregates contain matching devices
- **AND** every underlying relation has at least one endpoint excluded by the query
- **WHEN** membership is projected
- **THEN** the exact matching edge count SHALL be zero
- **AND** the edge SHALL remain invisible and unpickable

#### Scenario: Canonical clipped relation and ambiguous portal
- **GIVEN** multiple canonical relations cross a shared boundary portal
- **WHEN** both endpoints of one relation match the authorized query
- **THEN** exact edge projection SHALL count that relation using its canonical endpoints and admitted rendered row
- **AND** the portal SHALL remain invisible, unpickable and absent from device totals
- **AND** relations with unknown endpoint ordinals SHALL NOT count as matches

#### Scenario: Partial bundle traffic stays excluded
- **GIVEN** the exact matching relation count is positive but smaller than the geometry's full bundle count
- **WHEN** the existing telemetry overlay describes the full bundle
- **THEN** the structural edge SHALL remain visible
- **AND** full-bundle traffic rates and animation SHALL remain suppressed
- **AND** filtered picks and details SHALL describe only the authorized matching population

#### Scenario: Projection is complete within bounded work
- **WHEN** the server evaluates admitted filtered edge rows
- **THEN** it SHALL use one authorized query revision, canonical ordinal mapping and exact geometry receipts
- **AND** native traversal SHALL enforce candidate, memory and shared view-deadline bounds
- **AND** incomplete traversal, budget exhaustion, overflow or changed identity SHALL NOT publish partial counts as a complete replacement
- **AND** BEAM and the browser SHALL NOT enumerate whole-fleet relation objects

#### Scenario: Negotiated rolling compatibility
- **WHEN** both client and server support membership protocol 2
- **THEN** they SHALL bind that version into the view digest and exchange bounded row-aligned edge counts
- **AND** the client SHALL validate exact edge row counts and represented-population limits atomically with node membership
- **WHEN** either side supports only protocol 1
- **THEN** version-1 bytes and conservative partial-aggregate behavior SHALL remain supported

#### Scenario: Camera continuity retains one validated view
- **WHEN** pan or zoom changes only the admitted view
- **THEN** retained node and edge membership SHALL belong to the same last validated replacement
- **AND** the existing ten-second deadline SHALL cover geometry and membership delays without extension by later camera moves or old-view frames
- **WHEN** the query, dictionary, authority or reset invalidates that membership
- **THEN** retained node and edge membership SHALL clear together
