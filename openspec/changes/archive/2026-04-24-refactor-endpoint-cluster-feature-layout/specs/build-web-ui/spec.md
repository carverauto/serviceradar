## ADDED Requirements
### Requirement: Endpoint cluster layout is backend-authored and feature-aware
The God-View topology pipeline SHALL compute endpoint cluster geometry on the backend as a topological feature with an explicit footprint. The primary backbone layout SHALL be computed from structural topology links before endpoint cluster projection is applied. Collapsed endpoint groups SHALL render as compact summary clusters that preserve backbone readability, and expanded endpoint groups SHALL render within a deterministic anchored fan/sector layout that reserves enough area to avoid local overlap with nearby nodes and backbone edges.

#### Scenario: Collapsed endpoint cluster preserves backbone layout
- **GIVEN** a topology payload contains infrastructure backbone links and one or more endpoint attachment groups
- **WHEN** the backend computes topology coordinates for the collapsed endpoint view
- **THEN** endpoint groups SHALL be represented as compact summary clusters
- **AND** the backbone infrastructure layout SHALL remain the primary structural geometry rather than collapsing into a vertical or high-fanout stack because of endpoint attachments

#### Scenario: Endpoint attachments do not drive structural backbone layout
- **GIVEN** a topology contains direct backbone links and dense endpoint attachment edges
- **WHEN** the backend computes the primary layout for the topology
- **THEN** endpoint attachment edges SHALL NOT be part of the structural backbone layout input
- **AND** endpoint cluster projection SHALL occur only after the backbone coordinates are established

#### Scenario: Expanded endpoint cluster fans out from its anchor
- **GIVEN** an operator expands an endpoint cluster attached to an infrastructure node
- **WHEN** the backend emits coordinates for the expanded cluster
- **THEN** endpoint member nodes SHALL occupy a directed fan or sector anchored to that infrastructure node
- **AND** member attachment edges SHALL be distributed across that fan instead of collapsing into a single radial plane or near-collinear bundle

#### Scenario: Expanded endpoint cluster avoids nearby backbone geometry
- **GIVEN** an expanded endpoint cluster is adjacent to other infrastructure nodes or backbone edges
- **WHEN** the backend selects the cluster orientation
- **THEN** it SHALL choose a deterministic sector placement that minimizes overlap and local crossing against nearby topology
- **AND** the emitted cluster footprint SHALL reserve enough space that member nodes and edges do not visibly overlap neighboring backbone geometry in normal rendering

#### Scenario: Post-projection cleanup preserves cluster feature geometry
- **GIVEN** the backend has projected an expanded endpoint cluster with a reserved footprint
- **WHEN** the final collision or proximity cleanup phase runs
- **THEN** the cleanup SHALL preserve the expanded cluster as a coherent feature envelope
- **AND** it SHALL NOT collapse the fan back into a flat, near-collinear, or visibly tangled bundle solely by resolving per-node point collisions

#### Scenario: Endpoint cluster geometry is deterministic for unchanged topology
- **GIVEN** identical topology structure, endpoint membership, and node-role inputs for the same topology revision
- **WHEN** the backend computes endpoint cluster coordinates multiple times
- **THEN** collapsed and expanded endpoint cluster orientation and member placement SHALL be stable across runs
- **AND** frontend expand/collapse rendering SHALL consume those backend coordinates without applying client-side re-layout

### Requirement: Endpoint cluster expansion state is explicit and reversible
The God-View topology pipeline and UI SHALL treat endpoint cluster expansion as explicit rendered topology state. Expansion state SHALL participate in snapshot identity, and operators SHALL have a reliable way to collapse expanded endpoint clusters without guessing hidden controls.

#### Scenario: Expanded and collapsed cluster states produce distinct snapshot identity
- **GIVEN** the same underlying topology structure and causal state
- **WHEN** an endpoint cluster changes from collapsed to expanded or from expanded to collapsed
- **THEN** the backend snapshot identity SHALL change to reflect that rendered topology state transition
- **AND** the streaming client SHALL NOT discard that update as an unchanged revision

#### Scenario: Operator can collapse an expanded endpoint cluster explicitly
- **GIVEN** an operator has expanded an endpoint cluster
- **WHEN** they use the provided collapse interaction for that cluster
- **THEN** the system SHALL return the cluster to its collapsed summary state
- **AND** the resulting snapshot SHALL preserve backbone readability and deterministic collapsed placement

#### Scenario: Reset returns the topology view to a collapsed recoverable state
- **GIVEN** one or more endpoint clusters are expanded in the topology view
- **WHEN** the operator triggers the view reset control
- **THEN** the system SHALL provide a deterministic path back to the collapsed topology state before or while re-fitting the camera
- **AND** the operator SHALL not be left in an expanded-cluster state without an obvious way to undo it
