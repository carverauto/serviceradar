## MODIFIED Requirements

### Requirement: Versioned Binary Topology Snapshots
The system SHALL deliver God-View geometry using the schema-3 Arrow IPC contract from #4749. Overview tiles and bounded detail scenes SHALL extend that contract without introducing a parallel JSON graph format.

Each payload SHALL contain one bounded record batch with `row_type` distinguishing node and edge rows, typed positions, UInt32 batch-local `edge_source` and `edge_target`, columnar regular details, and lazily decoded `details_irregular`. The schema SHALL retain required schema/revision columns and metadata. Missing required columns, incompatible types, invalid local endpoint references, nonfinite coordinates, or inconsistent identity metadata SHALL reject the payload without replacing the last compatible accepted scene.

Tile metadata SHALL include `payload_kind=tile`, `layout_version`, `z`, `x`, `y`, `tile_revision`, coordinate-space metadata, actual feature counts, and applicable cardinality and encoded-byte budgets. Persisted integer world coordinates in the fixed extent `0..2^24-1` SHALL be authoritative for tiles. Schema-3 `node_x` and `node_y` SHALL retain UInt16 tile-local coordinates with explicit affine world-origin and extent metadata. The coordinate error SHALL remain below one tile width per axis divided by 65535. Adjacent tiles SHALL use a deterministic shared-boundary convention; the browser SHALL NOT recompute overview placement. Persisted integer stability and bounded wire quantization error SHALL be measured separately.

Bounded detail metadata SHALL include `payload_kind=detail`, `level_id`, `parent_level_id`, layout version, publication generation, content revision, structural signature, selected layout algorithm, counts, budgets, and bounded continuation. A continuation SHALL pin the publication and native scope that produced it; it SHALL NOT resume across generations even when geometry is unchanged. Its coordinates SHALL belong to the selected detail scene; one validated ELK result SHALL author its accepted geometry. Detail coordinates SHALL NOT move persisted map positions. All edge references SHALL resolve inside the returned batch, including explicitly non-owning clipping proxies used by tiles.

#### Scenario: Client accepts supported snapshot schema
- **GIVEN** a supported schema-3 tile from an accepted layout version
- **WHEN** the client decodes its typed columns
- **THEN** it SHALL render the server-authored world positions using the declared coordinate transform
- **AND** it SHALL NOT invoke ELK for overview tile placement

#### Scenario: Detail coordinates remain separate
- **GIVEN** a bounded detail payload is opened from a map device, aggregate, or rendered relation bundle
- **WHEN** the client lays out that detail scene
- **THEN** one selected ELK pipeline SHALL author its accepted coordinates and routes
- **AND** bounded map pages SHALL declare the existing radial overview profile rather than selecting the layered detail profile solely because their transport payload kind is `detail`
- **AND** the bounded page SHALL elaborate its real endpoint attachment fan using existing radial projection and relation bindings, without applying the unbounded overview's small unclustered-fan cap
- **AND** neither its output nor its camera SHALL overwrite the map's persisted coordinate space

#### Scenario: Client handles unsupported snapshot schema
- **GIVEN** a payload has an unsupported schema or invalid required columns, endpoints, coordinates, or identity metadata
- **WHEN** the client validates the payload
- **THEN** it SHALL reject it and expose a recoverable compatibility or data error
- **AND** the last compatible accepted scene SHALL remain active

#### Scenario: Client validates required metadata envelope fields
- **GIVEN** a tile or bounded detail payload lacks its required identity, revision, coordinate-space, count, or budget metadata
- **WHEN** the client validates its envelope
- **THEN** the payload SHALL be rejected before replacing accepted geometry
- **AND** the previous compatible scene SHALL remain active

#### Scenario: Client validates required columns for schema version 1
- **GIVEN** an older server emits schema version `1`
- **WHEN** the schema-3 tile client validates the payload
- **THEN** it SHALL reject the unsupported version even if its legacy columns are complete
- **AND** the UI SHALL expose a recoverable compatibility error while retaining the last compatible scene

#### Scenario: Details remain lazy
- **GIVEN** a tile or detail scene contains regular details columns and irregular detail content
- **WHEN** the operator pans, zooms, filters, hovers, or selects
- **THEN** interaction SHALL retain typed-column access
- **AND** only the requested irregular details SHALL be decoded

### Requirement: Structural Reshape Contract
The system SHALL distinguish local presentation filters, viewport tile selection, bounded detail navigation, geometry publication, and telemetry overlays. Presentation and navigation SHALL NOT mutate canonical topology or trigger a world relayout.

#### Scenario: Viewport navigation fetches bounded geometry
- **WHEN** the operator pans or zooms the overview
- **THEN** the client SHALL select only visible tiles and a configured bounded prefetch neighborhood
- **AND** compatible cached tiles SHALL be reused without recomputing world coordinates

#### Scenario: Visual-only filter action
- **WHEN** the operator hides or highlights a class in resident geometry
- **THEN** the client SHALL apply the presentation change locally
- **AND** rendered relations SHALL continue to satisfy their visible endpoint contract
- **AND** the filter SHALL NOT cause canonical recomputation or a new layout version

#### Scenario: Structural reshape action
- **WHEN** the operator opens a device neighborhood or attachment-member page
- **THEN** the client SHALL fetch only the bounded required detail if it is not cached
- **AND** it SHALL enter a separate ELK coordinate space while preserving map camera and selection
- **AND** exiting SHALL restore the compatible map tiles and camera without a geometry refetch

#### Scenario: Geometry publication invalidates affected tiles
- **WHEN** canonical membership, static geometry content, or relation bindings change
- **THEN** the backend SHALL publish a complete new generation within the current layout version unless explicit relayout is required
- **AND** only changed tiles and changed bounded detail identities SHALL be invalidated
- **AND** unchanged tiles SHALL retain their content revisions

#### Scenario: Telemetry does not reshape topology
- **WHEN** health, last-seen data, or traffic changes without a geometry change
- **THEN** the server SHALL deliver a bounded telemetry overlay
- **AND** layout version, accepted device positions, and geometry tile revisions SHALL remain unchanged

### Requirement: Wasm Arrow Execution Layer
The system MUST provide a WebAssembly execution layer for Arrow-backed God-View client operations over resident tiles and bounded detail scenes without requiring the browser to materialize the canonical graph.

#### Scenario: Three-hop traversal computed in Wasm
- **GIVEN** a bounded detail scene declares complete membership for the requested traversal
- **WHEN** the operator requests nodes within three hops of its selected device
- **THEN** traversal SHALL execute over its resident Arrow-backed memory
- **AND** the resulting selection mask SHALL apply locally without reconstructing per-row objects

#### Scenario: Missing neighborhood membership is fetched explicitly
- **GIVEN** visible tiles do not contain a complete requested canonical neighborhood
- **WHEN** the operator requests that neighborhood
- **THEN** the client SHALL fetch a bounded server-authored detail scene with explicit continuation when necessary
- **AND** it SHALL NOT present traversal of only loaded tiles as a complete canonical result

#### Scenario: Local multi-column filter computed in Wasm
- **GIVEN** resident tiles or a bounded detail scene contain the requested attribute columns
- **WHEN** the operator applies a compound visual filter
- **THEN** the Wasm layer SHALL scan those columns and emit a visibility or ghosting mask locally
- **AND** frame rendering SHALL remain within the applicable interaction budget

#### Scenario: Layout interpolation computed in Wasm
- **GIVEN** an explicit transition between two accepted coordinate sets requires animation
- **WHEN** the client computes intermediate positions
- **THEN** interpolation SHALL use Arrow-backed memory without introducing periodic object-allocation stalls
- **AND** the result SHALL NOT mutate persisted world coordinates or mix map and detail coordinate spaces

## ADDED Requirements

### Requirement: Persistent world layout is deterministic and incrementally stable
God-View SHALL support an invented topology of 1,000,000 devices and at least 2,000,000 relations using server-authored hierarchical world coordinates persisted through platform migrations. A `layout_version` SHALL identify an explicit coordinate space and placement configuration. An ordinary incremental update SHALL preserve existing coordinates; only an explicit full relayout SHALL publish a different coordinate space.

Fresh world placement SHALL reuse the existing pinned ELK radial engine through bounded hierarchy batches of at most 512 nodes, with validated subtree envelopes composed into persisted coordinates before tile generation. Tiles SHALL NOT run independent layout passes. The layout worker SHALL retain the prior accepted publication when ELK execution or geometry validation fails. An incompatible placement algorithm SHALL trigger a staged new layout version on reconciliation and SHALL NOT relabel old Morton coordinates as ELK output.

Initial placement SHALL use authoritative sites when available, otherwise stable transport components, then infrastructure and attachment groups. Stable identifiers SHALL break ties independently of input row order. Existing placement slots and parent assignments SHALL survive incremental insertion, deletion, component merge/split, and changes to preferred roots unless a new layout version is explicitly published. Deleted slots SHALL NOT cause surviving positions to be renumbered.

#### Scenario: Radial layout remains visible through the tile engine
- **GIVEN** an invented root with endpoint attachments whose count fits a standard tile
- **WHEN** the background worker computes and publishes a fresh world
- **THEN** the endpoints SHALL occupy the ELK radial level and the tile SHALL retain their names, coordinates and connections
- **AND** the Home view SHALL fit the accepted active-device bounds

#### Scenario: Equivalent fresh input produces equivalent coordinates
- **GIVEN** identical invented canonical membership, relations, seed, and layout configuration in different input orders
- **WHEN** a fresh layout is computed
- **THEN** every device SHALL receive the same world coordinates and stable placement identity

#### Scenario: Incremental additions preserve existing positions
- **GIVEN** a persisted 1,000,000-device layout
- **WHEN** an invented 1% addition is applied within the same layout version
- **THEN** existing persisted integer device coordinates SHALL remain exactly unchanged
- **AND** the same prior placement and change batch SHALL produce the same new placements
- **AND** session reloads SHALL recover those persisted coordinates

#### Scenario: Schema changes use the migration lifecycle
- **WHEN** persistent layout, device-coordinate, or relation-binding records are introduced or changed
- **THEN** the schema change SHALL be an Elixir migration in the platform schema
- **AND** the configured core migration expected version SHALL be updated
- **AND** ingestion, rendering, and test helpers SHALL NOT create schema objects

### Requirement: Geometry generations publish atomically
The server SHALL distinguish stable `layout_version`, immutable publication `generation`, and per-tile content `tile_revision`. Candidate generations SHALL remain invisible until their positions, relation bindings, spatial summaries, and required low-zoom tiles are coherent. Publication SHALL reject stale writers and retain the last accepted generation on failure.

#### Scenario: Failed candidate does not replace accepted geometry
- **GIVEN** an accepted generation is serving requests
- **WHEN** source acquisition, layout, persistence, or tile validation fails for its replacement
- **THEN** the accepted generation SHALL remain available
- **AND** no request SHALL observe a mix of old and candidate memberships or relation bindings

#### Scenario: Unchanged content survives a later generation
- **GIVEN** a new generation changes one part of the world
- **WHEN** it is published
- **THEN** an unchanged tile SHALL retain the same geometry bytes and content revision
- **AND** publication generation or source-poll identity alone SHALL NOT invalidate its ETag

### Requirement: Quadtree tiles conserve membership within hard budgets
The server SHALL expose quadtree tiles keyed by `(layout_version, z, x, y)` within a fixed world extent and declared maximum zoom. Every admitted device SHALL have exactly one owning tile and one visible representation at every zoom: an individual device or membership in one stable aggregate. Importance-based `min_zoom` SHALL prioritize individual display without overriding density or byte budgets. A singleton representation in the standard profile SHALL preserve the device identity, label and authoritative coordinates rather than displaying an aggregate count of one. The compact aggregate-only profile SHALL continue bounding identifier bytes.

Each tile SHALL enforce node, relation, label, total-feature, and actual encoded-byte limits during construction. An oversized tile SHALL generalize further; it SHALL NOT silently truncate membership or transmit overflow. Boundary and context proxies SHALL count against feature budgets but contribute zero represented-device membership. Aggregate payloads SHALL contain bounded summaries and navigation references, not complete member lists.

#### Scenario: Membership is conserved at every zoom
- **GIVEN** the seeded 1,000,000-device canonical fixture
- **WHEN** all tiles at any supported zoom are generated
- **THEN** the visible owned device count plus the sum of aggregate member counts SHALL equal the admitted canonical device count
- **AND** shared tile boundaries SHALL neither omit nor duplicate a member
- **AND** every tile SHALL remain within its feature and encoded-byte limits

#### Scenario: Maximum-zoom density remains reachable
- **GIVEN** one maximum-zoom tile contains more devices or relations than its budgets permit
- **WHEN** it is generated
- **THEN** stable aggregates and bounded detail/member-page references SHALL represent the excess
- **AND** every admitted device SHALL remain reachable by search and bounded detail navigation
- **AND** no overflow member list SHALL be embedded in the tile

#### Scenario: Large worlds use map-style level of detail
- **GIVEN** a canonical world contains one million or more admitted devices
- **WHEN** the operator zooms out
- **THEN** the viewport SHALL display bounded clusters and grouped relations without requiring every individual device glyph or label to fit on screen
- **AND** panning SHALL load bounded visible tiles and neighboring prefetch rather than the complete canonical world
- **AND** zooming in SHALL reveal nearby individual devices subject to density and encoded-byte budgets

### Requirement: Tile relations preserve identity across bundles and clipping
The tile engine SHALL bundle low-zoom relations by their visible endpoint or aggregate pair while retaining stable bundle identity and represented-relation counts. Long relations SHALL become visible when their endpoint representations are eligible and SHALL be clipped deterministically across tiles. The spatial index SHALL find a crossing segment even when both endpoints lie outside the requested tile, without scanning all canonical relations for every tile request. Every returned edge endpoint SHALL be local to its batch.

#### Scenario: Adjacent tiles share a continuous relation
- **GIVEN** one admitted relation crosses multiple tiles
- **WHEN** those tiles are rendered together
- **THEN** its segments SHALL retain stable relation identity and deterministic boundary ownership
- **AND** procedural packet flow SHALL retain route-distance continuity
- **AND** clipping proxies SHALL NOT appear as extra devices or inflate aggregate counts

#### Scenario: Shared seams retain the same routing grade across adjacent tiles
- **GIVEN** adjacent tiles at the same zoom and budget, one denser than the other
- **WHEN** a relation crosses their shared boundary
- **THEN** both SHALL publish the same point for that crossing
- **AND** the point SHALL be the canonical intersection while that side's distinct crossings fit the shared cap
- **AND** a shared face SHALL use the stricter dyadic routing grade and crossing count of both adjacent cells, accounting for corners and edge-pair cardinality before interior selection
- **AND** encoding retries SHALL retain the publication routing budget regardless of interior budget or profile
- **AND** a quantized portal SHALL use aggregate route identity and SHALL NOT be drawn as a resolved canonical cable
- **AND** paging every rendered edge SHALL conserve the exact relation membership of the published geometry

#### Scenario: Owned endpoint contact draws the canonical segment once
- **GIVEN** a canonical endpoint lies on a shared boundary
- **WHEN** the canonical segment has zero length inside its half-open owner
- **THEN** that owner SHALL draw no synthetic connector
- **AND** the neighbor that contains the interior SHALL draw the canonical segment
- **AND** an unowned tangential corner contact SHALL NOT create a segment
- **AND** a genuine self-loop SHALL contribute to the owning representation's internal-relation count

#### Scenario: Low-zoom bundles remain explainable
- **GIVEN** many admitted relations connect the same visible aggregate pair
- **WHEN** the overview uses a bundled edge
- **THEN** its count and identity SHALL describe those represented relations without serializing them all
- **AND** `kind=bundle` picking metadata SHALL resolve the accepted tile selector and return the exact represented relation count and two rendered endpoint glyphs
- **AND** the metadata SHALL reference a `kind=bundle_members` bounded scene without assuming the rendered bundle ID is a canonical relation ID
- **AND** bounded details SHALL preserve access to the underlying canonical relation identities

### Requirement: Tile HTTP responses are authorized and revision cacheable
The authenticated `GET /topology/tiles/:layout_version/:z/:x/:y` endpoint SHALL return one bounded schema-3 geometry tile with an ETag derived from layout version and tile content revision. Current authority SHALL be checked before response or HTTP 304. Cache entries SHALL be isolated by effective device visibility when authorization scopes differ; aggregate counts and details SHALL obey that same visibility boundary.

The server SHALL provide bounded layout-manifest metadata, coordinate search, identity details, and bounded detail-scene endpoints. A detail request with no revision SHALL resolve the requested level's current content revision; it SHALL NOT use its parent's revision. An unavailable pinned detail revision SHALL return HTTP 409 `stale_revision`. A valid empty tile SHALL be cacheable. A layout other than the installed one SHALL return HTTP 409 `layout_changed` before zoom-range validation. Over-max zoom on the installed layout, other malformed keys, and a malformed overlay revision SHALL return HTTP 400. Unknown identities SHALL return HTTP 404. Tile and overlay budget failures SHALL return HTTP 413 `topology_budget_exceeded` with no `Retry-After`. Absence of an accepted layout, and a source transition, SHALL return HTTP 503 with `Retry-After: 1`. Error bodies SHALL be `{error: code}`. These errors SHALL NOT replace the client's last compatible scene. Candidate generations SHALL never be served.

Picking metadata SHALL accept `device`, `relation`, `aggregate`, and `bundle` kinds. Detail scenes SHALL accept `neighborhood`, `component_members`, `aggregate_members`, and `bundle_members` kinds. All picks and scenes SHALL pin layout version and publication generation. Aggregate and bundle kinds SHALL additionally pin z/x/y and the encoded geometry tile revision, and SHALL use the corresponding accepted server selector. Detail continuation envelopes SHALL be bounded to 512 bytes and SHALL include that publication identity plus native world/scope revisions and typed UInt32 page fields. Current authority SHALL be checked independently of every cursor.

A bundle-member page SHALL examine at most 4,096 raw spatial candidates and return at most 128 distinct canonical devices and 256 canonical relations before scoped inventory enrichment. It SHALL distinguish exact total relation membership from per-page visible device/relation counts and scanned candidate count. It SHALL NOT claim an exact distinct-device total from the represented relation count. Empty pages with remaining candidates SHALL return an advancing continuation rather than imply completion.

#### Scenario: Bundle details preserve exact membership across bounded pages
- **GIVEN** a rendered bundle has more relations or distinct endpoints than one detail page permits
- **WHEN** the operator traverses its `bundle_members` scene under one accepted selector
- **THEN** each page SHALL preserve the node, relation, and candidate budgets
- **AND** every represented canonical relation SHALL remain reachable exactly once without preloading its full member list
- **AND** endpoint devices MAY repeat on later pages while counts remain explicit
- **AND** an empty filtered page with a continuation SHALL permit another bounded request

#### Scenario: Detail continuation cannot cross publication or tile identity
- **GIVEN** a detail cursor was produced for one publication and native scope
- **WHEN** its layout or generation differs from the requested publication, or its tile/profile/scope no longer matches
- **THEN** the continuation SHALL be rejected without returning mixed-publication content
- **AND** unchanged native geometry SHALL NOT make an old publication cursor reusable
- **AND** a publication change during scoped enrichment SHALL reject the completed result

#### Scenario: First paint is independent of channel timing
- **GIVEN** an accepted layout has its low-zoom tiles available
- **WHEN** an authenticated operator opens God-View before channel delivery
- **THEN** HTTP manifest and visible-tile requests SHALL produce the first usable frame
- **AND** no complete canonical graph SHALL be required by the browser

#### Scenario: Authorization revocation defeats a cached validator
- **GIVEN** an operator previously fetched a tile and its ETag
- **WHEN** the required authority is revoked before a conditional request
- **THEN** the request SHALL fail authorization
- **AND** it SHALL NOT return either cached tile bytes or HTTP 304

#### Scenario: Search locates a device hidden by generalization
- **GIVEN** an admitted authorized device is represented by a dense aggregate
- **WHEN** the operator searches for that device
- **THEN** the server SHALL return its persistent coordinates, a useful target zoom, and bounded detail navigation
- **AND** the client SHALL fly to that location without fetching unrelated topology

### Requirement: Dirty-tile invalidation and telemetry are separate bounded streams
The topology channel SHALL send bounded geometry invalidations naming layout version, publication identity, and affected tile keys, never whole graphs. A watch whose `layout_version` is not the installed layout SHALL be rejected as `layout_changed` before an over-max zoom is reported as `invalid_tiles`. Initial watch acknowledgements and later invalidations SHALL obey the same metadata byte limit and SHALL use an explicit reset/reconcile marker on overflow. Clients SHALL refetch only visible dirty tiles and reconcile publication identity after reconnect.

Telemetry SHALL use a separate bounded overlay keyed by stable node, aggregate, relation, or bundle IDs and the compatible tile geometry identity. Health rollups, last-seen values, and traffic rates SHALL NOT participate in geometry tile revisions. Stale overlays SHALL be discarded; a telemetry sequence gap SHALL reset only the overlay. Metrics SHALL continue through NATS JetStream and the configured telemetry backend.

Overlay bodies SHALL use authenticated HTTP with a separate ETag and a 256 KiB encoded JSON limit; channel control metadata SHALL remain within 16 KiB. Each overlay SHALL pin the installed generation and encoded geometry revision, using a compatible native selector and health index. Telemetry SQL waits SHALL retain only bounded plain selected data, not native world handles. Rate queries SHALL select at most 512 exact interface pairs from at most 256 selected relations and obey a separate 1 MiB request budget without truncating identities.

Packet attribution SHALL admit only direct physical evidence with no virtual role; only a globally exclusive endpoint interface SHALL supply a relation measurement. Fresh measured packet or octet rates SHALL drive directional traffic animation without requiring every packet family. The response SHALL distinguish observed packet rates from complete packet totals: missing families remain unknown, never zero. Summing packet families SHALL require common identified producer provenance; a uniquely measured single family SHALL NOT require cross-family identity proof. Ambiguous measurements and excluded evidence SHALL remain unknown. A bundle direction SHALL animate only after its rendered membership is fully selected in that frame. It MAY animate the observed contribution from fresh, unambiguous physical bindings while other selected bindings have no telemetry; complete totals SHALL remain unknown and observed coverage SHALL be explicit. Sampled rates SHALL NOT be extrapolated or accumulated across pages as a complete current measurement. Health SHALL distinguish healthy, unavailable and unknown counts, with explicit seed/source freshness metadata.

#### Scenario: Geometry change touches only dependent tiles
- **WHEN** one device's non-telemetry geometry content changes
- **THEN** invalidation SHALL be limited to its owning tiles, affected aggregate ancestry, and tiles touched by any changed old or new relation geometry
- **AND** unrelated tile revisions SHALL remain reusable

#### Scenario: Telemetry animates without geometry fetches
- **GIVEN** visible tiles are cached and packet flow is enabled
- **WHEN** local health or traffic rates change
- **THEN** bounded overlays SHALL update the corresponding visible glyphs and procedural edge flow
- **AND** the update SHALL trigger zero geometry tile refetches or world-layout operations

#### Scenario: Invalidation overflow is explicit and bounded
- **GIVEN** a structural publication changes more tile keys than one allowed message can hold
- **WHEN** the channel publishes its invalidation or watch acknowledgement
- **THEN** it SHALL send a bounded reset/reconcile marker
- **AND** it SHALL NOT send a partial key list that implies completeness

#### Scenario: Shared interfaces and partial bundles do not invent packet flow
- **GIVEN** a rendered bundle includes unselected relations or an endpoint interface shared by another canonical relation outside the selected page
- **WHEN** the server computes its current overlay
- **THEN** the response SHALL report observed and total membership separately
- **AND** a shared interface SHALL NOT be attributed to an individual relation unless a unique opposite endpoint supplies the measurement
- **AND** a bundle with unselected membership SHALL have unknown flow and no packet animation
- **AND** a fully selected bundle with partial telemetry MAY animate only its measured contribution, SHALL keep complete totals unknown, and SHALL report observed relation counts

#### Scenario: Measured zero and missing producer provenance remain distinct
- **GIVEN** a single physical relation has three fresh measured packet families from one identified producer
- **WHEN** all three rates are zero
- **THEN** its overlay SHALL report measured zero without animation
- **AND** absent producer identities SHALL NOT establish matching packet-family provenance

#### Scenario: Ordinary SNMP counters animate traffic
- **GIVEN** a physical relation has a fresh positive unicast packet rate but no multicast or broadcast counters
- **WHEN** its flow overlay is requested
- **THEN** the response SHALL carry the observed packet rate and enable directional animation
- **AND** the complete packet total SHALL remain unknown
- **AND** a fresh positive octet rate alone SHALL also enable traffic animation without inventing a packet rate
- **AND** measured zero or stale observations alone SHALL NOT animate

#### Scenario: Publication during telemetry IO cannot replace current overlays
- **GIVEN** a telemetry query started for an installed generation and encoded tile revision
- **WHEN** a newer generation is installed before it completes
- **THEN** the stale result SHALL be discarded without replacing current overlay state
- **AND** telemetry refresh SHALL NOT refetch geometry or extend a sample's freshness timestamp

### Requirement: Tile navigation preserves bounded detail scenes and cached maps
The God-View client SHALL use deck.gl TileLayer in OrthographicView with bounded prefetch and an LRU cache, reusing #4749 typed WebGPU sublayers and procedural packet flow. Picking SHALL fetch details by stable identity. Browser ELK SHALL run only on a bounded device-neighborhood, component/aggregate-member, or rendered-bundle-member detail scene, with explicit entry and exit.

#### Scenario: Panning back reuses cached geometry
- **GIVEN** an unchanged previously visited area remains within the LRU budget
- **WHEN** the operator pans back to it
- **THEN** its tiles SHALL render from cache without a network fetch

#### Scenario: Zoom transition preserves compatible shared boundaries
- **GIVEN** target-zoom tiles arrive at different times
- **WHEN** the client transitions visible coverage to that zoom
- **THEN** it SHALL retain compatible previous coverage until the target coverage is ready for a coherent swap
- **AND** it SHALL NOT render incompatible parent/child portals across a shared boundary
- **AND** failed or stale target requests SHALL preserve the last compatible coverage

#### Scenario: Detail overflow stays bounded
- **GIVEN** an attachment group exceeds the configured detail-scene member budget
- **WHEN** the operator opens it
- **THEN** the client SHALL receive one bounded member page plus bounded context
- **AND** ELK SHALL never receive the entire canonical graph or the complete unbounded group
- **AND** returning SHALL restore the compatible cached map camera and tiles

### Requirement: Million-device tile interactions satisfy measured performance budgets
God-View SHALL meet the tile-engine acceptance budgets on an independently invented seeded fixture of 1,000,000 devices and at least 2,000,000 relations. Measurements SHALL use a real WebGPU device with procedural packet flow enabled and record device limits, selected budgets, payload sizes, fixture seed, and measurement method.

#### Scenario: Real-device navigation meets the acceptance budgets
- **GIVEN** the accepted synthetic million-device world is available from a local server
- **WHEN** the operator opens, pans, zooms, hovers, and selects in God-View
- **THEN** first usable frame SHALL arrive within 3 seconds
- **AND** pan and zoom SHALL sustain at least 30 frames per second
- **AND** hover and selection SHALL each complete in less than 100 milliseconds
- **AND** visible-tile fetch plus decode SHALL be at most 200 milliseconds at p95
- **AND** a SwiftShader-only run or pure index benchmark SHALL NOT satisfy this real-device gate

### Requirement: Topology locations can be shared
The topology UI SHALL provide a shareable map location containing a versioned resource and coordinate-space identity, layout version, center and zoom. It SHALL restore the same area for the same layout version across ordinary publications and restarts, while displaying current authorized data. An explicit device link SHALL resolve the stable device identity to its current position.

#### Scenario: Share and reopen a map area
- **WHEN** a user shares a zoomed map view and another authorized session opens its link
- **THEN** the map SHALL restore that center and zoom after validating the manifest
- **AND** the link SHALL NOT pin transient telemetry or publication generation

#### Scenario: Obsolete or invalid map location
- **WHEN** a link contains a replaced layout version, a different resource/space or invalid coordinates
- **THEN** the UI SHALL visibly explain that the saved location cannot be restored and show the current Home view
- **AND** SHALL NOT silently reinterpret that location or request arbitrary backend URLs

#### Scenario: Device link after relayout
- **WHEN** an authorized user opens a device link after a full relayout
- **THEN** the UI SHALL search the stable device id and open its current coordinates
- **AND** a missing device SHALL yield an explicit unavailable state

#### Scenario: Address bar follows map navigation
- **WHEN** a user pans or zooms the world map
- **THEN** compact `layout`, `x`, `y` and `z` query parameters SHALL track the settled camera, rounding coordinates to at most one decimal and zoom to at most three decimals
- **AND** the authorized topology route SHALL supply the resource and coordinate-space identity without repeating them in the URL
- **AND** older expanded `map_*` links SHALL still restore their validated location and become compact links on the next address-bar update
- **AND** updates SHALL replace the current history entry, preserve host history state and unrelated query parameters, and stop when the renderer is destroyed
- **AND** copying the address bar SHALL restore the same camera as Share map
