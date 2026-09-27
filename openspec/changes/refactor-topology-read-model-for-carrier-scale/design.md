## Context
[Issue #4774](https://github.com/carverauto/serviceradar/issues/4774) now requires a web-map-style tile engine for 200,000 to 1,000,000 or more devices. The user confirmed this revised scope. This amendment replaces this change's earlier semantic-level-only overview and its frontend-only geometry decision: persistent server world coordinates own the overview, while ELK remains only in explicitly entered bounded detail scenes. Tiles are current scope, not future work.

The broader carrier-scale change also separates infrastructure transport, endpoint census, unresolved identity diagnostics, and evidence-backed impact semantics. Quarantine and evidence-backed `Affected` tasks remain outside #4774. This amendment does not imply that those independent requirements are implemented.

## Implemented foundation and measured evidence
The Dgraph canonical reader now pages Device vertices and canonical relations through one Rust read-only transaction. Raw UID order and page progress are validated; the reader reduces an oversized response until it fits the pinned gRPC receive limit or fails at one row. Required-block, wrong-type, UID, RPC, and snapshot errors reject the whole refresh. Existing domain admission still excludes orphan/no-identity endpoint relations; excluded raw rows advance the cursor and count toward page termination. This admission rule is not new quarantine behavior. The real loopback gRPC protocol target passed, including an actual oversized response and later-page failures: [focused protocol run](https://carverauto.buildbuddy.io/invocation/e79e0e20-1ad8-47f0-a325-c09bbde3ef22). Actual Dgraph query verification and the final post-paging repository gate remain pending.

`Atlas` and `AtlasStore` provide immutable semantic indexes, atomic watched selection, and bounded member/neighborhood pages. `AtlasReader` and `AtlasLevel` select membership before scope-authorized inventory enrichment and derive final detail content/structure revisions. Runtime supervision retains the last accepted index on source failure and rebuilds after store restart. Revision metadata HTTP and bounded channel watch mode are implemented; joins select metadata mode before the first tick, and acknowledgements/invalidation use a 16 KiB reset fallback. Current persisted human authority is refreshed on HTTP and channel operations. Four real-database reader/channel/HTTP tests passed in 90.7 seconds against invented srql-fixtures scratch data; DROP and a fresh query verified absence, and temporary credentials were removed. This is foundation evidence, not tile HTTP or overlay acceptance.

Pure Atlas checks passed on an independently invented 200,000-device/400,000-relation graph. The server foundation with authorization/cache and store-fault fixes passed `make test` through the repository's Make target, which invokes Bazel with `--config=remote`: [351 tests passed, two skipped](https://carverauto.buildbuddy.io/invocation/fa2af5b1-2d16-4723-b15b-0c9e94e1fc03), exit 0. That run precedes source paging and tile-engine changes. A later workspace Cargo check stopped on unrelated existing `reqsign-azure-storage` undeclared test dependencies; it is not a full-tree pass.

The Rust engine passed [seven remote Bazel tests](https://carverauto.buildbuddy.io/invocation/0ca01302-0f5f-4122-ad85-2b06d4ed2098), including placement stability, tile count/cardinality checks, crossing segments, shared corners, owned boundary contacts, and phase continuity. The invented 1,000,000-device/2,000,000-relation fixture measured fresh placement at 1,952 ms, concentrated 1% incremental growth at 3,231 ms, index construction at 2,764 ms, and zoom-zero tile generation at 230 ms. Sixty-four sampled tile-generation calls at zooms 4, 8, 12, and 16 had p95 4.635 ms. Those are pure Rust operations on a remote test executor; the samples are not exhaustive all-zoom enumeration, and timings exclude persistence, Arrow encoding, HTTP, decode, and browser work. The engine, core-owned NIF, persistence resources, migration, and bounded Oban worker are now integrated. The HTTP/channel and cache lifecycle are present but are not yet enabled as the overview runtime. Packaged NIF and pinned resource/configuration checks passed independently; the combined Dgraph/database lifecycle, schema-3 encoding, cache/transport integration, overlays, and real-WebGPU acceptance remain open.

## Goals / Non-Goals
- Persist deterministic, stable world positions and publish coherent incremental generations.
- Bound overview delivery by visible tiles, with correct aggregate counts and explicit access to every admitted device.
- Keep geometry cached while health and packet flow update separately.
- Preserve bounded, readable ELK detail scenes without changing map geometry.
- Measure the complete 1M-device path and real WebGPU acceptance with packet flow enabled.
- Do not add a second renderer, change #4749 internals, or bring evidence-backed impact/quarantine work into #4774.
- Do not infer geographic relationships for sites whose topology is nongeographic.

## Decisions

### Decision: Separate map and bounded detail geometry

The overview uses server-authored persistent world coordinates. A browser never lays out the whole canonical topology. Bounded ELK scenes remain separate coordinate spaces for a selected device neighborhood or a page of attachment members. Entering detail saves the map camera and selection; exit restores them without moving the world.

Reuse the jointly paged Dgraph canonical reader, RuntimeSupervisor failure retention, stable semantic identities, component/attachment grouping, bounded detail selection, scoped inventory reads, and current-authority checks. The existing semantic-level content hash includes telemetry and cannot be reused as a geometry tile ETag. Existing Atlas global/component pages are useful detail/index foundations, not the tile overview implementation.

### Decision: Publish immutable generations within a stable coordinate version

Ownership: a pure Rust `topology-atlas` engine with a core-owned NIF resource; a core Oban worker coordinates durable generation. Core must not depend on web-ng. The worker reads canonical topology, creates or updates the spatial index, persists the candidate, and publishes it. HTTP and channels read accepted immutable generations rather than doing whole-graph layout in a request.

Three identities have different purposes:

| Identity | Meaning | Changes when |
| --- | --- | --- |
| `layout_version` | Coordinate space, placement algorithm/configuration, fixed world extent | Explicit full relayout only |
| `generation` | Atomically published geometry/topology state within a layout | Membership, relation binding, importance, or other geometry content changes |
| `tile_revision` | Content identity of one geometry tile | That tile's admitted geometry or static details change |

The source poll/revision and generation must not be included unconditionally in tile content hashes. Untouched tile bytes and ETags remain reusable after publication of another generation. A telemetry update advances only overlay sequence/revision.

Build a candidate generation separately. Only publish its head after coordinates, relation bindings, hierarchy summaries, dirty-tile index, and required low-zoom tiles are complete and validated. A failed read, placement, persistence, or encoding operation leaves the previous accepted generation active. Compare-and-swap publication prevents an older worker from replacing a newer head. Restart reconstructs an accepted generation from persistence. Partial candidates are never visible; abandoned generations are collected after readers release them.

An immutable generation need not duplicate one million unchanged position rows. Position assignments belong to a layout version and are append-stable; generation membership, relation-binding changes, and tile revisions use an immutable delta or equivalent MVCC representation. The published head is the visibility boundary. Deletions cannot mutate an old generation out from under in-flight requests.

### Decision: Persist layout state through platform migrations

Logical records, with physical representation chosen to avoid full rewrites:

- Layout: `layout_version`, algorithm and configuration version, seed, integer world extent, maximum zoom, creation time, status.
- Generation: `layout_version`, `generation`, predecessor, canonical source identity, status, publication time, accepted tile-index reference.
- Device position: `layout_version`, canonical `device_id`, integer `world_x`, `world_y`, stable placement parent, allocated slot, importance/minimum zoom. Generation membership controls visibility.
- Relation binding: `layout_version`, stable canonical `relation_id`, canonical endpoint IDs, endpoint placement bindings, route/bundle inputs. Coordinates derive from the authoritative persisted endpoints; a relation binding does not duplicate an independently mutable device position.
- Aggregate and spatial summaries: stable aggregate identity and tile ownership, represented-member count, stable child/detail reference. Counts describe canonical admitted membership, not telemetry.
- Geometry tile cache: `(visibility_scope, layout_version, z, x, y, tile_revision)`, content type, encoded bytes, checksum, row counts. A manifest maps an accepted generation to current tile revisions.

Create/alter these records only with Elixir migrations under `elixir/serviceradar_core/priv/repo/migrations/`, in `platform`, with the matching `core.migrations.expectedVersion` bump. Use Ash resources and existing core persistence conventions. No ingestion, helper, test, or request handler creates schema objects.

### Decision: Use hierarchical integer placement and freeze existing positions

The initial algorithm is hierarchical Morton placement in fixed integer world coordinates `0..2^24-1`, implemented in Rust. It derives a deterministic component/transport forest, reserves three leaf slots per node, and uses an incremental vacancy map that refines allocation without moving existing positions, parents, or component bounds. These are initial measured placement choices, not evidence that tile generation or persistence is complete. Place sites when authoritative site membership exists; otherwise stable transport components. Within those containers place a ranked infrastructure forest, then endpoint groups. Stable semantic IDs break ties. Cross-links do not dictate node placement. Nongeographic sites receive deterministic spatial slots; geographic-looking coordinates are not implied.

Existing coordinates and placement-parent assignments are frozen during ordinary incremental updates. New devices occupy deterministic available slots near their parent. Reserve growth space and retain tombstoned slots; do not renumber by current sorted input, current component count, or current child count. A component merge/split or a new preferred root does not silently move existing devices. Explicit relayout produces a new layout version when a different partition or arrangement is needed.

Fresh-layout determinism and incremental stability are separate promises. The same canonical input and configuration produce the same fresh layout. The same prior persisted placement plus the same sorted change batch produces the same incremental result. Arbitrary insertion histories need not converge to the fresh-layout positions; promising that would conflict with freezing prior placements. Tests compare exact integer coordinates, satisfying the issue's small-epsilon bound more strongly.

Do not allocate a canonical-size array for each component or scan every edge per node/tile. Index construction must be linear or near-linear in canonical devices and relations. Local updates should touch the changed memberships/bindings and affected hierarchy/tile paths. A seeded invented 1,000,000-device and at least 2,000,000-relation hierarchy measures CPU, peak resident memory, layout duration, persistence duration, index size, and 1% incremental update cost before choosing final algorithm parameters.

### Decision: Conserve membership through quadtree generalization

The quadtree key is `(layout_version, z, x, y)` for `0 <= z <= Zmax`; `0 <= x,y < 2^z`. The manifest defines a fixed world extent and one unambiguous half-open tile-boundary convention, with the outer world boundary included exactly once. A device has one owning tile per zoom. This remains true for coordinates on boundaries.

At a zoom, each admitted device is represented exactly once as an owned visible device or as a member of one owned aggregate. The conservation invariant is `visible_device_count + sum(aggregate.member_count) == admitted_device_count` across all tiles at that zoom. Boundary proxies, route segments, and context glyphs contribute zero membership. A device represented individually cannot also remain in an aggregate count.

Importance determines the earliest zoom at which an individual device is eligible. Eligibility does not bypass density or byte budgets. Tile construction coarsens the affected aggregate partition deterministically until node, edge, label, total feature, and encoded-byte bounds all hold. Aggregates have stable identities derived from spatial/hierarchical ownership, not health or transient row order. Do not serialize their full membership lists.

At maximum zoom, dense populations remain bounded aggregates with explicit bounded detail/member-page references. Search can always locate any admitted device and open its detail even if density prevents a standalone map glyph. An overflow aggregate is an intentional visible representation, not a silent truncation. The membership conservation test runs at every zoom.

Low-zoom relation bundles have stable IDs and represented-relation counts keyed by their visible endpoint or aggregate pair and any semantics required to avoid misleading combinations. Internal relations can contribute a bounded internal-relation count rather than an invisible oversized edge list. Preserve parallel-relation semantics through counts and detail lookup.

Long edges are clipped into the tiles they cross once both endpoint representations are eligible. The initial engine uses a segment bounding-volume index, not endpoint-only ownership, to find crossing lines whose endpoints are both outside the tile. Candidate counts and memory must be measured: dense high-zoom tiles can still visit many relations that collapse to a small bundle set, so bounded output alone does not prove bounded request cost. Each emitted segment retains relation/bundle identity and phase information; clip-local proxy rows keep UInt32 endpoints batch-local and contribute zero device membership.

Shared geometry uses four fixed side-midpoint portals and four exact corner portals per tile. Coordinates and identities derive from layout version, zoom, and global grid boundaries, independently of local density. Exact integer/rational classification makes diagonal corner crossings agree. Eight zero-member boundary glyphs plus one generalized interior glyph can represent every directed pair within nine nodes and 72 edges; these are minimum feasible cardinality bounds, not calibrated production budgets. Bundle identities derive from stable endpoint representation IDs and layout identity, never local row indexes.

An endpoint on a boundary belongs to its half-open owner. If its canonical segment immediately exits or enters that owner, preserve the owned representation-to-portal connector even when the canonical clip has zero length. Reserve a phase distance of half a tile width for each such connector, including when the raw device equals the portal: its aggregate may still need a visible connector. Omit only genuinely coincident rendered endpoints. Unowned tangent corner contacts add no segment; genuine self-loops contribute to the owning representation's internal-relation count.

For canonical length L and reserved source/target phase distances S,T, canonical clip [a,b] uses phase [(S+aL)/(S+L+T),(S+bL)/(S+L+T)]. The source connector uses [0,S/(S+L+T)] and the target connector uses [(S+L)/(S+L+T),1]. Adjacent segments compute the same phase boundary without another tile's plan. Bundles describe aggregate flow, not individually tracked packet identity.

Fixed portals guarantee adjacency only for the same zoom. The client must retain compatible coverage while the target zoom loads, then swap coherent visible coverage atomically. A default partial parent/child TileLayer fallback must not place incompatible portals across a shared rendered boundary. A future cross-zoom stitching policy would need its own explicit contract.

Changing an existing device dirties its owned tile at every represented zoom plus the tiles touched by changed old/new edge segments and affected ancestor aggregate/bundle summaries. A node-only metadata/position change does not invalidate unrelated tiles. Changing an endpoint of a long relation can legitimately dirty crossed tiles, so the single-device invalidation test must distinguish a node-only change from a relation-geometry change.

### Decision: Extend schema 3 for tile and bounded detail delivery

Geometry uses the schema-3 Arrow batch from #4749, extending metadata and typed fields as needed, with no parallel JSON graph. Stable node/aggregate/relation IDs, typed positions, UInt32 local endpoints, columnar regular details, and lazy irregular details remain the contract. Tile metadata includes `payload_kind=tile`, `layout_version`, `z`, `x`, `y`, `tile_revision`, world extent/bounds or exact coordinate transform, actual row counts, configured feature/byte limits, and membership counts.

Position authority is the persisted integer world position. The actual #4749 encoder and decoder retain UInt16 `node_x`/`node_y`. Tiles retain those column types and encode tile-local coordinates with explicit affine world-origin and extent metadata. Per-axis error must remain below the tile width divided by 65535; the server's integer world positions remain exact. Do not silently reinterpret UInt16 values, infer scaling from viewport, or let the client recompute layout. Route/proxy quantization and the half-open ownership rule must agree at adjacent boundaries. A device may quantize differently across zooms within the declared bound; persisted-coordinate stability and rendered quantization error are separate checks.

HTTP contract:

| Request | Response |
| --- | --- |
| `GET /topology/tiles/manifest` | Small authenticated JSON metadata: current layout, generation, extent, zoom range, budgets, coordinate encoding, tile URL template, overlay protocol |
| `GET /topology/tiles/:layout_version/:z/:x/:y` | One bounded schema-3 Arrow geometry tile, ETag over layout and tile content revision |
| `GET /topology/overlays/:layout_version/:z/:x/:y?revision=...` | Bounded JSON health and flow snapshot pinned to the encoded tile revision, with a separate content ETag and current authority checked before read and delivery |
| `GET /topology/tiles/search?device_id=...&layout_version=...` | Authorized device ID, world coordinates, target zoom, bounded detail reference |
| `GET /topology/details?kind=device|relation|aggregate&id=...&layout_version=...&generation=...` | Bounded picking metadata and a bounded scene reference; aggregate membership is paged in that scene |
| `GET /topology/snapshot/latest?level_id=...&revision=...` | Bounded schema-3 ELK detail scene after #4749; retained semantic contract is explicitly detail-only |

Static routes must be declared before parameterized tile routes. An omitted detail revision requests the child's latest revision, not the parent's. Keep geometry generation pinning distinct from a tile content revision. A valid empty tile is a cacheable empty batch, not missing topology. Malformed keys return 400, unknown/retired layout or unknown detail returns 404 or an explicitly documented retirement response, stale explicit revisions return 409 with reconciliation metadata, and no accepted layout returns 503. Authorization failures remain failures even when a matching ETag was supplied.

Picking metadata pins the layout and publication generation displayed by the caller. Aggregate picks additionally supply z/x/y and the encoded tile revision; the server obtains membership from its cached native selector, never a client-supplied member list. A generation or tile mismatch returns 409. Metadata requests and responses are each capped at 256 KiB, and sixteen supervised reads bound world-handle retention during inventory IO. Aggregate metadata returns its exact represented count and a scene reference, not an unbounded membership list or a second JSON graph format.

Tile ETags must not change just because generation advances elsewhere. Per-request current authority is checked before cache lookup/304. Use private HTTP caching and key server caches by the effective inventory visibility scope/policy version when scopes differ. A scope may not receive another scope's node IDs, aggregate counts, details, or tile bytes. A role/user ID alone is not a safe visibility fingerprint if grants can change. If existing policy is a single shared all-device visibility domain after the analytics+devices permission checks, establish that from actual policy and document the bounded supported model instead of inventing future multitenancy.

The current `Inventory.Device` policy uses `read_with_permission(devices.view)` without a row-level visibility filter; deployment separation is the database search path. The tile runtime supports this existing shared visibility domain after refreshing both `analytics.view` and `devices.view`. Detail enrichment still passes the caller's current scope to Ash. Introducing partition- or device-filtered read policies requires matching native indexes/cache keys before enabling those policies for the shared tile runtime.

Candidate generations are not observable. Requests pin the accepted generation at admission; an encoded response corresponds to that complete generation. The client uses the channel/manifest publication identity to reject stale in-flight results. Unchanged tile content can be carried forward into later generations without changing its ETag or triggering a fetch.

### Decision: Separate geometry caching from telemetry overlays

Precompute low-zoom geometry before publishing a new layout; generate higher tiles on demand against the immutable accepted index and cache the result. Choose the low-zoom cutoff, cache persistence/storage, maximum entries/bytes, prefetch radius, and eviction policy from the invented scale fixture. Work-in-progress requests are deduplicated. Cache size and active subscriptions are bounded.

Channel tile mode joins before its first tick and never sends a whole graph or a legacy snapshot. A geometry invalidation names `layout_version`, predecessor/current generation, and affected tile keys. It contains no full device/relation lists. Retain the existing 16 KiB metadata ceiling and a bounded key-count ceiling; overflow uses an explicit reset/reconcile marker. Initial watch acknowledgements are subject to the same ceiling. Disconnect/rejoin reconciles the manifest rather than assuming delivery continuity. Only visible dirty tiles are refetched; a compatible clean tile remains in the LRU and revisiting it requires no network fetch.

Telemetry is a separate bounded per-watched-tile overlay keyed by stable device/aggregate/relation/bundle IDs plus layout/tile geometry identity and overlay sequence. Initial overlay state is supplied separately so static cached geometry does not display stale health. Aggregate health and edge traffic live in the overlay. Unknown/no-data is explicit. Stale overlays for retired tile geometry are discarded; an overlay sequence gap requests only an overlay reset, not geometry. Large updates are coalesced or paged within message byte/feature limits rather than sending unbounded lists.

Overlay bodies use authenticated HTTP with a separate content ETag and an actual 256 KiB JSON ceiling. The channel carries only small overlay invalidation/sequence metadata within its existing 16 KiB control ceiling. Overlay reads pin the encoded geometry revision and installed publication generation; the native selection and availability index must belong to that same generation. A durable head-change hint does not invalidate a coherent installed world before its replacement is ready. A completed old-generation read is discarded. Final geometry receipts retain at most 256 rendered edge ID/count summaries, so even wholly unselected bundles have explicit unknown coverage without Arrow decoding or full membership lists.

The initial overlay owner permits four active requests and 64 waiters, coalesces identical reads, and caches only plain data in at most 128 entries/8 MiB for five seconds. Preparation returns at most 256 canonical bindings after examining at most 4,096 candidates, plus bounded native health rollups. The preparation process must return successfully and exit before a separate telemetry-query task starts; database waits retain no native world, health, or selector handles. Preparation handoff is capped at 8 MiB. Empty selection pages still advance their cursor, and no frame accumulates old sampled rates across pages to imply a complete current bundle measurement. Cancellation keeps admission occupied until process DOWN; native execution permits separately survive a killed dirty-NIF caller.

Interface attribution uses only `direct-physical` evidence (including normalized legacy `direct`), an absent/empty role, and exact positive interface bindings. Logical, hosted, inferred, attachment, path and unknown evidence are excluded, with eligibility reasons reported. A native index computes each binding's degree across all active canonical relations, including relations outside the selected page; only degree-one endpoints can supply a relation measurement. Source/out is preferred for the canonical forward direction and target/in is its fallback; the reverse direction uses the opposite pair. Rendered reversal swaps those directions. The two endpoint observations are never added together.

One backend-routed SRQL read accepts at most 512 distinct exact device/interface pairs and 1 MiB of serialized request data, without truncating identifiers. Initial configurable defaults are a 15-minute query window, 120-second sample freshness and five-second SQL timeout; response metadata preserves those controls and actual observation intervals. Packet totals require measured unicast, multicast and broadcast families from the same identified gateway/agent producer at one endpoint. Missing producer identity and the writer's unknown placeholder cannot establish common provenance; explicit producer ambiguity stays unknown. A uniquely measured octet family remains independent. Measured zero stays measured. A bundle direction animates only when every rendered underlying relation is measured in that frame; partial coverage is never extrapolated. Cache TTL never rewrites sample timestamps or turns old rates fresh. Backend failures remain errors rather than measured zero.

Geometry does not include changing health, last-seen time, traffic rates, or the telemetry watermark in its content hash. Existing schema telemetry columns can be neutral in geometry batches and filled by the overlay path; their presence does not make them geometry revision inputs. Metrics continue through NATS JetStream and the configured telemetry reader; the layout worker creates no direct telemetry writes to CNPG or StarRocks.

Availability is a separate native index seeded through batches of at most 500 current inventory identities. Missing/deleted devices, unset availability and mapper-only sightings remain unknown. One supervised owner alternates bounded dirty-identity reads with rolling reconciliation, so missed hints cannot leave state permanently stale. Dirty retention is capped at 5,000 identities and 512 KiB; overflow requests reconciliation. Responses distinguish initial seeding, refreshing, current and stale source state and expose the conservative start time of the last completed scan. Owner restarts use a new opaque hexadecimal epoch; dispatch sequences prevent older observations replacing newer ones. A native admission permit lasts through execution and reply encoding even when its BEAM caller dies: a process DOWN message alone does not prove a dirty NIF has stopped.

### Decision: Integrate the tile client after #4749 and measure real-device acceptance

After #4749 lands, reuse its deck.gl 9.4 typed sublayers, WebGPU-only path, and per-edge procedural flow in TileLayer with OrthographicView. No renderer edits before that dependency. Viewport selection and bounded prefetch drive tile fetching; the browser does not receive the entire world graph. Picking uses stable identity and bounded details. Search flies to persistent coordinates and can enter a bounded ELK detail scene. Returning restores cached map tiles and camera.

Acceptance on the seeded 1M-device/at-least-2M-relation fixture requires all zooms obey feature and actual encoded-byte limits, membership conservation, exact coordinate stability across fresh deterministic runs/session reloads and 1% incremental additions, bounded dirty-tile sets, cached revisits with no fetch, and telemetry with zero geometry refetches. On real WebGPU with packet flow enabled: first usable frame <=3 seconds, pan/zoom >=30 FPS, hover/select <100 ms, and local visible-tile fetch plus decode p95 <=200 ms. Record GPU/device limits, fixture seed, budgets, payload sizes, concurrency, sampling method, and timings. SwiftShader and pure index tests do not satisfy real-device acceptance.

## Risks and remaining measured choices
- Integer placement stability does not prove tile query complexity, encoded-byte bounds, or browser performance. Measure each boundary independently.
- Dense components and crossing relations can defeat a naive spatial index. Test maximum-zoom overflow, giant fanout, and crossing-only segment queries.
- Copying the complete canonical graph into BEAM terms and then back into Rust can amplify peak memory. Prefer a core-owned resource path that consumes the typed Rust source and exports bounded results or persistence deltas; measure any remaining full-graph transfer.
- The selected maximum zoom, per-tile row/feature/byte limits, prefetch radius, low-zoom pregeneration cutoff, and cache entry/byte limits remain provisional until measured on the invented scale fixture.
- Publication retention must specify which accepted generations survive restart. Mutable active flags alone cannot reconstruct historical membership; retain generation deltas or explicitly retire old generation requests while in-flight immutable readers remain valid.
- The wider AGE extension retirement remains gated on migrating its active non-topology consumers in `replace-age-topology-with-dgraph`.

## Migration and rollout
1. Validate complete Dgraph source acquisition and preserve its existing domain admission behavior.
2. Add core-owned persistent layout resources and platform migrations with the Helm expected-version bump.
3. Integrate the measured Rust placement engine, immutable generation publication, restart recovery, and bounded spatial tile generation.
4. Add authenticated manifest/tile/details/search delivery, scope-safe ETags, dirty-tile invalidation, and separate bounded telemetry overlays.
5. After #4749 lands, integrate TileLayer, prefetch/LRU caching, picking/search, and bounded ELK detail entry/exit without editing a competing renderer.
6. Run the 1M-device membership, stability, all-zoom budget, dirty-tile, cache, and overlay tests; complete real-WebGPU acceptance with packet flow enabled.
7. Run strict validation for every touched pending change and `make test` with `--config=remote`; deliver the PR through no-mistakes. CNPG tests use only an invented srql-fixtures scratch database with verified cleanup. Live Dgraph verification uses only the separately authorized disposable fixture namespace.
