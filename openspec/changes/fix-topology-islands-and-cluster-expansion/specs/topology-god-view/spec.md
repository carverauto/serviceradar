## ADDED Requirements

### Requirement: Concurrent Endpoint Cluster Expansion
Within an explicitly entered bounded ELK detail scene, the God-View topology surface SHALL allow operators to expand multiple endpoint clusters concurrently without silently collapsing previously expanded clusters. All expanded memberships together SHALL remain within that detail scene's node, relation, and byte budgets; map-wide expansion SHALL NOT grow an unbounded graph. The concurrent expansion limit MUST be configurable and MUST default to at least 3.

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
The God-View server world layout and bounded ELK detail layout SHALL place devices whose only connectivity is an endpoint attachment near their attachment anchor instead of placing them in unplaced residual lanes. Map coordinates SHALL be server-authored and persistent; ELK coordinates SHALL belong only to the explicitly entered detail scene.

#### Scenario: Attachment-only device renders near its anchor
- **GIVEN** a device whose only edges are attachment-plane rows referencing an anchor infrastructure node
- **WHEN** the server places the device in the world or the client lays out its bounded detail scene
- **THEN** the device SHALL remain in the anchor's connected layout neighborhood through the configured single geometry authority
- **AND** the device SHALL NOT be routed to unplaced residual lanes

### Requirement: Collision-Safe Endpoint Cluster Layout
Within a bounded ELK detail scene, the God-View client SHALL place expanded endpoint-cluster members through that scene's single geometry authority with deterministic membership containment, node separation, and routed-edge clearance.

#### Scenario: Expanded members form a collision-safe group
- **GIVEN** an endpoint cluster with N visible members expands
- **WHEN** the client lays out the expanded cluster
- **THEN** every member SHALL remain contained in the cluster's allocated layout neighborhood
- **AND** no two member node boxes SHALL overlap

#### Scenario: Expanded group avoids unrelated geometry
- **GIVEN** an endpoint cluster expands near unrelated topology nodes or groups
- **WHEN** the configured geometry authority lays out and routes the visible graph
- **THEN** the expanded group SHALL NOT overlap unrelated node or group boxes
- **AND** its rendered trunk SHALL NOT pass through a nonincident node or group interior

#### Scenario: Degenerate small clusters
- **WHEN** an expanded cluster has fewer than 3 visible members
- **THEN** the configured geometry authority SHALL use the same layout contract as for larger clusters
- **AND** the result SHALL remain free of node overlap
