## ADDED Requirements

### Requirement: Concurrent Endpoint Cluster Expansion
The God-View topology surface SHALL allow operators to expand multiple endpoint clusters concurrently without silently collapsing previously expanded clusters. The concurrent expansion limit MUST be configurable and MUST default to at least 3.

#### Scenario: Second cluster expands while first stays open
- **GIVEN** endpoint cluster A is expanded
- **WHEN** the operator expands cluster B
- **THEN** both A and B SHALL render their expanded member neighborhoods in the same snapshot revision

#### Scenario: Expansion limit enforced deterministically
- **GIVEN** the number of expanded clusters reaches the configured limit
- **WHEN** the operator expands an additional cluster
- **THEN** the oldest expansion SHALL collapse
- **AND** the remaining expansions SHALL stay open and stable across subsequent snapshot revisions

### Requirement: Connectivity-Anchored Placement
The God-View layout SHALL place devices whose only connectivity is an endpoint attachment adjacent to their attachment anchor instead of placing them in unplaced residual lanes.

#### Scenario: Attachment-only device renders near its anchor
- **GIVEN** a device whose only edges are attachment-plane rows referencing an anchor infrastructure node
- **WHEN** the client lays out the snapshot
- **THEN** the device SHALL be positioned on a ring or spiral around that anchor
- **AND** the device SHALL NOT be routed to unplaced residual lanes

### Requirement: Spiral Endpoint Cluster Layout
The God-View client SHALL place expanded endpoint-cluster members in a collision-free spiral arrangement around the anchor, ordered by member grouping, selecting placement by scoring node overlap and edge crossings.

#### Scenario: Expanded members form a collision-free spiral
- **GIVEN** an endpoint cluster with N visible members expands
- **WHEN** the client lays out the expanded cluster
- **THEN** members SHALL be arranged on a spiral path around the anchor with no two member nodes overlapping

#### Scenario: Placement minimizes overlap and crossings
- **GIVEN** multiple candidate placements exist for an expanded cluster
- **WHEN** the client selects a placement
- **THEN** it SHALL score candidates by member-node overlap count and intersections between member edges and unrelated edges
- **AND** the placement with the lowest score SHALL be selected

#### Scenario: Degenerate small clusters
- **WHEN** an expanded cluster has fewer than 3 visible members
- **THEN** the client MAY use the linear fallback arrangement
- **AND** the result SHALL still be free of node overlap
