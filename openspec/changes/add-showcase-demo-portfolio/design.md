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
  - Each demo is one step from a customer deployment: swap the simulated
    source for a real one and keep everything else (D17).
  - The camera analysis pipeline proven end to end with a real model (D16).
- Non-Goals:
  - A video management system. A multiview of a handful of tiles is the ceiling.
  - Faithful Modbus/DNP3/IEC-104 stacks in this change. Registers are
    simulated behind the `Source` boundary (D17); a real adapter uses the same
    allowlisted TCP proxy.
  - Training or fine-tuning models; the detector is off the shelf.
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
  The follow-on `add-spatial-observation-ingestion` proposal replaces independently
  sampled position components with one atomic spatial observation on that same
  telemetry path; battery, link quality and other numeric measurements remain
  metrics. Its negotiated contract must land before demos depend on atomic positions.
- Faults become OCSF events in the result `events[]`, which reach the stateful
  alert engine; each pack ships event-signal alert rules.
- Wi-Fi uses the existing `serviceradar.wifi_map.batch.v1` contract for sites,
  controllers and APs, so the demo exercises the real ingestor and SRQL
  `wifi_*` entities.

The dashboard reads "latest value per asset" frames for the map. If SRQL cannot
express that frame efficiently today, the SRQL change is a task of this change,
not a demo-side workaround. The drone map interpolates between the last two
known positions so movement is smooth despite frame refresh granularity.

### D6. Data provenance: real public data yes, customer data never

Demos should be as real as possible, so public real-world reference data is
welcome: real airports, IATA codes and gates, airline flight numbers, public
coordinates and region names, vendor product and model names, and real vendor
MAC OUIs.

What is forbidden is anything exported, replayed, "sanitized" or reshaped from
a customer or partner deployment or dataset -- their site lists, naming
schemes, IP plans, serials, fleet shape or captures. Scenario packs are built
from public information and invention, and a pack is not set up to mirror a
specific customer's deployment. Dashboards start from the generic SDK
templates, not from any customer dashboard repository.

**Airport venue.** The Wi-Fi and baggage demos share one airport so a single
venue shows RF, OT and (later) perimeter drones together. The airport is real
and public, but it is chosen so it is not the hub of an airline we work with,
and every flight belongs to a fictional carrier: an airline designator that no
real airline holds, invented flight numbers and bag tags in the standard
10-digit format under that carrier. The designator is checked by looking it up
in the public IATA and ICAO airline designator listings, and is used only if it
appears in neither (most two-letter IATA and three-letter ICAO codes are
assigned, so expect to try several); the pack records the code and the date it
was checked. The venue is picked in task 8.1.

One mechanical rule remains, for operational safety rather than privacy:
simulated devices use only private (RFC 1918) or documentation IP ranges and
non-public host names, so no sweep, MTR run or plugin probe in `demo` ever
targets a real internet host. `simkit` ships a guard, used by every plugin's
tests and by the fixture exporter, that fails on a publicly routable address or
a public DNS name in any emitted record.

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
  author-supplied `resolveFixture({query, frameQueries, frames, fixtures,
  activeFixture})`; libraries can be served locally for offline booths instead
  of from `esm.sh`.

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
action input. The replayer Deployment is declared in `carverauto/gitops` for
the `demo` namespace in the `carverauto` context. WebRTC/TURN settings and
trust for the demo upload key are declared in `helm/serviceradar/values-demo.yaml`
on `staging`, which Argo CD reads directly.

### D13. Faults on a timer or on demand, always through the plugin

Waiting minutes for the next scheduled fault kills a live demo, so presenters
can trigger faults from the dashboard, as the mockups show. The trigger must be
as real as the timer: the dashboard never fakes state. Both paths go through
the plugin and produce the same OCSF events in the events store, the same
alerts and the same metric changes.

- **Faults are plugin actions.** Each demo plugin declares a fault-injection
  action (inputs: a fault kind the pack declares, a target, an optional
  duration) using the northbound action model from
  `add-northbound-action-integrations`: action descriptor, input schema, RBAC,
  audit and invocation history. The platform delivers the invocation to the
  agent over the command bus and the plugin's action entrypoint runs at once.
- **Immediate event.** The action emits the fault's opening OCSF event right
  away, so it reaches the events store and the alert engine within seconds.
  This needs a host call that lets an action entrypoint emit plugin events
  through the same path as run results; the action model in
  `add-northbound-action-integrations` records only invocation lifecycle and
  audit events, so this change adds that call (task 3.1).
- **Stateless runs still see the fault.** The action result carries a
  time-bounded run override (fault kind, target, start, expiry). The platform
  keeps active overrides for the assignment and passes them to every run until
  they expire; `simkit` overlays them exactly like scheduled faults. Runs are
  stateless, so expiry is signalled by the platform: the first run after an
  override's expiry receives it marked `expired`, and the platform discards it
  once a run that received it reports success, so a failed or missed run is
  retried by the next one, for at most seven days after expiry. The run that
  receives it emits the resolving event and does not apply the fault.
  Ending early emits the resolving event from the action instead, and the
  override is discarded without an `expired` delivery. This is a generic
  product capability (a real plugin could use it for a maintenance window or a
  temporary threshold change), not a demo-only path.
- **Guards.** A maximum duration per fault kind, at most one active injected
  fault per kind and target, a per-assignment rate limit, and an "end fault
  early" action that expires the override and emits the resolving event.
  Scheduled faults are never suppressed: an injection is rejected when its
  window (start to start plus duration) overlaps an active injected fault or
  any scheduled window of the same kind on the target, and the action
  evaluates the schedule to decide. Each
  pack can turn its schedule off for presenter-only sessions. Every fault
  carries an id in its opening and resolving events, and resolving an alert
  that is already resolved is a no-op, so a resolving event repeated by an
  expiry retry is harmless.
- **Presenter strip.** Each dashboard shows the active incident (linking to the
  real alert), the countdown to the next scheduled fault, and a trigger button
  per declared fault, rendered from the plugin's action descriptors. Users
  without permission to invoke the action see the strip without buttons. The
  countdown reads the simulator's `demo.fault.next_at` / `demo.fault.active`
  metrics and hides when they are absent, so a real `Source` needs no dashboard
  change; with a real source the same buttons become real operational actions
  (reboot an AP, run a crossing test).
- **Event-driven dashboards.** Frames stay the source of truth, but a dashboard
  must react in seconds, not on its next poll. The dashboard host gains a live,
  RBAC-scoped event subscription (OCSF events matching a filter, for example
  the plugin's source or the dashboard's assets) and an on-demand frame
  refresh. When a matching event arrives, or an action the dashboard invoked
  completes, the dashboard refreshes the affected frames, so the incident
  banner, map highlight and detail panel change as soon as the event lands.

### D14. UI references (mockups)

A set of AI-generated mockups (a standalone React/Vite app kept outside the
repository) guides layout for the drone, Wi-Fi, baggage, pipeline and
cyber + OT dashboards. They are references for structure and content; their
public real-world data (real airports and gates, a real oil basin, vendor
product names) is acceptable to reuse under D6, except that the airport venue
and its flights follow the airport-venue rule in D6 rather than the mockups.

Adopted:

- **Common frame:** incident banner at the top; header with scenario/filter
  chips and KPIs; body split roughly 7/12 visual and 5/12 detail; the active
  SRQL query visible as chips.
- **Drone:** tactical map with heading-rotated icons, callsign/altitude/battery
  labels, range rings around ground stations, geofence polygons, corridor
  paths and a methane overlay toggle; video tiles carry a telemetry HUD
  (heading, altitude, speed, battery, gimbal) and detection boxes (D16);
  detail cards for link quality, battery, gimbal and geofence margin. The
  single video pane becomes the multiview overlay the spec requires.
- **Wi-Fi:** an indoor floorplan (plan view, D9) with AP pins, client-density
  and interference heat, a roam trail, a capacity-forecast strip and a
  controller -> switch -> AP topology drawer.
- **Baggage:** sorter schematic chain with per-conveyor speed and state, a
  register table, an in-flight bag list, a controller table and a fieldbus
  topology tab; KPIs for bags/hour, screening reject rate and transit time.
- **Pipeline:** lease map with trunkline path, radio lines from each asset to a
  backhaul tower, station cards (pressure, flow, vibration, radio SNR, radio
  path) and a radio backhaul topology drawer.
- **Cyber + OT:** one interleaved timeline with domain filters (OT, IT syslog,
  plugin sandbox, RF) and severity.
- **Entity fields** in the mockups (drone, AP, PLC, bag, pipeline asset,
  incident, security event) seed the simulator data models.

Rejected:

- Buttons that change dashboard state directly: every fault button calls the
  plugin action (D13), and "clear" means the "end fault early" action. The
  mockups' global "system reset" control is dropped.
- Operator-control language ("reset ESD valve") and anything that shows the
  dashboard talking to a device (raw `rtsp://` handles, `ip:502` register
  endpoints). Video is WebRTC through the camera API.
- Randomized "latency" and fake throughput counters; every number on screen
  comes from a frame.
- Claims that the demo agent or plugins are Rust or `wasmtime`; demo plugins
  are Go SDK plugins on the agent's wazero runtime.

### D15. Shared IoT asset shape and later rail / agriculture packs

Later packs are sparse, poorly connected sites with many cheap sensors, and
they share one asset shape so dashboards can share hooks:
`asset_id, kind, location (lat/lon or track milepost), status, link_quality,
last_seen` plus kind-specific metrics and `fault | geofence | stale | hotspot`
events. Link quality and last-seen are columns on every asset, and "live" vs
"edge last-known" is a first-class state -- the edge store-and-forward story
is the differentiator against single-vertical vendors. `simkit` provides the
shape; a `sim-iot` plugin family would carry these packs.

Candidates, each a later change reusing `simkit`:

- **Rail, short line:** locomotives (position, speed, notch, fuel), grade
  crossings (power, gates, lights, last test), wayside detectors (axle count,
  bearing temperature), radio heartbeat, work windows as time-bounded
  geofences. Faults: crossing power failure, bearing temperature at a
  detector, dragging equipment before a bridge, locomotive dark in a canyon
  (store-and-forward replay on reconnect).
- **Rail, yard and corridor:** switch machines, retarders, bowl occupancy,
  ramp cranes and hostlers, car identity reads, detector ribbons, wayside huts
  (power and fiber). Faults: switch fails to throw, radio fade on the hump
  lead, hazmat car routed to the wrong bowl.
- **Ranch:** pivots (heading, pressure, percent complete), wells and VFDs
  (flow, level, energy, trips), soil probe grid, weather station, grain bin
  temperature cables, LoRa/mesh gateway signal. Faults: pivot stuck, end-gun
  pressure collapse, well low level, bin hotspot, gateway down with probes
  going stale.
- **Agriculture district:** hundreds of pivots and pumps grouped by ranch,
  crop and water district; machine fleet; allocation burn; elevator or packing
  shed as a small OT site.
- **Midwest row crop:** corn/soybean/small-grain fields named the way farmers
  name them, a normalized machine record, coverage heat as the headline
  visual, radio signal by field, shop and gateway staleness. Two scripts:
  planting week (vacuum drop leaves a zero-population streak; RTK/radio fade
  grays the machine to last-known) and harvest week (combine, cart and trucks;
  yield/moisture hex layer with a wet low spot; dryer plenum over-temperature
  while the combine runs). If only one scene is built, build harvest on a
  single quarter-section. Positioning: the site and connectivity twin for
  co-ops, rural carriers, dealers and elevators -- not an agronomy platform.
  No satellite imagery, prescriptions or crop models.

### D16. Real detections on drone video

The mockups draw detection boxes on the drone feed. These are real, not
painted: the demo exercises the camera analysis pipeline that already exists
(relay analysis branches, bounded frame extraction, HTTP worker dispatch,
`camera_analysis_result.v1`, `Camera.AnalysisResultIngestor` -> OCSF events)
and has never been validated end to end outside tests. Today both analysis
workers (`ReferenceAnalysisWorker`, `ExternalBoomboxAnalysisWorker`) are
deterministic stubs that return one fixed label at confidence 1.0.

Work this adds:

- **A real inference worker.** A containerized HTTP worker speaking
  `camera_analysis_input.v1` / `camera_analysis_result.v1`, running an
  off-the-shelf object detector (ONNX runtime, CPU first; GPU optional) with
  a model whose license permits commercial demo use. Bazel-built image,
  deployed in `demo`, registered through the existing worker registry, probed
  and health-tracked like any other worker.
- **Multiple detections per result.** The contract carries one `detection`
  today; a frame with three vehicles needs a list. Extend the contract
  additively (`detections[]`, keeping `detection` for existing workers) with
  normalized bbox coordinates, label, confidence, and the frame's media
  timestamp.
- **Detections reach viewers.** Results currently become OCSF events only.
  Add a relay-session-scoped detection feed that the dashboard camera API
  exposes (`onDetections`), so `<CameraTile>` can draw boxes aligned to the
  frame they came from, within a stated latency budget; detections older than
  the budget are dropped rather than drawn late.
- **Detections become incidents.** Detection events above a confidence
  threshold for configured labels (e.g. a person, a vehicle) feed the stateful
  alert engine through the pack's event-signal rules, matching on label and
  confidence only, so the drone incident flow includes a real detection. A
  detection is an image-space box and is not geolocated, so no rule joins it
  against drone position or geofence polygons. The alert resolves
  after a configured quiet window with no matching detection, so detection
  alerts close without operator action.
- **Bounded cost.** Analysis runs only while a relay session is active and at
  the bounded sample rate the camera-streaming spec already requires; the
  demo caps the number of concurrently analysed streams.

The replayed clips make this reproducible: the same footage produces the same
detections, so the demo is stable while the pipeline is real.

### D17. Built to swap in real sources

The purpose of each demo is to be one step from a customer deployment: replace
the simulated source, keep everything else. So:

- **Product contracts only.** Plugins emit only standard contracts (device
  discovery, metric batches, OCSF events, Wi-Fi map batches, camera
  descriptors, topology links). No demo-only schemas, SRQL entities or
  database tables. Dashboards read only product SRQL entities and would render
  a real customer's data unchanged.
- **A source boundary in every plugin.** Each plugin is split into a `Source`
  (produces device-native observations: register blocks, controller-API JSON,
  telemetry frames, camera URLs) and a normalizer that maps observations to
  product contracts. `simkit` implements the simulated `Source`, producing the
  same device-native shapes a real device or vendor API returns. Each plugin
  documents the real `Source` it expects in production (for example a Modbus
  TCP client over the host TCP proxy, a controller REST client over the host
  HTTP proxy) and ships at least the interface and a contract test that a real
  implementation must pass.
- **Real transport where it is cheap.** Video is real RTSP through the real
  relay; analysis is a real model; alerts, topology and inventory go through
  the real pipeline. Only the device protocol layer is simulated.

Alternative considered: simulated devices as network endpoints (a simulator
service exposing Modbus TCP, vendor-shaped HTTP APIs and RTSP, polled by
production adapters through the host proxy), the pattern `faker` uses for the
Armis API. It is more faithful but needs a stateful service per domain; it is
the natural next step for any pack a customer is about to buy, and the `Source`
boundary makes it a drop-in.


### D18. Network-scale acceptance ownership

`prove-million-device-topology` owns the network simulator and complete production
pipeline/hardware-browser proof. It remains required for #4774; the showcase
portfolio supplies reusable simkit and plugin topology-link foundations (D10).

### D19. Shared mapping ownership

`add-shared-spatial-resources` owns resource descriptors, reusable tile transport,
provider adapters and dashboard location sharing. Existing plan-view foundations
and #4847 stay in this portfolio. Topology location support stays in #4774.

### D20. Separate platform workstreams

- `add-spatial-observation-ingestion`: atomic wire contract and SDK/host admission.
- `add-spatial-history-projection`: JetStream history, current projection and reads.
- `add-camera-recording-storage`: shared ingest and verified segment publication.
- `add-edge-recording-archive`: offline JetStream buffering and continuous S3 drain.
- `add-recording-playback-lifecycle`: authorized replay, retention, holds and exports.

Each has its own issue, requirements and acceptance. None blocks #4774. SCRITH
ontology/causal implementation remains excluded.

## Risks / Trade-offs

- A scenario pack drifts toward mirroring a customer's deployment -> packs are
  built from public information and invention (D6), and review checks where
  each pack's data came from.
- Real inference is CPU-heavy and the analysis pipeline is unproven -> sample
  rate and concurrent-stream caps, analysis only while a session is active,
  and the pipeline is validated on one stream before the multiview uses it.
- Detection boxes drawn late look broken -> a latency budget; stale
  detections are dropped, not drawn.
- Model licensing -> only models whose license allows commercial demo use,
  recorded beside the worker image.
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
- Which detector model and runtime (CPU ONNX first); is a GPU node available
  to `demo` for more concurrent analysed streams?
- Should `simkit` be promoted into the Go SDK (and then Rust) once it proves
  useful to plugin authors writing test doubles?
