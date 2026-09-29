## Delivery status for #4774

The user confirmed the updated tile-engine scope. PR #4812 (the #4749 renderer dependency) is merged and integrated. The implementation now uses persistent server world coordinates, schema-3 quadtree tiles, separate health/flow overlays, and a WebGPU TileLayer overview with explicit bounded ELK detail scenes. The earlier semantic-only overview is superseded.

The integrated [scratch database workflow](https://carverauto.buildbuddy.io/invocation/20b4c301-e1e4-4d32-ab95-79dc21afb7e5) passed all eight core lanes, the selected Go/SRQL lanes, web topology lanes, actual Dgraph schema lifecycle, and the Dgraph/Oban world worker. Teardown and generation release passed; a separate database query verified zero remaining databases for this run. Dgraph fixture cleanup independently lists namespaces after deletion. Database tests use srql-fixtures scratch DB only; every fixture is invented.

The [client regression run](https://carverauto.buildbuddy.io/invocation/2e9b3e25-477e-4bab-bbd0-bba33ea4796b) passed the JavaScript unit suite and three WebGPU browser cases. They cover HTTP recovery, search, actual picking, bounded detail entry/return, scene-cache identity, and conditional refetch of exactly one visible dirty tile. Canvas sizing, duplicate scene fetches across tile levels, and invalidation-triggered extra prefetch were reproduced and repaired.

The shared invented million-device/two-million-relation generator passes the [layout and 1% growth regression](https://carverauto.buildbuddy.io/invocation/ebff9383-0c25-4bcd-961a-9c3e2300131d). Its production NIF/Arrow output is served over loopback HTTP to the real map renderer. Physical GPU results and their limitations are recorded in [the acceptance report](../../../docs/god-view-world-acceptance.md). The remote repository gate passed 367 targets with two skipped, and all three browser targets passed, at `f795ebe144`. The final tree at `b5e3e9cbb8` passed the full remote make (367 targets passed, two skipped, seven quality targets) and the guarded million-device scratch worker, which recorded persist 317,201 ms, publish 3,492 ms, reload 36,933 ms, index 3,793 ms, one zoom-16 tile query at 7,975 microseconds, and peak BEAM resident memory of 2,987,208 KiB with no manual statistics intervention.

## Remaining workstream completion gates

The current #4774 workstream is not complete until both independently tracked
proposals pass: `verify-topology-feature-parity` / #4908 (legacy behavior and bounded ELK)
and `prove-million-device-topology` / #4909 (real ingestion, SNMP overlays and hardware
WebGPU animation). Existing checked implementation/fixture tasks do not satisfy
those remaining gates. Dashboard generalization, spatial ingestion and VMS/NVR
have separate proposals and are not dependencies of this workstream.

## 1. Topology Contract

- [x] 1.1 Implement and round-trip schema-3 tile and bounded detail payloads, including UInt16 local coordinates with affine metadata, local UInt32 endpoints, counts, budgets, and lazy details.
- [x] 1.2 Integrate server world-coordinate authority for the overview and explicit bounded ELK detail coordinate spaces; preserve map state on detail entry/exit.
- [x] 1.3 Specify separate layout version, immutable publication generation, tile content revision, and telemetry overlay identity, with scope-safe caching and targeted invalidation.
- [x] 1.4 Specify the authenticated tile HTTP contract, manifest/search/details, bounded channel invalidations, and independent overlays in the existing carrier-scale deltas.
- [x] 1.5 Build immutable Atlas indexes during canonical runtime refresh and return bounded semantic memberships through AtlasStore, reusable for detail navigation. Superseded within this change by the schema-3 tile engine: the semantic-levels serving surface (TopologyChannel modes, the snapshot revisions endpoint, AtlasStore, and runtime Atlas publication) was removed; detail navigation reads persisted-world pages instead.
- [x] 1.6 Page canonical Dgraph relations and isolated Device vertices through one read-only transaction and pass actual loopback gRPC regressions for receive limits, raw UID progress, stable timestamps, and later-page atomic failure. Live backend validation remains in 1.8.
- [x] 1.7 Validate atomic watched-detail selection, bounded scope-authorized enrichment, final content/structure revisions, and HTTP/channel revision metadata with a separate canonical revision. The watched-level channel and revisions metadata endpoints were later removed with the semantic-levels surface; bounded enrichment and revision fingerprinting survive in detail scenes.
- [x] 1.8 Validate canonical isolated vertices through actual Dgraph queries and deliver bounded geometry through the schema-3 encoder.
- [x] 1.9 Revalidate the typed paged graph response, AtlasSource adapter, and runtime source-failure/restart retention after integration (`paging.rs`, `AtlasSourceTest`, and `RuntimeGraphConcurrencyTest` passed in the repository gate). The AtlasSource adapter and its test were later removed with the semantic-levels surface; the typed paged graph response and RuntimeGraph restart retention remain.

## 2. Discovery and Projection Semantics
- [x] 2.1 Preserve canonical topology completeness while deriving infrastructure-first importance, stable site/component grouping, and attachment summaries for the tile world.
- [ ] 2.2 Quarantine unresolved sightings, null-neighbor rows, and duplicate identity fragments while preserving diagnostics. This remains outside #4774.
- [x] 2.3 Preserve every admitted endpoint through correct aggregate membership, coordinate search, and bounded detail/member pages.

## 3. UI Reliability and Readability
- [x] 3.1 Bootstrap the layout manifest and visible tiles over HTTP independently of channel timing; retain the last compatible map on failure.
- [x] 3.2 Bound map labels by the 128-glyph tile limit and label byte limit, and reuse bounded ELK scene label admission; never run a whole-world browser layout.
- [x] 3.3 Keep detail expansion bounded: one accepted scene, at most one pending replacement, 128 nodes/256 relations/262,144 bytes per scene, and four cached scene pages; overflow uses explicit pages or summaries (`WorldSceneTest`, native details, and browser entry/return).
- [x] 3.4 After #4749 lands, integrate deck.gl TileLayer with OrthographicView and its existing typed WebGPU sublayers.
- [x] 3.5 Restrict existing ELK adapters to bounded detail scenes. Audit and reuse the current forest/radial code where useful; its presence does not satisfy persistent world-layout work.
- [x] 3.6 Keep map and detail coordinate/cache identities separate and restore only compatible accepted scenes after errors.
- [x] 3.7 Add stable-identity picking and coordinate search, including devices still represented by aggregates at maximum zoom.
- [x] 3.8 Make map Fit use the declared world/container extent and detail Fit include the full bounded scene inside the measured safe viewport.
- [x] 3.9 Render bounded bundles and clipped relation segments with stable picking identity and continuous procedural packet flow; resolve bundle metadata and bounded member scenes through the accepted tile selector with publication-bound continuation.
- [x] 3.10 Expose recoverable tile, overlay, and detail-layout failures without replacing coherent last-good state.
- [x] 3.11 Add bounded prefetch/LRU caching, in-flight request deduplication, and cached revisits/detail return with no geometry fetch; swap coherent same-zoom coverage without incompatible parent/child boundary portals.
- [x] 3.12 Apply separate bounded telemetry overlays, reject stale geometry/overlay results, and reconcile sequence gaps without geometry refetch.
- [x] 3.13 Refetch only visible dirty tiles, reconcile channel resets/reconnects, and bound initial acknowledgements as well as invalidation messages.

- [x] 3.14 Share and restore versioned map locations and stable device links; reject incompatible layouts explicitly and reuse a renderer-independent location contract for future SDK integration. Remote million-world browser proof: `1494fd57-1471-4b3e-9bf7-394fc1582f79`.

## 4. Status and Diagnostics
- [ ] 4.1 Replace heuristic three-hop Affected propagation with evidence-backed impact semantics. Outside #4774.
- [ ] 4.2 Expose quality counters for unresolved identities, duplicate identity collisions, attachment drops, and bootstrap failures. Outside #4774.
- [ ] 4.3 Add diagnostics for quarantined identities without promoting them into the default backbone. Outside #4774.

## 5. Verification
- [x] 5.1 Add invented regressions for dense fanout, giant components, isolated vertices, tile-boundary ownership, long crossing-only relations, and maximum-zoom overflow.
- [x] 5.2 Integrate an independently invented seeded 1,000,000-device/at-least-2,000,000-relation hierarchy; record placement, persistence, tile-index, candidate-query, memory, and encoded-byte measurements.
- [x] 5.3 Run strict OpenSpec validation for the carrier change and every touched pending duplicate delta.
- [x] 5.4 Verify fresh-layout determinism, session persistence, exact integer stability after 1% additions, tombstone/reappearance, and separate UInt16 wire precision bounds across zooms.
- [x] 5.5 Verify real WebGPU with packet flow enabled: first frame <=3 seconds, pan/zoom >=30 FPS, hover/select <100 milliseconds, and local tile fetch plus decode p95 <=200 milliseconds. Record GPU limits, fixture seed, budgets, and timing method; SwiftShader alone is insufficient.
- [x] 5.6 Verify all-zoom device-count conservation, every tile's actual feature/byte bounds, targeted dirty sets, cache revisits with no fetch, and telemetry updates with zero geometry refetch.
- [x] 5.7 Round-trip tile/detail metadata, UInt16 affine positions, local endpoints/proxies, and columnar/lazy details through the schema-3 NIF encoder and client decoder.
- [x] 5.8 Run make test with --config=remote on the final tree before the PR. Deliver every PR through no-mistakes with the srql-fixtures-only database restriction in the run intent.
- [x] 5.9 Pass pure semantic Atlas tests using an invented 200,000-device/400,000-relation graph. Historical only: those tests were removed with the semantic-levels surface and are not in the current suite. This check does not replace the open million-device tile acceptance above.
- [ ] 5.10 Complete `prove-million-device-topology`; its own checklist owns the real-ingestion million-device proof. Mocked overlay fixtures and scratch layout benchmarks do not satisfy it.

## 6. Persistent World and Tile Engine
- [x] 6.1 Add core Ash layout/head/device-position/relation-binding resources and platform migrations with the Helm core migration expected-version bump.
- [x] 6.2 Integrate the isolated Rust hierarchical Morton placement proof into the core-owned engine/NIF, retaining existing positions, parents, bounds, and reserved slots on incremental changes.
- [x] 6.3 Add Oban generation coordination, staged full relayout, compare-and-swap publication, coherent bootstrap/restart, old-reader retention, and failed-candidate cleanup.
- [x] 6.4 Build a quadtree node and relation-intersection index; prove high-zoom queries avoid canonical-size scans and find crossing edges whose endpoints lie outside the tile.
- [x] 6.5 Integrate importance/min_zoom, stable aggregates and counts, stable-ID bundles, fixed shared side/corner portals, owned endpoint connectors with phase continuity, and over-budget generalization including at maximum zoom.
- [x] 6.6 Enforce actual schema-3 encoded-byte budgets as well as cardinality limits; measure final limits rather than treating provisional numbers as calibrated.
- [x] 6.7 Pregenerate low-zoom tiles and implement bounded lazy high-zoom caching with geometry-only ETags and current authority checked before conditional responses.
- [x] 6.8 Maintain dirty-tile dependencies for changed nodes, aggregate ancestry, and old/new relation geometry; retain untouched tile revisions across publication generations.
- [x] 6.9 Serve separate bounded initial/live telemetry overlays through the existing JetStream-backed telemetry path, with no direct metric writes from layout or tile code.
