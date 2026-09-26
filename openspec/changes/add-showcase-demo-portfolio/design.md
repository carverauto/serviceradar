## Context

Every demo follows one pattern:

1. A Wasm plugin running on an agent in the `demo` namespace emits devices,
   metrics, events and (for video demos) camera descriptors.
2. The normal pipeline lands them: inventory through `DeviceDiscoveryIngestor`
   and DIRE, metrics through JetStream and EventWriter, events through
   `events.internal.*` into the stateful alert engine, camera descriptors
   through `Camera.InventoryIngestor`.
3. A signed dashboard package reads it all back as SRQL frames and tells the
   story: map -> asset -> live signal -> incident -> drill-down.

The survey behind this change found these constraints in the current platform:

- **Check runs are stateless.** Each `run_check` gets a fresh wazero module
  (default 60 s interval, 10 s timeout). No KV, no globals survive.
- **Result and telemetry limits:** 2 MiB result, 256 records per telemetry
  batch, 64 MiB Wasm.
- **Metrics are rejected in the result payload**; they must go through
  `emit_telemetry`, which is the JetStream-first path the hard rules require.
- **Device coordinates** land in device metadata (`latitude`/`longitude`), not
  columns. Wi-Fi sites have real coordinate columns via
  `serviceradar.wifi_map.batch.v1`.
- **Plugins cannot emit topology.** Edges come only from mapper results.
- **The SDK alert hint (`alert_hint`/`condition_id`) is not consumed** by core;
  events drive alerts only through event-signal rules.
- **Camera streams in practice use the agent's native RTSP reader** (H.264
  only); the Wasm stream bridge is not wired to assignments. A replayed RTSP
  source only needs a descriptor with a reachable `rtsp_url`.
- **Dashboards have no video API**, the page CSP has `media-src 'none'`,
  `camera_relay_webrtc_enabled` defaults to false, and there is no SRQL camera
  entity. Frame refresh is hardcoded to 15 s. The dev harness logs
  `srql.update` but does not filter fixtures. The SDK map helpers assume a
  Mapbox basemap.
- **The Rust SDK lags the Go SDK**: no RTSP over host TCP, no TLS, no
  `status_body` HTTP mode, `wasm32-unknown-unknown` target (so
  `Instant::now()` / `OffsetDateTime::now_utc()` likely panic and there is no
  sleep), private `http` module, missing builders and packaged examples.

## Goals / Non-Goals

- Goals:
  - Self-running demos that look like product, never need a presenter to
    trigger anything, and survive being left alone for weeks in `demo`.
  - Each demo also runs on a laptop from fixtures (`npm run dev`) with no live
    ServiceRadar.
  - Every platform gap a demo hits is fixed in the product or SDK, not worked
    around inside the demo.
  - Rust SDK parity with Go, proven by tests rather than asserted.
- Non-Goals:
  - A video management system. A multiview of a handful of tiles is the ceiling.
  - Faithful Modbus/DNP3/IEC-104 stacks. Registers are simulated; the pitch is
    that the real adapter uses the same allowlisted TCP proxy.
  - Shipping any demo artifact to customers or in a release.
  - A Grafana-style panel builder.

## Decisions

### D1. `demo/` layout and product fencing

```
demo/
  README.md                 how to run, publish, and what each demo shows
  BUILD.bazel               package_group //demo/...; visibility fence
  simkit/                   shared Go simulation library (+ native tests)
  rtsp-replayer/            image target, clip lock file, deploy notes
  wifi-campus/  drone-fleet/  ot-plc/  dc-hall/  cyber-ot/
    plugin/                 main.go, plugin.yaml, config.schema.json
    scenarios/*.yaml        scenario packs (config for the plugin)
    dashboard/              dashboard.config.mjs, src/, fixtures/ (generated)
    alert-rules/            event-signal rules the pack installs
    BUILD.bazel             :plugin :bundle :dashboard :fixtures
                            :update_fixtures :publish
```

Fencing is mechanical, not a convention: every `demo/**` target has visibility
limited to `//demo:__subpackages__`, and a test asserts that no target outside
`//demo/...` depends on one and that `plugin_inventory.bzl`, the Helm chart and
release manifests reference nothing under `demo/`. Demo plugins are signed with
a demo-only upload key that only the `demo` instance trusts, so a demo plugin
can never be confused with a first-party one.

Alternatives: a separate `serviceradar-demos` repository. Rejected for now --
demos and the product gaps they expose change together, and one PR should be
able to add the SDK hook and the dashboard that uses it. Revisit if `demo/`
grows its own release cadence.

### D2. One library, a few plugin families

Rather than one `sim-world.wasm` with every domain in it, or a one-off generator
per demo, `demo/simkit` holds the generic machinery and each plugin family stays
thin:

- `wifi-campus` -- sites, controllers, APs, clients, RF.
- `drone-fleet` -- vehicles, ground stations, geofences, camera descriptors.
- `ot-plc` -- controllers, registers, process models; the airport baggage and
  well-pad demos are two scenario packs for this one plugin (and the substation
  variant later is a third).
- `dc-hall`, `cyber-ot` -- P2, `cyber-ot` reusing the `ot-plc` twin plus
  IT-side event noise.

A scenario pack is the plugin's assignment config (well under the 2 MiB config
cap), so one Wasm binary can run several packs on several assignments.

### D3. Stateless, time-derived simulation

Because runs share no state, all simulator state is a pure function of
`(scenario seed, entity id, wall-clock time)`:

- Positions come from parametric paths (orbits, lawnmower survey grids,
  corridor patrols) evaluated at `t`.
- Process values come from seeded noise plus scheduled fault overlays.
- Counters are integrals computed in closed form, so they are monotonic across
  runs without being stored.
- A run emits samples at a fine resolution (default 1 s for drones, 10 s
  otherwise) covering the window since the previous scheduled run, so time
  series are smooth even at a 30-60 s run interval.

This makes the demos restart-proof, lets any number of agents run the same pack
consistently, and lets the native fixture exporter (D7) produce the same data
the plugin would.

### D4. Fault scheduler

Each scenario pack lists faults with `kind`, targets (selector over entities),
`period`, `phase`, `duration`, `jitter` (seeded) and effects (metric overlays,
state flips, emitted events). The scheduler guarantees, and a unit test checks
over a simulated week, that:

- at every instant at least one fault is active or begins within 10 minutes;
- faults of the same kind on the same target never overlap;
- every fault emits an opening event and a resolving event, so alerts open and
  close on their own.

Examples: drone `lost_link` and `geofence_breach`; baggage `jam` and
`eds_timeout`; Wi-Fi `rogue_ap`, `controller_partition`, `channel_saturation`;
well pad `pressure_spike_with_radio_fade`, `valve_failed_to_close`.

### D5. Data placement: inventory slow, motion as telemetry

Moving hundreds of drones by rewriting device metadata every run would push
DIRE and CNPG through pointless churn. Instead:

- Inventory (device discovery) is emitted on a slow cadence gate (default
  every 15 minutes, computed from time so it is stateless) with stable serials
  derived from the scenario seed; it carries the home or install location.
- Live position, heading, battery, link quality, belt speed, pressure and the
  like are metrics through `emit_telemetry`, i.e. JetStream -> EventWriter,
  exactly as the hard rules require. Nothing in a demo writes to a database.
- Faults become OCSF events in the result `events[]`, which reach the stateful
  alert engine; each pack ships event-signal alert rules.
- Wi-Fi uses the existing `serviceradar.wifi_map.batch.v1` contract for sites,
  controllers and APs, so the demo exercises the real ingestor and SRQL
  `wifi_*` entities.

The dashboard reads "latest value per asset" frames for the map. If SRQL cannot
express that frame efficiently today, the SRQL change is a task of this change,
not a demo-side workaround. The drone map interpolates between the last two
known positions so movement is smooth despite frame refresh granularity.

### D6. Synthetic identifiers, enforced

Per the repository's live-data rule, everything is invented from nothing:

- IPv4 only from `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`; IPv6 from
  `2001:db8::/32`.
- MACs from `00:00:5e:00:53:00` through `00:00:5e:00:53:ff` (the `00:00:5e:00:53:xx` block) or locally administered unicast
  (`02:xx:...`) derived from the seed -- never a real vendor OUI.
- Hostnames under `example.com`, `example.net` or `.test`; site, facility and
  asset codes invented, and never shaped like IATA/ICAO codes.
- Map placement avoids real named facilities (airports, bases, plants,
  wellheads, pipelines); each scenario pack records why its coordinates are
  safe. Plan views (baggage hall, DC hall) use no basemap at all.
- Phone numbers `555-0100`-`555-0199`; people, organizations and
  serials invented.

The Wi-Fi twin is a fictional university/corporate campus plus branch sites.
It is deliberately not airport-shaped and is not derived, "sanitized" or
re-shaped from any customer dataset or customer dashboard repository: the shape
of real data identifies its owner even after names are removed. The dashboard
starts from the generic `react-map` template.

`simkit` ships a guard used by every plugin's tests and by the fixture
exporter: it walks every emitted record and fails on an IP, MAC, hostname or
coordinate outside the rules above.

### D7. Fixtures come from the simulator

Each demo's `:fixtures` target runs the same `simkit` code natively (plain Go,
not TinyGo) against its scenario pack at pinned timestamps -- one "steady" and
one per headline fault -- and writes dashboard harness frames. They are
committed through `write_source_files` with a `diff_test`, following the
repository's generated-file rule, and the harness fixture dropdown switches
between them. The dev harness gains a fixture resolver hook (D9) so filter
chips work offline instead of only logging the query.

### D8. Video: replayed RTSP through the real relay

- Clips are stock or commissioned footage whose license allows public demo use,
  transcoded once to H.264 (no B-frames) because the agent relay is H.264-only.
  They live in a Linode Object Storage bucket, never in git. `demo/rtsp-replayer/
  clips.lock.json` records object key, sha256, duration, resolution, license and
  source.
- `//demo/rtsp-replayer:image` (Bazel-built OCI image, pushed to
  `registry.carverauto.dev`) fetches the locked clips at start, verifies
  digests, and serves each as a looping RTSP path. The bucket read credential is
  a Kubernetes Secret in `demo` (the replayer is demo infrastructure, not a
  monitored device, so the unified device-credential model does not apply).
- The drone simulator emits camera descriptors whose `rtsp_url` points at
  replayer paths; with more drones than clips, paths reuse clips at different
  start offsets. The agent's native RTSP reader, core-elx Membrane fan-out and
  WebRTC egress then behave exactly as for a real camera.

### D9. Dashboard platform additions

- **Video API.** Manifest capability `camera.stream.view`, RBAC-gated like the
  `/cameras` page. Host API `api.camera.open({camera_source_id,
  stream_profile_id}) -> {attach(el), close(), onState(fn)}` built on the
  existing relay-session and WebRTC signaling endpoints, with the retry and
  WebCodecs/MSE fallback logic moved out of the LiveView hook into a shared
  module both use. The host closes every session a renderer opened when it is
  destroyed or hidden. SDK: `useCameraStream`, `<CameraTile>`, `<CameraGrid>`
  and types; the harness supplies a mock stream so dashboards run offline.
  Discovery through a camera-source SRQL entity. CSP gains exactly the media
  sources the player needs (`blob:` and `mediastream:` for `media-src`), not a
  wildcard. Concurrency is bounded per renderer (default 9 tiles).
- **Proving the video API first.** Before the drone demo depends on it, a small
  test dashboard under `demo/` plays two or more UniFi Protect streams from the
  `demo` namespace at the same time through the new API.
- **Frame refresh.** `data_frames[].refresh_interval_ms`, clamped to the
  existing 1-60 s bounds, replaces the hardcoded 15 s.
- **Plan views.** An SDK helper for a deck.gl `OrthographicView` canvas with the
  same layer factories, popup and theme plumbing as the map helpers.
- **Harness resolver.** `srql.update` in the dev harness calls an optional
  author-supplied `resolveFixture(query, frameQueries)`; libraries can be served
  locally for offline booths instead of from `esm.sh`.

### D10. Topology links from plugins

`serviceradar.topology_links.v1` carries directed link observations
(`from`, `to` by device identity keys the plugin also emits, `kind`
(`wireless`, `wired`, `backhaul`, `controller`), optional metrics, observed-at).
A core handler beside the other plugin-result handlers turns them into
plugin-sourced links with provenance `plugin:<id>`. It targets the topology
read model rather than AGE directly so it survives
`replace-age-topology-with-dgraph`. Go and Rust SDKs get the same emitter.

### D11. Rust parity is tested, not claimed

A conformance suite lives with the SDKs: golden host-call transcripts and
result payloads for each capability, produced by the Go SDK and replayed
against the Rust SDK (and vice versa for Rust-only conveniences). Parity gaps
closed by this change are listed in the `plugin-sdk-rust` delta. Any feature
this change adds to the Go SDK (topology links, anything `simkit` needs from
the SDK) lands in Rust in the same phase. The Rust SDK moves to `wasm32-wasip1`
to match the agent's `wasi-preview1` runtime.

### D12. Build and deploy

All build, fixture, publish and deploy steps are Bazel targets; no scripts.
`bazel run //demo/<name>:publish` publishes the signed plugin bundle and the
dashboard package to the `demo` instance through the existing CLI publish APIs,
installs the pack's alert rules, and assigns the plugin to the demo agent. The
operator token is read from the client environment at run time, never as an
action input. Cluster-side resources (replayer Deployment, WebRTC/TURN
settings, trust for the demo upload key) are declared in `carverauto/gitops`
for the `demo` namespace in the `carverauto` context.

## Risks / Trade-offs

- Map placement that "looks real" can still land on a real facility ->
  placement review is part of each pack, the guard checks coordinates against
  the pack's declared safe bounds, and plan views avoid basemaps entirely.
- Several WebRTC tiles cost relay CPU and bandwidth in a shared namespace ->
  per-renderer tile cap, sessions close when the overlay is hidden or the tab is
  backgrounded, and the replayer serves modest bitrates.
- Demo plugin churn could load DIRE/CNPG in `demo` -> slow inventory cadence
  (D5), stable identities, telemetry through JetStream only.
- Clip licensing -> only clips with recorded licenses in the lock file; the
  replayer refuses unlisted objects.
- `demo/` dragging on `make test` -> simkit and fixture tests are small and
  hermetic; Wasm builds run only for `//demo/...` targets.

## Migration Plan

Additive. No product behavior changes unless a dashboard declares the new
capability or frame setting. Rollback is disabling the demo packages and
assignments in `demo`; product-side additions are independently revertible.

## Open Questions

- Minimum plugin run interval the agent allows (drone smoothness depends on it;
  D3 back-fills samples either way).
- Wire the unconsumed SDK `alert_hint` into core, or remove it from the
  `plugin-sdk-go` spec? Demos do not depend on it; recommend a separate fix.
- Does the demo need TURN, or does the ingress path suffice for booth networks?
- Should `simkit` be promoted into the Go SDK (and then Rust) once it proves
  useful to plugin authors writing test doubles?
