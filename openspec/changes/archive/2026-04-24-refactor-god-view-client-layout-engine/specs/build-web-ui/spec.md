## ADDED Requirements
### Requirement: God-View visible topology layout is client-computed from backend semantics
The God-View UI SHALL compute visible topology coordinates on the client from backend-provided topology semantics. The backend SHALL remain authoritative for topology membership, stable identity, edge classification, and cluster expansion state, but the client SHALL own the final node positions used for rendering the visible graph.

#### Scenario: Visible topology layout is recomputed from topology semantics
- **GIVEN** a God-View snapshot includes topology nodes, edges, cluster metadata, and expansion state
- **WHEN** the client receives a new topology revision or a changed expansion state
- **THEN** the client SHALL build the visible graph for that state
- **AND** it SHALL compute the rendered node coordinates from that visible graph before drawing with deck.gl

#### Scenario: Layout cache is keyed by topology revision and expansion state
- **GIVEN** a God-View topology revision and a specific set of expanded endpoint clusters
- **WHEN** the same revision and expansion state are rendered again
- **THEN** the client MAY reuse the cached layout result
- **AND** it SHALL recompute layout when either the topology revision or the expansion state changes

### Requirement: God-View preserves Arrow, roaring bitmap, and deck.gl integration during layout migration
The God-View layout-engine migration SHALL preserve the existing compact transport and rendering stack. Arrow payload decoding, roaring bitmap driven state, and deck.gl rendering SHALL remain compatible while coordinate computation moves to the client.

#### Scenario: Arrow transport remains the topology payload source
- **GIVEN** a God-View snapshot transport path using Arrow-backed topology payloads
- **WHEN** client-side layout is enabled
- **THEN** the client SHALL continue decoding topology state from the Arrow payload
- **AND** layout computation SHALL operate on the decoded topology graph rather than requiring a new transport format

#### Scenario: Roaring bitmap state remains compatible with client layout
- **GIVEN** God-View uses roaring bitmap indexed state for selection, overlays, or visibility controls
- **WHEN** client-side layout computes new positions
- **THEN** those bitmap-driven states SHALL continue to target stable node and edge identities
- **AND** position recomputation SHALL NOT require replacing bitmap-based state handling

#### Scenario: deck.gl remains the renderer
- **GIVEN** God-View renders nodes and edges through deck.gl layers
- **WHEN** client-side layout is active
- **THEN** deck.gl SHALL continue to render the topology
- **AND** the renderer SHALL consume client-computed coordinates instead of backend-authored screen positions

### Requirement: God-View endpoint clusters render as readable client-layout features
Collapsed and expanded endpoint clusters SHALL be represented as client-layout features within the visible topology graph. Collapsed endpoint clusters SHALL remain compact summary nodes, and expanded endpoint clusters SHALL render as readable anchored fan or spiral structures that avoid obvious self-overlap and duplicate membership.

#### Scenario: Collapsed endpoint cluster remains compact
- **GIVEN** a topology contains one or more endpoint clusters in collapsed state
- **WHEN** the client computes the visible layout
- **THEN** each collapsed cluster SHALL render as a compact summary feature
- **AND** the backbone topology SHALL remain readable without large endpoint-driven distortion

#### Scenario: Expanded endpoint cluster fans or spirals out from its anchor
- **GIVEN** an operator expands an endpoint cluster attached to an infrastructure node
- **WHEN** the client computes the visible layout for that expanded state
- **THEN** endpoint members SHALL render in a readable anchored fan or spiral pattern
- **AND** member edges SHALL not collapse into a single flat stack or obvious self-overlap under normal rendering

#### Scenario: Endpoint membership is not duplicated across visible clusters
- **GIVEN** a topology graph contains attachment evidence for endpoint grouping
- **WHEN** the visible graph is constructed for client layout
- **THEN** each endpoint SHALL belong to at most one rendered visible cluster in a given snapshot state
- **AND** the UI SHALL NOT render duplicate copies of the same endpoint across multiple expanded or collapsed groups

#### Scenario: Reset collapses expanded endpoint clusters
- **GIVEN** one or more endpoint clusters are expanded in God-View
- **WHEN** the operator uses the reset or collapse control
- **THEN** the visible graph SHALL return to the collapsed-cluster state
- **AND** the client SHALL recompute the visible layout for that collapsed state instead of reusing stale expanded coordinates
