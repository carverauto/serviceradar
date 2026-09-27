# God View world-tile validation

This report covers #4774's invented million-device tile fixture. It does not use
captured deployment data. The generator creates 1,000 invented components with
1,000 devices each and two relations per device; identities are generated under
`example.test`. It is deterministic and uses no external input or random seed.

## Workload and ownership

`rust/topology-atlas/fixtures/hierarchy.rs` owns the shared 1,000,000-device /
2,000,000-relation hierarchy. The existing Rust layout test also uses this
fixture for stable placement and 1% growth. The export target runs the production
layout, streams positions and relations into the packaged core NIF, and encodes
actual schema-3 tiles with the web producer. No browser fixture substitutes JSON
for the tile wire format.

The browser exercise serves those immutable bytes over a real loopback HTTP
server. Only the Phoenix channel is simulated. It opens the world at zoom 0,
flies to two searched devices, opens bounded detail scenes, returns to retained
geometry, pans, uses wheel zoom, changes health, and picks actual geometry with
packet flow enabled. Missing fixture tiles, browser errors, disabled packet flow,
wrong aggregate totals, and unexpected geometry requests fail the exercise.

The fixture includes every tile at zooms 0 through 3, neighborhoods around the
selected devices through zoom 16, and the tiles crossed by the search flights.
It is not an exhaustive materialization of the entire quadtree. Dense-fanout
all-zoom conservation and crossing-only relations have separate native tests;
server generation enforces feature and actual encoded-byte limits on every call.

## Physical GPU measurements

The validation device reports Apple Metal 3, a non-fallback WebGPU adapter,
`maxVertexBuffers=8`, and `maxBufferSize=4294967292`. The browser viewport is
1280 by 720 CSS pixels at DPR 1. Geometry is bounded to 128 glyph rows, 256 edge
rows and 262,144 encoded bytes per tile; client cache and viewport limits are
64 tiles and 32 MiB with four concurrent fetches.

The normal visible Chrome run measured 409 ms to usable geometry, 119 ms p95
tile fetch/decode, and 1.1 ms p95 picking. Combined pan/zoom averaged 27.2 FPS.
A separate empty-page animation-frame measurement on the same host was 30.0 FPS.
The ordinary-window run therefore does not establish the >=30 FPS acceptance.

A throughput run disables Chrome's frame-rate limit. It waits for WebGPU queue
completion rather than counting only CPU submissions, records the complete
pan/zoom interval without retaining only its fast tail, and keeps packet flow
on. It measured 317 ms to first usable frame, 57.2 ms p95 tile fetch/decode and
5.5 ms p95 picking over 207 geometry requests. The GPU-completion throughput was
above 30 frames/second. This is rendering capacity, not a claim about physical
display presentation or the normal-window result above. Cold tile creation still
has shader-assembly pauses; the observed slowest frame gaps were about 104 ms.
Skipping empty tile sublayers subsequently reduced normal-window tile decode
p95 to 9.7 ms, with 0.8 ms p95 picking and a 316 ms first usable frame, but the
normal-window pan/zoom average remained below the SLO at 27.6 FPS.

Native fixture measurements on RBE were 1,126 ms for fresh placement, 19,749 ms
for NIF import/index creation, and 14,814 ms for the selected tile encoding set.
These exclude database persistence and browser work. The real database worker
proof uses a smaller 503-to-504-device fixture to verify atomic publication,
follow-up scheduling, persisted identities, reload and stable coordinates.
Million-device database persistence time and peak resident memory remain
unmeasured; do not infer them from native layout timings.

## Reproduction

Build everything on RBE. The declared write-back targets provide artifacts for
a physical browser without reading Bazel's output cache:

```
bazel run -c opt --config=remote //elixir/web-ng:million_world_browser_fixture_export
bazel run -c opt --config=remote //elixir/web-ng/assets:world_gpu_smoke
bazel test -c opt --config=remote //elixir/web-ng/assets:million_world_browser_test
```

The last target uses the pinned SwiftShader executor to check functional browser
behavior, not the physical GPU SLOs. The same `god_view_million_browser.cjs`
executable supports `GOD_VIEW_PHYSICAL_GPU=1` with the exported JSON and HTML as
its two arguments. It launches installed Chrome with normal frame scheduling, reports the adapter
and timing method, and enforces performance thresholds. `GOD_VIEW_UNCAPPED=1`
opts into the separate throughput diagnostic; `GOD_VIEW_HEADLESS=1` selects
headless Chrome while retaining the physical adapter requirement. `PLAYWRIGHT_MODULE` can point to an
already-installed Playwright module; this browser-only step builds no assets.
`GOD_VIEW_CPU_PROFILE` optionally records a Chrome CPU profile for this workload.

The exported JSON/HTML and CPU profiles are disposable artifacts and must not be
committed. Full `make test` and no-mistakes remain required before a PR.
