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
server. The Phoenix channel and telemetry overlays are simulated; this exercise
does not prove SNMP ingestion through JetStream/EventWriter. It opens the world at zoom 0,
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

The visible Chrome run passed all four SLOs with normal frame scheduling and
packet flow enabled: 293 ms to usable geometry, 52.3 FPS across the complete
pan/zoom interval, 1.4 ms p95 picking (20 real picks), and 64.1 ms p95 tile
fetch/decode (247 timed samples). It opened zoom 0 with a total of 1,000,000 devices,
entered two detail scenes, and reported no renderer errors or missing tiles.
Frame p95 was 33.3 ms; the slowest cold-tile frame gap was 122.6 ms. FPS counts
completed WebGPU frames rather than only CPU submissions; it is not a direct
measurement of physical display presentation.

Chrome Energy Saver initially capped an empty page at 30 FPS while this laptop
was at 7% battery, and the map averaged 27.6 FPS. Disabling Energy Saver in an
owned disposable browser profile restored the empty-page baseline to 60 FPS and
produced the passing result above. The regular browser profile was untouched.
The passing run did not disable Chrome's frame-rate limit. An uncapped throughput
mode remains available as a diagnostic, but is not the acceptance evidence.

After the timed interaction, the same exercise compared decoded positions against the
canonical integer coordinates for two independently selected devices. Each was
visible at nine zoom levels; maximum error was half one tile-local UInt16 unit,
below the one-unit bound. These probes made 32 additional geometry requests
after timing was complete. This checks producer-to-decoder wire precision
separately from native exact-integer placement stability.

Native fixture measurements on RBE were 1,126 ms for fresh placement, 19,749 ms
for NIF import/index creation, and 14,814 ms for the selected tile encoding set.
These exclude database persistence and browser work. The real database worker
proof uses a smaller 503-to-504-device fixture to verify atomic publication,
follow-up scheduling, persisted identities, reload and stable coordinates.
The same worker then persisted the invented 1,000,000-position and
2,000,000-relation hierarchy on a scratch database and reloaded it.
`//rust/dgraph-topology:world_worker_test` passed in 386.7s on hosted run
[4751bf7b-5a71-46eb-a07c-90016b563dcd](https://carverauto.buildbuddy.io/invocation/4751bf7b-5a71-46eb-a07c-90016b563dcd)
at commit `b5e3e9cbb8`. The test log recorded persist 317,201 ms, publish
3,492 ms, reload 36,933 ms, index 3,793 ms, and one zoom-16 tile query at
7,975 microseconds. Peak BEAM resident memory was 2,987,208 KiB. Suite, observer,
teardown, and generation release all exited 0, with zero remaining scratch
databases and no manual statistics intervention.

### Stale-statistics cursor regression

An earlier million-device reload selected a plan that scanned all 2,000,000
relations per page through an endpoint index, spending 266 seconds on relation
reads against the unchanged 300-second production deadline. The added active
`(layout_version, relation_id)` cursor index alone did not fix it: PostgreSQL had
not refreshed its table statistics after the bulk staging, so an independent
scratch plan still scanned the 2M rows. Running `ANALYZE` on the relation
table switched an empty tail-cursor probe to the cursor index in 0.076 ms with
4 buffers, versus 512 ms and 503,339 buffers. This diagnostic probe did not
return a full 5,000-row page. Full-layout activation now
refreshes planner statistics for both tables before acquiring the active-head
lock, so readers keep serving the previous publication during the maintenance
operation and a fresh bulk load can use the bounded seek immediately. No
production timeout was increased.

## Reproduction

### Shared locations and address-bar updates

The extended remote browser exercise
[2d622dfb-5766-4384-8e78-4added2798ff](https://carverauto.buildbuddy.io/invocation/2d622dfb-5766-4384-8e78-4added2798ff)
passed with real pan/wheel interactions, debounced center/zoom query parameters,
preserved browser history state, shared-location reload across a new publication,
invalid/incompatible link handling and stable device lookup. Compact links use
`layout`, `x`, `y` and `z`, with at most one decimal for coordinates and three
for zoom. Fractional legacy `map_*` links restore their camera and canonicalize
to that bounded precision; unrelated query parameters survive. Its telemetry overlay
and channel remain simulated. This is functional SwiftShader proof, not a new
physical-GPU performance measurement or a real SNMP-ingestion test.

The same source tree passed the
[remote repository gate](https://carverauto.buildbuddy.io/invocation/a982b070-e1bf-45dc-a584-6c5669ed43d8):
367 tests passed and two platform-specific Swift targets were skipped.

### Commands

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
and timing method, and enforces performance thresholds. Set
`GOD_VIEW_ENERGY_SAVER_OFF=1` for the measured full-performance condition: the
executable disables Energy Saver through Chrome settings in its own temporary
profile, then deletes that profile on exit. Normal frame scheduling is retained.
`GOD_VIEW_UNCAPPED=1`
opts into the separate throughput diagnostic; `GOD_VIEW_HEADLESS=1` selects
headless Chrome while retaining the physical adapter requirement. `PLAYWRIGHT_MODULE` can point to an
already-installed Playwright module; this browser-only step builds no assets.
`GOD_VIEW_CPU_PROFILE` optionally records a Chrome CPU profile for this workload.

The exported JSON/HTML and CPU profiles are disposable artifacts and must not be
committed. The [remote repository gate](https://carverauto.buildbuddy.io/invocation/f7274971-4a46-4a06-9172-e264f2f4b735)
passed `make test` (367 targets passed, two skipped), followed by all three
WebGPU/browser acceptance targets at commit `f795ebe144`. The final tree at
`b5e3e9cbb8` re-ran the full remote `make test` (367 targets passed, two
skipped, seven quality targets passed) and the guarded million-device worker
above with no manual statistics intervention.

The [Fit navigation regression](https://carverauto.buildbuddy.io/invocation/dd7a6350-7c14-4e9a-bf56-1e8c3c17a350)
passed all three WebGPU cases after first reproducing the failure: Fit in an open
detail scene used to discard that scene because the overview also handled the
reset event. The overview now leaves fitting to the active detail renderer; Fit
on the map restores the fixed world extent.
