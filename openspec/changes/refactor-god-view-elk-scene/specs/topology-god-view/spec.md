## MODIFIED Requirements

### Requirement: Versioned Binary Topology Snapshots
The system SHALL stream topology snapshots for God-View using a versioned Arrow IPC payload contract and a required metadata envelope for deterministic client decoding.

The snapshot schema version `1` MUST use two record batches:
- `nodes` columns:
  - `node_index` (`u32`, required)
  - `node_id` (`utf8`, required)
  - `node_type` (`utf8`, required)
  - `x` (`f32`, required compatibility hint; non-authoritative for ELK scene geometry)
  - `y` (`f32`, required compatibility hint; non-authoritative for ELK scene geometry)
  - `z` (`f32`, optional; default `0`)
  - `status_code` (`u8`, required; enum-mapped)
  - `causal_class` (`u8`, required; enum-mapped to `root_cause|affected|healthy|unknown`)
  - `severity` (`u8`, optional)
  - `size` (`f32`, optional)
  - `color_rgba` (`fixed_size_binary[4]`, optional)
- `edges` columns:
  - `edge_index` (`u32`, required)
  - `edge_id` (`utf8`, required)
  - `source_index` (`u32`, required; references `nodes.node_index`)
  - `target_index` (`u32`, required; references `nodes.node_index`)
  - `edge_type` (`utf8`, required)
  - `weight` (`f32`, optional)
  - `status_code` (`u8`, optional)
  - `color_rgba` (`fixed_size_binary[4]`, optional)

The metadata envelope MUST be included with each snapshot revision and MUST include:
- `schema_version` (integer, required)
- `snapshot_revision` (monotonic integer, required)
- `generated_at` (RFC3339 timestamp, required)
- `graph_id` (string, required)
- `node_count` and `edge_count` (integer, required)
- `bitmap_version` (integer, required)
- `bitmap_offsets` (object/map, required)
- `flags` (object/map, optional; includes renderer/runtime hints)

Backend `x`, `y`, or equivalent coordinate fields SHALL NOT be authoritative for the ELK scene path. The frontend SHALL derive every accepted visible coordinate and route from the bounded semantic graph through its single ELK geometry authority.

#### Scenario: Client accepts supported snapshot schema
- **GIVEN** the server emits a topology snapshot with a supported schema version
- **WHEN** the God-View client receives the payload
- **THEN** the client decodes nodes and edges without JSON transformation
- **AND** the client renders the decoded snapshot revision

#### Scenario: Client handles unsupported snapshot schema
- **GIVEN** the server emits a topology snapshot with an unsupported schema version
- **WHEN** the God-View client receives the payload
- **THEN** the client rejects that snapshot revision
- **AND** the UI displays a recoverable compatibility error state

#### Scenario: Client validates required metadata envelope fields
- **GIVEN** the server emits a snapshot revision
- **WHEN** the client validates envelope metadata
- **THEN** missing required fields cause the revision to be rejected
- **AND** the previous accepted revision remains active

#### Scenario: Client validates required columns for schema version 1
- **GIVEN** the server emits schema version `1`
- **WHEN** the client validates record batch columns
- **THEN** missing required node or edge columns cause the revision to be rejected
- **AND** optional columns may be absent without failing decode

#### Scenario: Legacy coordinate hints do not become a second authority
- **GIVEN** a supported snapshot contains finite `x` and `y` compatibility hints
- **WHEN** the ELK scene path lays out the bounded visible graph
- **THEN** the client SHALL NOT apply those hints as accepted node positions
- **AND** all accepted coordinates and routes SHALL come from the decoded ELK result

### Requirement: Structural Reshape Contract
The system SHALL distinguish visual-only filter toggles from structural reshape actions, and SHALL require backend recomputation of bounded topology membership and relationships for reshape operations that change the visible topology.

#### Scenario: Visual-only filter action
- **WHEN** the operator hides or highlights a class of nodes without changing graph structure
- **THEN** the client applies the change locally from loaded snapshot data

#### Scenario: Structural reshape action
- **WHEN** the operator triggers a collapse or expand operation that changes graph membership
- **THEN** the backend SHALL recompute the bounded visible node and relationship membership
- **AND** the server SHALL emit a new snapshot revision
- **AND** the frontend SHALL compute all accepted coordinates and routes through the single ELK scene path

## ADDED Requirements

### Requirement: ELK is the single visible topology geometry authority
The God-View client SHALL produce the complete bounded visible topology scene through one compound ELK layout invocation. It SHALL NOT apply a second backbone, satellite, endpoint-cluster, route, fallback, or backend-coordinate projection pass to the accepted result.

Managed visual density SHALL remain presentation-only state. It MAY change fixed-pixel glyph radii, rendered route widths, and label candidate budgets, but it SHALL NOT change the semantic graph, ELK input geometry, accepted node/group coordinates, or accepted route points.

#### Scenario: Collapsed topology uses one layout authority
- **GIVEN** a bounded snapshot with infrastructure nodes and collapsed endpoint summaries
- **WHEN** the client computes topology geometry
- **THEN** every layout node and rendered relation SHALL be represented in one ELK input graph
- **AND** the accepted node positions and relation routes SHALL come from the decoded result of that invocation

#### Scenario: Expansion does not trigger post-layout projection
- **GIVEN** a valid scene with one or more collapsed endpoint clusters
- **WHEN** the operator expands a cluster
- **THEN** the client SHALL compute the complete new bounded graph through the same compound ELK path
- **AND** it SHALL NOT move expanded members or their anchor in a separate radial, spiral, lane, or grid pass

#### Scenario: Layout failure reuses only an exactly compatible scene
- **GIVEN** the last known good scene has the same structural graph identity, expansion set, and viewport profile as the requested scene
- **WHEN** ELK fails or returns invalid geometry
- **THEN** the client SHALL preserve that last known good scene
- **AND** it SHALL expose a layout diagnostic

#### Scenario: Layout fails without a compatible scene
- **GIVEN** no last known good scene matches the requested structural graph identity, expansion set, and viewport profile
- **WHEN** ELK fails or returns invalid geometry
- **THEN** the surface SHALL show a recoverable layout error
- **AND** it SHALL NOT invent geometry with a radial, spiral, lane, grid, fallback, or backend coordinate path

#### Scenario: Presentation density reuses the accepted scene
- **GIVEN** an accepted ELK scene and a camera scale that requires a different managed visual density
- **WHEN** the renderer changes glyph, route, or label presentation extents
- **THEN** normalized node, group, and route geometry SHALL remain unchanged
- **AND** the client SHALL NOT invoke ELK or a post-layout packing pass solely for the density change

### Requirement: Expanded endpoint clusters are compound layout groups
The God-View client SHALL represent each expanded endpoint cluster as a compound layout group allocated together with the rest of the bounded graph. Every member SHALL be contained by its group, and non-nested node and group boxes SHALL NOT overlap.

A visible collapsed summary SHALL reserve its conservative `448x448` world-unit ELK envelope. When expanded, the same non-rendered gateway SHALL reserve the named `112x112` world-unit outer envelope appropriate to routing and packing rather than retaining the visible-summary envelope.

Each rendered or layout-only relation SHALL be owned by the lowest common ELK compound containing both endpoints. A relation whose endpoints belong to the same expanded group SHALL be group-owned; only a relation that crosses compound boundaries SHALL be root-owned.

#### Scenario: Expanded members remain inside their group
- **GIVEN** an endpoint cluster with bounded visible membership
- **WHEN** the cluster is expanded
- **THEN** every expanded member node SHALL be a child of exactly one compound group
- **AND** every member layout box SHALL be contained within that group's padded bounds

#### Scenario: Concurrent expanded groups remain separated
- **GIVEN** two or more endpoint clusters are expanded concurrently
- **WHEN** the compound scene is laid out
- **THEN** their group bounds SHALL NOT overlap each other
- **AND** neither group SHALL overlap a nonmember infrastructure node

#### Scenario: Expansion preserves one rendered transport trunk
- **GIVEN** a collapsed endpoint cluster is connected to an infrastructure anchor by one rendered trunk
- **WHEN** the cluster expands to show bounded member nodes
- **THEN** the summary SHALL act as a non-rendered gateway inside the compound group
- **AND** the scene SHALL retain one rendered anchor-to-group trunk
- **AND** layout-only member constraints SHALL NOT create a rendered fan of duplicate trunks

#### Scenario: Compound-local relations use their lowest common owner
- **GIVEN** an expanded group containing two relation endpoints
- **WHEN** the client builds the compound ELK graph
- **THEN** that rendered or layout-only relation SHALL be stored on the group owner exactly once
- **AND** it SHALL NOT be duplicated on the root edge array
- **AND** relations crossing group boundaries SHALL remain root-owned

### Requirement: Rendered relations are canonicalized before ELK
The God-View client SHALL collapse semantic relations into stable rendered-route entities before building the ELK graph. Each rendered entity SHALL have one canonical direction, one stable ELK edge identifier, and a sorted list of contributing semantic relation identifiers.

#### Scenario: Semantic relations collapse before layout
- **GIVEN** multiple semantic attachment relations map to one visible cluster trunk
- **WHEN** the client prepares the ELK graph
- **THEN** ELK SHALL receive exactly one rendered edge for that trunk
- **AND** that edge SHALL retain a sorted list of all contributing semantic relation identifiers

#### Scenario: Input order does not choose route direction
- **GIVEN** the same semantic relations arrive in a different array order
- **WHEN** rendered entities are canonicalized
- **THEN** their edge identifiers, direction, and contributing relation order SHALL remain unchanged

### Requirement: Visible topology relations use validated routed geometry
Every rendered relation SHALL use the ordered path returned by the accepted ELK scene. It SHALL decode from exactly one continuous section with at least two distinct points and SHALL NOT positively intersect the open padded interior of a nonincident node or compound group in supported managed views.

A compound group is incident when either route endpoint is the group or one of its descendants. Layout-only constraints are excluded from rendered-route assertions, and boundary tangency within the configured epsilon is allowed.

The rendered path SHALL expose a finite positive effective stroke width to acceptance instrumentation and SHALL use rounded joints so screen-space clearance checks bound the visible mantle and crust at bends.

#### Scenario: Routed relation avoids unrelated geometry
- **GIVEN** a visible relation whose direct source-to-target chord would cross an unrelated node or endpoint group
- **WHEN** the scene is decoded and rendered
- **THEN** the visible stroke SHALL follow the validated ELK route points around that unrelated geometry
- **AND** no direct line or arc for the same relation SHALL be drawn over the routed stroke

#### Scenario: Invalid rendered section rejects the scene
- **GIVEN** ELK returns zero, multiple, branching, discontinuous, or degenerate sections for a rendered relation
- **WHEN** the client validates the decoded scene
- **THEN** it SHALL reject that scene
- **AND** it SHALL follow the compatible-last-good or recoverable-error behavior

#### Scenario: Routed interaction geometry matches the visible stroke
- **GIVEN** a rendered route is selected or hovered
- **WHEN** deck.gl evaluates its interaction geometry
- **THEN** hit testing and emphasis SHALL use the same decoded point path as the visible route

### Requirement: God-View labels are decluttered in screen space
After applying configured zoom-tier candidate budgets, the God-View renderer SHALL admit node labels through deterministic screen-space collision checks against higher-priority labels, non-owning protected glyph boxes, routed stroke corridors, and measured interface safe areas. Edge labels SHALL remain suppressed in the shared overview.

#### Scenario: Overview labels remain legible
- **GIVEN** a managed topology view with more label candidates than can be displayed without collision
- **WHEN** the renderer evaluates deterministic candidate anchors
- **THEN** admitted labels SHALL NOT overlap each other, non-owning glyphs, routed strokes, or interface safe areas
- **AND** lower-priority labels SHALL be omitted deterministically

#### Scenario: Selected label wins when a safe candidate exists
- **GIVEN** a selected or focused label conflicts with a lower-priority label
- **AND** at least one candidate position avoids fixed interface chrome
- **WHEN** label admission is recomputed
- **THEN** the selected or focused label SHALL remain visible
- **AND** lower-priority conflicting labels SHALL be evicted

#### Scenario: Selected identity remains available when canvas placement is impossible
- **GIVEN** every candidate position for a selected label intersects fixed interface chrome
- **WHEN** label admission is recomputed
- **THEN** the canvas SHALL omit the colliding label
- **AND** the selected identity SHALL remain visible in the details surface

#### Scenario: Camera movement does not rerun topology layout
- **GIVEN** an accepted topology scene
- **WHEN** pan or zoom changes screen-space label collisions without changing graph structure or viewport profile
- **THEN** the renderer SHALL recompute label admission from the existing scene
- **AND** it SHALL NOT invoke ELK solely because the camera moved

### Requirement: Managed camera operations use complete visual bounds
God-View initial view and Fit SHALL contain the complete visual scene inside the measured safe viewport. Focus SHALL contain the selected neighborhood's complete visual bounds. Both SHALL account for relevant nodes, compound groups, routed edges, glyph extents, admitted labels, and interface safe areas through one coordinate convention.

Managed views SHALL prefer the detail presentation when it is feasible. When detail is infeasible but overview is feasible, overview SHALL cap ordinary and expanded-member outer radii at `10` CSS pixels, collapsed-summary outer radii at `20` CSS pixels, endpoint-anchor outer radii at `12` CSS pixels, and rendered route widths at `10` CSS pixels. Detail rendered route widths SHALL be capped at `12` CSS pixels.

#### Scenario: Fit avoids controls and status chrome
- **GIVEN** a scene whose content extends toward the control panel or status strip
- **WHEN** the operator invokes Fit
- **THEN** the complete visual scene SHALL fit inside the measured safe rectangle
- **AND** no admitted node glyph or label SHALL be clipped by the canvas edge, control panel, or status strip

#### Scenario: Focus frames one complete selected neighborhood
- **GIVEN** one or more endpoint groups remain expanded
- **WHEN** the operator selects or expands a group while the camera is not user-locked
- **THEN** focus SHALL frame that group's compound bounds, anchor, trunk, glyphs, and admitted neighborhood labels
- **AND** it SHALL NOT collapse other expanded groups

#### Scenario: User-locked camera survives expansion
- **GIVEN** the operator has manually locked the camera through pan or zoom
- **WHEN** an endpoint group expands
- **THEN** the existing camera state SHALL be preserved
- **AND** Fit SHALL remain available to frame the complete updated scene

#### Scenario: Managed camera states keep glyphs separated
- **GIVEN** fixed-pixel node glyphs in a bounded accepted scene
- **WHEN** the client computes initial view, Fit, or focus
- **THEN** projected glyph boxes SHALL NOT overlap each other within browser tolerance
- **AND** members that cannot fit at the minimum supported managed-view scale SHALL remain summarized by the configured upstream budget

#### Scenario: Portrait managed view selects a feasible presentation contract
- **GIVEN** one accepted portrait-profile ELK scene whose fixed-pixel detail extents cannot fit without collision
- **WHEN** the client computes initial view, Fit, focus, or a manual managed view
- **THEN** it SHALL select the first feasible detail-or-overview presentation contract
- **AND** overview glyph and route extents SHALL obey the role-specific caps
- **AND** the accepted ELK nodes, groups, and route points SHALL remain unchanged

#### Scenario: Fit is bounded and idempotent
- **GIVEN** unchanged scene and viewport inputs
- **WHEN** Fit performs its provisional geometry fit, label admission, at most one label-aware refit, and final admission
- **THEN** all retained visual content SHALL be inside the safe rectangle
- **AND** invoking Fit again SHALL return the same view state and label set within tolerance

#### Scenario: Viewport profile changes deterministically
- **GIVEN** a valid scene in one quantized viewport profile
- **WHEN** the usable viewport crosses the configured profile threshold
- **THEN** the client MAY recompute the scene once with the new ELK direction and profile
- **AND** repeated sizes within one profile SHALL NOT cause layout churn

#### Scenario: Collapse and re-expand are stable
- **GIVEN** the same snapshot semantics, viewport profile, and endpoint expansion set
- **WHEN** the operator collapses and re-expands the same cluster without other structural changes
- **THEN** node, group, and route geometry SHALL return to the same scene within the configured numeric tolerance

### Requirement: Dense-layout fixtures enforce semantic and geometric invariants
The God-View test suite SHALL include sanitized paired collapsed and expanded fixtures representative of the farm01 regression. Each fixture SHALL declare expected decoded graph counts, semantic relation-class counts, rendered-glyph counts, rendered-route counts, visibility policy, aggregation policy, and expansion membership, then validate those semantics together with rendered geometry.

#### Scenario: Endpoint expansion preserves the route-collapse invariant
- **GIVEN** a collapsed fixture and its paired bounded expansion fixture
- **WHEN** the expansion adds its declared endpoint-member nodes and attachment-class semantic relations
- **THEN** decoded and rendered counts SHALL match the fixture manifest
- **AND** the rendered-route delta SHALL remain zero when member relations collapse into the existing cluster trunk

#### Scenario: Fixture geometry is collision-safe and deterministic
- **GIVEN** either paired fixture with a supported viewport profile
- **WHEN** input arrays are shuffled or the same layout is recomputed
- **THEN** node, group, and route geometry SHALL remain deterministic within tolerance
- **AND** no non-nested boxes SHALL overlap
- **AND** no rendered route SHALL positively intersect a nonincident padded node or group interior

#### Scenario: Browser acceptance uses production rendering conditions
- **GIVEN** the paired fixtures are loaded through the Bazel-owned God-View browser harness
- **WHEN** collapsed, expanded, concurrent-expansion, Fit, focus, and resize interactions run with pinned browser, viewport, DPR, font, and animation settings
- **THEN** exported geometry invariants SHALL pass
- **AND** screenshot and trace artifacts SHALL be retained for human review
