## MODIFIED Requirements

### Requirement: Versioned Binary Topology Snapshots
The system SHALL deliver God-View topology using the versioned schema-3 Arrow IPC contract and required metadata for deterministic typed-column decoding. Semantic atlas levels SHALL extend this contract rather than introduce a parallel graph format.

Each level SHALL use a single bounded record batch with `row_type` distinguishing node and edge rows. The schema SHALL preserve the typed node position/state/traffic columns, UInt32 `edge_source` and `edge_target` indices, directional edge telemetry columns, and `snapshot_schema_version` and `snapshot_revision` columns. Details SHALL be available through `node_detail_*`, `edge_detail_*`, and `edge_metadata_*` columns; `details_irregular` SHALL be decoded lazily when its details are requested rather than reconstructed for every row on interaction.

The batch schema metadata SHALL include `schema_version`, `revision`, `level_id`, and `parent_level_id`, together with level kind, structural signature, causal bitmap metadata, actual node and edge counts, applicable budgets, and bounded continuation information. A global root SHALL have no parent; every child level SHALL identify its parent. HTTP metadata and batch metadata SHALL agree. Edge endpoint indices and causal bitmap positions SHALL refer to the local returned node set, not the canonical graph.

Backend position columns SHALL remain non-authoritative compatibility hints for the ELK scene path. The frontend SHALL derive every accepted visible coordinate and route from the bounded semantic graph through its single selected geometry pipeline.

#### Scenario: Client accepts supported snapshot schema
- **GIVEN** the server emits a bounded schema-3 level
- **WHEN** the God-View client receives the payload
- **THEN** it SHALL decode node and edge columns into typed memory without reconstructing per-row detail objects
- **AND** it SHALL render the level identified by the batch metadata

#### Scenario: Client handles unsupported snapshot schema
- **GIVEN** the server emits an unsupported schema version
- **WHEN** the God-View client receives the payload
- **THEN** it SHALL reject the revision and display a recoverable compatibility error
- **AND** the previous accepted level SHALL remain active

#### Scenario: Client validates required level metadata
- **GIVEN** a level response lacks required metadata or disagrees with its HTTP envelope
- **WHEN** the client validates the response
- **THEN** it SHALL reject the response rather than cache it under a different level or revision
- **AND** the previous accepted level SHALL remain active

#### Scenario: Client validates required columns for schema version 3
- **GIVEN** the server emits schema version `3`
- **WHEN** the client validates the batch
- **THEN** missing required columns, incompatible typed endpoints, or out-of-range local node references SHALL cause rejection
- **AND** absent optional details SHALL NOT prevent typed-column decoding

#### Scenario: Lazy details do not replace columnar interaction paths
- **GIVEN** a level includes details columns and irregular detail content
- **WHEN** the operator filters, pans, zooms, hovers, or selects
- **THEN** the client SHALL retain the typed-column interaction path
- **AND** it SHALL decode only the requested irregular details

#### Scenario: Legacy coordinate hints do not become a second authority
- **GIVEN** a supported snapshot contains finite node position compatibility hints
- **WHEN** the selected ELK pipeline lays out the bounded level
- **THEN** the client SHALL NOT apply those hints as accepted node positions
- **AND** every accepted coordinate and route SHALL come from that pipeline's validated result

### Requirement: Structural Reshape Contract
The system SHALL distinguish visual-only filtering, navigation between bounded semantic levels, and changes to canonical topology. Level navigation SHALL request bounded membership from the backend without treating navigation itself as a canonical structural revision.

#### Scenario: Visual-only filter action
- **WHEN** the operator hides or highlights a class without changing graph structure
- **THEN** the client SHALL apply the change locally to the accepted bounded level
- **AND** a managed route SHALL render only when its visible endpoint contract remains satisfied
- **AND** a valid anchor-to-group trunk MAY remain when the compound-group contract resolves its non-rendered gateway

#### Scenario: Expansion or collapse navigates bounded levels
- **WHEN** the operator expands or collapses a summary
- **THEN** the client SHALL select the corresponding child or parent level at the compatible revision
- **AND** uncached membership SHALL arrive as one bounded HTTP level response
- **AND** the frontend SHALL compute accepted coordinates and routes through that level's single selected geometry pipeline
- **AND** returning to a compatible cached parent SHALL NOT require a fetch or canonical recomputation

#### Scenario: Canonical topology changes invalidate affected levels
- **WHEN** canonical membership or semantic relations change
- **THEN** the backend SHALL recompute affected level memberships and structural signatures
- **AND** it SHALL publish bounded revision invalidations for affected levels
- **AND** unrelated cached levels SHALL remain reusable when their signatures match

## ADDED Requirements

### Requirement: Semantic atlas levels are bounded at the server contract
God-View SHALL expose global, site or transport-component, infrastructure-neighborhood, and paged endpoint-membership levels. The server SHALL bound every response before inventory enrichment and encoding and SHALL NOT instruct the browser to lay out the complete canonical graph.

Each level SHALL carry stable `level_id`, `parent_level_id`, and `revision` metadata in the schema-3 Arrow batch. Aggregate identities SHALL derive from semantic membership or anchors rather than input order or telemetry. Local edge endpoints SHALL refer only to nodes present in that batch. The contract SHALL define node, relation, identity-label, member, and encoded-byte budgets; summaries and context count against those budgets.

#### Scenario: Large canonical graphs remain bounded on the wire
- **GIVEN** an independently invented canonical graph has at least 200,000 nodes and 400,000 relations
- **WHEN** the client requests any semantic level
- **THEN** the response SHALL contain exactly one bounded schema-3 Arrow batch
- **AND** actual node rows, relation rows, labels, members, and encoded bytes SHALL remain within the level's budgets
- **AND** the layout input SHALL contain only that bounded level

#### Scenario: Global and component overflow remain reachable
- **GIVEN** the global aggregate count or one transport component exceeds its level budget
- **WHEN** the server constructs the requested level
- **THEN** it SHALL summarize, subdivide, or page the excess using bounded continuation metadata
- **AND** every omitted aggregate or member SHALL remain reachable through level navigation
- **AND** no summary SHALL embed an unbounded member identity list

#### Scenario: Missing site metadata uses transport components
- **GIVEN** canonical infrastructure has no authoritative site metadata
- **WHEN** the server builds the global level
- **THEN** it SHALL group infrastructure by deterministic transport component
- **AND** equivalent reversed input arrays SHALL produce the same aggregate and level identifiers

### Requirement: Atlas levels use HTTP and channel invalidations
The authenticated topology HTTP endpoint SHALL return one schema-3 level for `level_id` and `revision`; the topology channel SHALL carry only bounded invalidations and small deltas, never complete graph or level payloads.

The existing `GET /topology/snapshot/latest` route SHALL default to the current global level when no level or revision is supplied. A request's `revision` SHALL identify that level's content, independently of its parent's revision and the atlas `canonical_revision`. An explicitly requested unavailable level revision SHALL return HTTP 409 and identify that level's current revision. Invalid parameters, unknown levels or out-of-range pages, and an unready atlas SHALL return HTTP 400, 404, and 503 respectively. A response SHALL NOT be cached under a different revision than its batch metadata.

#### Scenario: First paint does not depend on the channel
- **GIVEN** a global level is available over HTTP and channel delivery is delayed
- **WHEN** God-View opens
- **THEN** its first usable frame SHALL come from the HTTP global-level response
- **AND** no complete graph SHALL be delivered through the channel

#### Scenario: Drill-down requests only the selected level
- **GIVEN** an accepted parent level contains an aggregate with a child reference
- **WHEN** zoom or selection enters that aggregate without a cached or pending child
- **THEN** the client SHALL fetch exactly that child level, omitting `revision` on a first visit when its content revision is unknown
- **AND** it SHALL NOT use the parent's revision as the child's requested revision
- **AND** unrelated levels SHALL NOT be included in the response

#### Scenario: Stale revision is explicit
- **GIVEN** the client requests a revision the server no longer serves
- **WHEN** the level endpoint handles the request
- **THEN** it SHALL return HTTP 409 with the current revision
- **AND** the client SHALL retain its last compatible good scene while reconciling the revision

#### Scenario: Invalidation traffic remains bounded
- **GIVEN** a structural revision changes level membership or summary counts
- **WHEN** the server publishes `topology_invalidated` on `topology:god_view`
- **THEN** the message SHALL include `previous_canonical_revision`, `canonical_revision`, and only the affected level identifiers with bounded per-level revision hints
- **AND** an explicit reset marker SHALL replace an invalidation list that exceeds its configured budget
- **AND** the message SHALL NOT embed Arrow payloads or canonical node and relation collections

### Requirement: Level caches preserve compatible geometry and navigation
The client SHALL cache levels by `(revision, level_id, expansion state)` and SHALL distinguish a per-level content revision, a structural signature, and a canonical source revision. Layout identity SHALL include the level and selected algorithm. Prefetch, navigation, and invalidation SHALL preserve compatible cached geometry and parent camera state.

#### Scenario: Telemetry revisions preserve geometry
- **GIVEN** an accepted level receives updated traffic counters or local health without a membership change
- **WHEN** the content revision advances
- **THEN** level ids, aggregate ids, and structural signatures SHALL remain unchanged
- **AND** the client SHALL reuse the accepted geometry

#### Scenario: Structural invalidation preserves unrelated levels
- **GIVEN** a structural update affects one neighborhood and ancestors whose summaries change
- **WHEN** the invalidation is applied
- **THEN** only those affected levels SHALL be invalidated
- **AND** unaffected cached levels SHALL retain their content revisions and accepted scenes
- **AND** changed content with an unchanged structural signature SHALL reuse compatible geometry
- **AND** a response from an older canonical generation SHALL NOT replace a newer accepted level

#### Scenario: Hover prefetch and parent return reuse cached levels
- **GIVEN** the pointer enters an expandable aggregate
- **WHEN** its child is not already cached or being fetched
- **THEN** the client SHALL prefetch that bounded child and deduplicate repeated requests
- **AND** selecting the aggregate SHALL reuse the result
- **AND** zooming back out SHALL restore the compatible cached parent scene and camera without an HTTP fetch

### Requirement: Bounded atlas levels satisfy interactive performance budgets
God-View SHALL preserve the existing first-frame SLO and measure hover, selection, and filtering at the largest permitted level on a real WebGPU device with procedural packet flow enabled.

#### Scenario: Carrier-scale navigation remains interactive
- **GIVEN** an independently invented canonical graph is far larger than every level budget
- **WHEN** a real WebGPU browser opens the global level and interacts with the largest permitted level
- **THEN** the first usable frame SHALL arrive within 3 seconds
- **AND** hover and selection SHALL each complete in less than 100 milliseconds
- **AND** filtering SHALL complete in less than 300 milliseconds
- **AND** measured device limits, wire row/byte counts, and timings SHALL be recorded with packet flow enabled
- **AND** a SwiftShader-only run SHALL NOT satisfy the real-device acceptance gate

### Requirement: God-View overview uses a deterministic radial transport forest
The God-View overview SHALL construct a deterministic rooted forest from the bounded promotable topology and SHALL pass only that acyclic forest to ELK Radial. Forest roots, selected relations, relation orientation, and node order SHALL remain stable across equivalent input orderings.

#### Scenario: Cyclic topology becomes a stable overview forest
- **GIVEN** a bounded topology component contains redundant or cyclic semantic relations
- **WHEN** the overview projection is built
- **THEN** exactly one load-bearing tree path SHALL connect each non-root node to the component root
- **AND** excluded semantic relations SHALL remain identified as non-tree cross-links
- **AND** ELK Radial SHALL receive an acyclic input graph

#### Scenario: Equivalent input order preserves geometry identity
- **GIVEN** two snapshots contain identical nodes and semantic relations in different array orders
- **WHEN** their overview forests and layout cache identities are produced
- **THEN** both SHALL choose the same roots and tree relations
- **AND** both SHALL produce the same level and algorithm cache identity

### Requirement: Non-tree cross-links use bounded progressive disclosure
The overview SHALL preserve non-tree relation identity and counts without rendering every cross-link as an always-on route. A bounded focus view MAY reveal cross-links relevant to its selected component, node, or route.

#### Scenario: Overview summarizes redundant links
- **GIVEN** a component contains semantic relations excluded from its overview forest
- **WHEN** the overview renders that component
- **THEN** it SHALL expose the excluded cross-link count through component or selection metadata
- **AND** it SHALL NOT draw those relations as an always-on edge mesh

#### Scenario: Focus reveals relevant cross-links
- **GIVEN** an operator selects a bounded infrastructure neighborhood
- **WHEN** the focus level is requested
- **THEN** relevant non-tree relations SHALL retain their original semantic relation identifiers and metadata
- **AND** unrelated tenant-wide cross-links SHALL remain outside that bounded level

### Requirement: Atlas Fit always contains the current bounded level
Initial view and Fit SHALL contain every rendered glyph and route in the current bounded atlas level inside the measured safe viewport. Fixed-pixel separation constraints SHALL NOT make part of the level unreachable; the renderer SHALL reduce presentation density or change semantic level before applying a conflicting zoom floor.

#### Scenario: Fit shows the complete radial overview
- **GIVEN** a valid bounded radial overview larger than the current viewport
- **WHEN** the operator invokes Fit
- **THEN** every overview glyph and tree route SHALL be inside the safe viewport
- **AND** the camera SHALL NOT clamp above the scale required to contain that level

#### Scenario: Dense detail reduces membership before clipping
- **GIVEN** a focused endpoint neighborhood whose full member set cannot fit with self-identifying glyphs
- **WHEN** the focus level is laid out or fitted
- **THEN** the level SHALL page, sample, or aggregate members until the accepted visible set fits
- **AND** it SHALL NOT preserve an unreadable camera floor that hides part of the accepted level

### Requirement: Expanded endpoint groups are bounded focus levels
Expanding an endpoint summary SHALL enter or update a bounded focus level for that group rather than adding an unbounded member fanout to the global overview.

#### Scenario: Expansion preserves unrelated overview state
- **GIVEN** a valid overview and one expandable endpoint summary
- **WHEN** the operator expands that summary
- **THEN** the focused level SHALL retain the required anchor and transport context plus a bounded member set
- **AND** unrelated components SHALL NOT be relaid out as part of that expansion
- **AND** collapse SHALL restore the previous compatible overview scene and camera state

#### Scenario: Repeated expansion remains recoverable
- **GIVEN** the operator expands, collapses, and expands multiple endpoint groups
- **WHEN** any newly requested level fails layout or rendering
- **THEN** the last compatible good level SHALL remain visible
- **AND** the UI and server diagnostics SHALL identify the failed level, algorithm, and error reason
