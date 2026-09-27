## Delivery status for #4774

The user confirmed the revised tile-engine scope: persistent server world coordinates, quadtree geometry tiles, separate telemetry, and a TileLayer client. The earlier semantic-only overview and browser-global ELK plan are superseded. Checked foundation or contract tasks below do not imply implemented tiles or measured browser behavior.

Implemented foundation includes the immutable semantic Atlas index, bounded detail membership selection before authorized inventory enrichment, atomic watched selection, final detail revisions, metadata-only HTTP/channel mode, and current human authorization checks. Four real-database reader/channel/HTTP tests passed in 90.7 seconds against invented srql-fixtures scratch data; DROP and a fresh query verified absence, and temporary credentials were removed. Pure Atlas checks passed on an invented 200,000-device/400,000-relation graph.

The complete Dgraph source reader now pages vertices and relations through one read-only transaction, adapts oversized responses, and rejects protocol/snapshot failures atomically. Existing orphan/no-identity edge admission still filters domain rows while raw rows advance the cursor. [Actual loopback gRPC protocol tests passed](https://carverauto.buildbuddy.io/invocation/e79e0e20-1ad8-47f0-a325-c09bbde3ef22), including receive-limit and later-page failures; live Dgraph verification remains open.

The Rust engine passed [seven remote Bazel checks](https://carverauto.buildbuddy.io/invocation/0ca01302-0f5f-4122-ad85-2b06d4ed2098), covering placement and bounded tile geometry including crossing, corner, endpoint-owner, and phase cases. On the invented 1,000,000-device/2,000,000-relation fixture, fresh placement took 1,952 ms, 1% incremental growth 3,231 ms, index construction 2,764 ms, and overview generation 230 ms. The 64 sampled tile-generation calls at zooms 4, 8, 12, and 16 had p95 4.635 ms. These remote-executor pure Rust timings exclude persistence, encoding, HTTP/decode, and browser work and do not establish exhaustive all-zoom acceptance. The engine, core-owned NIF, persistence resources, migration, and bounded Oban worker are now integrated. HTTP/channel and cache lifecycle code is present but is not yet enabled as the overview runtime. The combined Dgraph/database lifecycle, encoded tile budgets, cache/transport integration, overlays, and browser acceptance remain open.

The pre-paging server foundation passed `make test` with `--config=remote`: [351 tests passed, two skipped](https://carverauto.buildbuddy.io/invocation/fa2af5b1-2d16-4723-b15b-0c9e94e1fc03), exit 0. A later workspace Cargo check stopped on unrelated existing `reqsign-azure-storage` undeclared test dependencies. The final changed tree requires the complete repository gate. Database validation uses only an invented srql-fixtures scratch database; live Dgraph verification uses the separately authorized disposable fixture namespace. Every PR goes through no-mistakes.

The native detail/health bridges and process-wide admission guards are implemented. [The native guard check and core shard passed](https://carverauto.buildbuddy.io/invocation/2e5f56b0-4538-4d54-8938-249bd3205489): five native tests and 266 core tests. Deliberately releasing the permit early failed the actual concurrent-work admission test before restoration. The availability owner and bounded inventory hints passed [949 inventory tests, 324 web tests and the integration-routing gate](https://carverauto.buildbuddy.io/invocation/6c4d2778-bde2-4e20-8487-f457a37a0a68). These checks compile the new owner and exercise hint delivery; actual database source reads and installed world/cache/overlay lifecycle proof remain pending. The overview runtime stays disabled until the schema-3 tile producer is integrated after #4749.

The integrated server checkpoint `e4a7be0c0c` passed [make test with remote execution](https://carverauto.buildbuddy.io/invocation/6377c40d-2b7b-455f-97ab-9095b336e75c): 356 targets passed and two were skipped. This includes bounded retention and typed exact-pair rate compilation; it excludes database integration tests. The native picking bridge passed [five native and 270 core tests](https://carverauto.buildbuddy.io/invocation/cc44fef4-51fe-4dae-82af-0c0c7a61221c). Picking HTTP and bounded-scene enrichment then compiled with [324 web tests passing](https://carverauto.buildbuddy.io/invocation/24de240a-8866-4e73-a3de-e238ed0a3c22). Actual installed-cache picking/scene delivery remains pending; no synthetic cache receipt is used as a substitute for the real schema-3 producer.

The bounded overlay read model and owner are implemented separately from geometry, with exact-pair SRQL reads, complete-bundle coverage, producer provenance, global interface-degree requirements and generation fences. The final focused remote run passed [330 web tests with zero failures](https://carverauto.buildbuddy.io/invocation/c85c4ae2-0362-4f53-b21a-665e116c5743). A deliberate partial-bundle mutation failed before exact source restoration, and a real PubSub regression reproduced the missing durable-publication handler before its fix. Actual backend rate queries, installed schema-3 cache/overlay delivery and browser behavior remain pending. Tasks 3.12 and 6.9 remain open.

## 1. Topology Contract

- [ ] 1.1 Implement and round-trip schema-3 tile and bounded detail payloads, including UInt16 local coordinates with affine metadata, local UInt32 endpoints, counts, budgets, and lazy details.
- [ ] 1.2 Integrate server world-coordinate authority for the overview and explicit bounded ELK detail coordinate spaces; preserve map state on detail entry/exit.
- [x] 1.3 Specify separate layout version, immutable publication generation, tile content revision, and telemetry overlay identity, with scope-safe caching and targeted invalidation.
- [x] 1.4 Specify the authenticated tile HTTP contract, manifest/search/details, bounded channel invalidations, and independent overlays in the existing carrier-scale deltas.
- [x] 1.5 Build immutable Atlas indexes during canonical runtime refresh and return bounded semantic memberships through AtlasStore, reusable for detail navigation.
- [x] 1.6 Page canonical Dgraph relations and isolated Device vertices through one read-only transaction and pass actual loopback gRPC regressions for receive limits, raw UID progress, stable timestamps, and later-page atomic failure. Live backend validation remains in 1.8.
- [x] 1.7 Validate atomic watched-detail selection, bounded scope-authorized enrichment, final content/structure revisions, and HTTP/channel revision metadata with a separate canonical revision.
- [ ] 1.8 Validate canonical isolated vertices through actual Dgraph queries and deliver bounded geometry through the schema-3 encoder.
- [ ] 1.9 Revalidate the typed paged graph response, AtlasSource adapter, and runtime source-failure/restart retention after integration.

## 2. Discovery and Projection Semantics
- [ ] 2.1 Preserve canonical topology completeness while deriving infrastructure-first importance, stable site/component grouping, and attachment summaries for the tile world.
- [ ] 2.2 Quarantine unresolved sightings, null-neighbor rows, and duplicate identity fragments while preserving diagnostics. This remains outside #4774.
- [ ] 2.3 Preserve every admitted endpoint through correct aggregate membership, coordinate search, and bounded detail/member pages.

## 3. UI Reliability and Readability
- [ ] 3.1 Bootstrap the layout manifest and visible tiles over HTTP independently of channel timing; retain the last compatible map on failure.
- [ ] 3.2 Enforce label/readability budgets for map tiles and bounded detail scenes without an unbounded browser layout.
- [ ] 3.3 Keep all concurrent detail expansions within shared node, relation, member, and byte limits; overflow uses explicit pages or summaries.
- [ ] 3.4 After #4749 lands, integrate deck.gl TileLayer with OrthographicView and its existing typed WebGPU sublayers.
- [ ] 3.5 Restrict existing ELK adapters to bounded detail scenes. Audit and reuse the current forest/radial code where useful; its presence does not satisfy persistent world-layout work.
- [ ] 3.6 Keep map and detail coordinate/cache identities separate and restore only compatible accepted scenes after errors.
- [ ] 3.7 Add stable-identity picking and coordinate search, including devices still represented by aggregates at maximum zoom.
- [ ] 3.8 Make map Fit use the declared world/container extent and detail Fit include the full bounded scene inside the measured safe viewport.
- [ ] 3.9 Render bounded bundles and clipped relation segments with stable picking identity and continuous procedural packet flow.
- [ ] 3.10 Expose recoverable tile, overlay, and detail-layout failures without replacing coherent last-good state.
- [ ] 3.11 Add bounded prefetch/LRU caching, in-flight request deduplication, and cached revisits/detail return with no geometry fetch; swap coherent same-zoom coverage without incompatible parent/child boundary portals.
- [ ] 3.12 Apply separate bounded telemetry overlays, reject stale geometry/overlay results, and reconcile sequence gaps without geometry refetch.
- [ ] 3.13 Refetch only visible dirty tiles, reconcile channel resets/reconnects, and bound initial acknowledgements as well as invalidation messages.

## 4. Status and Diagnostics
- [ ] 4.1 Replace heuristic three-hop Affected propagation with evidence-backed impact semantics. Outside #4774.
- [ ] 4.2 Expose quality counters for unresolved identities, duplicate identity collisions, attachment drops, and bootstrap failures. Outside #4774.
- [ ] 4.3 Add diagnostics for quarantined identities without promoting them into the default backbone. Outside #4774.

## 5. Verification
- [ ] 5.1 Add invented regressions for dense fanout, giant components, isolated vertices, tile-boundary ownership, long crossing-only relations, and maximum-zoom overflow.
- [ ] 5.2 Integrate an independently invented seeded 1,000,000-device/at-least-2,000,000-relation hierarchy; record placement, persistence, tile-index, candidate-query, memory, and encoded-byte measurements.
- [x] 5.3 Run strict OpenSpec validation for the carrier change and every touched pending duplicate delta.
- [ ] 5.4 Verify fresh-layout determinism, session persistence, exact integer stability after 1% additions, tombstone/reappearance, and separate UInt16 wire precision bounds across zooms.
- [ ] 5.5 Verify real WebGPU with packet flow enabled: first frame <=3 seconds, pan/zoom >=30 FPS, hover/select <100 milliseconds, and local tile fetch plus decode p95 <=200 milliseconds. Record GPU limits, fixture seed, budgets, and timing method; SwiftShader alone is insufficient.
- [ ] 5.6 Verify all-zoom device-count conservation, every tile's actual feature/byte bounds, targeted dirty sets, cache revisits with no fetch, and telemetry updates with zero geometry refetch.
- [ ] 5.7 Round-trip tile/detail metadata, UInt16 affine positions, local endpoints/proxies, and columnar/lazy details through the schema-3 NIF encoder and client decoder.
- [ ] 5.8 Run make test with --config=remote on the final tree before the PR. Deliver every PR through no-mistakes with the srql-fixtures-only database restriction in the run intent.
- [x] 5.9 Pass pure semantic Atlas tests using an invented 200,000-device/400,000-relation graph. This historical foundation check does not replace the open million-device tile acceptance above.

## 6. Persistent World and Tile Engine
- [ ] 6.1 Add core Ash layout/head/device-position/relation-binding resources and platform migrations with the Helm core migration expected-version bump.
- [ ] 6.2 Integrate the isolated Rust hierarchical Morton placement proof into the core-owned engine/NIF, retaining existing positions, parents, bounds, and reserved slots on incremental changes.
- [ ] 6.3 Add Oban generation coordination, staged full relayout, compare-and-swap publication, coherent bootstrap/restart, old-reader retention, and failed-candidate cleanup.
- [ ] 6.4 Build a quadtree node and relation-intersection index; prove high-zoom queries avoid canonical-size scans and find crossing edges whose endpoints lie outside the tile.
- [ ] 6.5 Integrate importance/min_zoom, stable aggregates and counts, stable-ID bundles, fixed shared side/corner portals, owned endpoint connectors with phase continuity, and over-budget generalization including at maximum zoom.
- [ ] 6.6 Enforce actual schema-3 encoded-byte budgets as well as cardinality limits; measure final limits rather than treating provisional numbers as calibrated.
- [ ] 6.7 Pregenerate low-zoom tiles and implement bounded lazy high-zoom caching with geometry-only ETags and current authority checked before conditional responses.
- [ ] 6.8 Maintain dirty-tile dependencies for changed nodes, aggregate ancestry, and old/new relation geometry; retain untouched tile revisions across publication generations.
- [ ] 6.9 Serve separate bounded initial/live telemetry overlays through the existing JetStream-backed telemetry path, with no direct metric writes from layout or tile code.
