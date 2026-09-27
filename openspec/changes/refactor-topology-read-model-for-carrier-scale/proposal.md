# Change: Refactor topology read model for carrier scale

## Why
God-View must remain useful at 200,000 to 1,000,000 or more devices. Sending and laying out the complete canonical graph in the browser cannot meet that scale. The default overview needs persistent coordinates, bounded spatial delivery, and separate live telemetry while every admitted device remains reachable through search and bounded detail.

[Issue #4774](https://github.com/carverauto/serviceradar/issues/4774) and its confirmed scope revision replace the earlier semantic-level-only plan. This proposal amends the existing carrier-scale change rather than creating a parallel design.

## What Changes
- **BREAKING architecture amendment:** server-authored persistent world coordinates become the overview geometry authority. ELK remains only for explicitly entered bounded device-neighborhood, component/aggregate-member, and rendered-bundle-member detail scenes.
- Add a core-owned Rust world-layout/tile engine and an Oban-coordinated persistence/publication lifecycle. Stable `layout_version` identifies the coordinate space; immutable publication generations and per-tile content revisions have separate identities.
- Persist device positions and relation bindings using platform Elixir migrations and the corresponding Helm migration expected-version bump. Incremental changes preserve existing placements; full relayout is explicit and versioned.
- Serve quadtree z/x/y tiles with importance-based visibility, stable aggregates, correct member counts, low-zoom edge bundles, clipped long relations, and hard feature/encoded-byte budgets. Overflow remains represented and reachable.
- Extend #4749 schema 3 with tile identity, budgets, and explicit affine transforms for UInt16 tile-local coordinates. Keep columnar details, local UInt32 endpoints, and lazy irregular details.
- Add authorized HTTP tile delivery with scope-safe ETags, bounded search/details, precomputed low-zoom tiles, lazy high-zoom caching, and dirty-tile channel invalidation.
- Separate state and packet-flow overlays from geometry revisions so telemetry never refetches geometry.
- After #4749 lands, use TileLayer in OrthographicView with bounded prefetch/LRU caching, picking, coordinate search, and explicit bounded ELK drill-down/return.
- Verify deterministic and incremental placement, all-zoom membership conservation and budgets, targeted invalidation, cached revisits, and real-WebGPU performance with packet flow enabled on an invented 1M-device/at-least-2M-relation fixture.

## Impact
- Affected specs: `topology-god-view`, `build-web-ui`, and `network-discovery`.
- Core: Dgraph canonical reader, core-owned Rust/NIF engine, NetworkDiscovery resources, Oban generation worker, platform migrations, and Helm migration version.
- Web: topology runtime/cache, tile/detail/search controllers, topology channel, and schema-3 tile integration.
- Client after #4749: God-View tile lifecycle, camera/navigation, bounded detail adapters, and existing typed WebGPU sublayers.
- Existing pending ELK and cluster-layout deltas are scoped to bounded detail scenes so archiving cannot restore overview frontend-layout ownership.

## Dependencies and scope
- #4749 supplies schema 3, typed decoding, WebGPU-only rendering, deck.gl 9.4, and procedural per-edge packet flow. Reuse those internals; do not edit their renderer files before the dependency lands.
- The complete paged Dgraph source, immutable semantic Atlas index, scoped detail reader, and authorization/watch checks are reusable foundation. Their passing checks do not establish tile-engine acceptance.
- `refactor-god-view-elk-scene` owns coherent geometry within bounded ELK detail scenes. This change owns the persistent world, tiles, publication, caches, overlays, and map/detail navigation boundary.
- Quarantine diagnostics and evidence-backed `Affected` behavior remain separate carrier-scale work (tasks 2.2 and 4.x), outside #4774. The SDK and #4748 are also outside this delivery.
- Global AGE extension removal remains blocked on its remaining consumers in `replace-age-topology-with-dgraph`; this tile engine uses Dgraph topology.
