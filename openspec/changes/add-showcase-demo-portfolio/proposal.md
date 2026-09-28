# Change: Add a showcase demo portfolio built on simulator plugins and SDK dashboards

## Why

ServiceRadar has no demo that tells a complete story. The `demo` namespace shows
whatever the lab happens to produce, and the product's strongest capabilities --
sandboxed Wasm plugins that can front any device, SRQL-driven signed dashboards
with maps, and relayed camera video -- are invisible unless someone already has
the right hardware. The one polished map dashboard we have is a customer's and
cannot be shown.

A portfolio of self-running demos fixes that: Wasm plugins that simulate
believable fleets (drones, campus Wi-Fi, airport baggage PLCs, well pads),
inject faults on their own timers or when a presenter asks, and feed the normal
pipeline; and signed
React dashboards that tell the story map -> asset -> live signal -> incident ->
drill-down. Building them also forces the SDKs to grow the features real
customers will need: a dashboard video API, plan-view (non-geographic)
rendering, faster frame refresh, plugin-emitted topology, and a Rust SDK at
parity with Go.

## What Changes

- **New `demo/` tree** in this repository holding demo simulator plugins
  (built with `serviceradar-sdk-go`), their scenario packs, their dashboards
  (built with `serviceradar-dashboard-sdk`), generated harness fixtures, alert
  rules and deploy targets. Nothing under `demo/` ships with the product: it is
  Bazel-visibility-fenced, absent from `build/wasm_plugins/plugin_inventory.bzl`,
  the Helm chart and release artifacts, and signed with a demo-only upload key.
- **`simkit`**, a shared Go library for deterministic simulation: time-derived
  state (runs are stateless), seeded identity, a fault scheduler, motion and
  process models, emitters for inventory/metrics/events/camera descriptors, and
  a native fixture exporter so dashboards and plugins cannot disagree.
- **Faults on a timer or on demand.** Every scenario pack schedules its own
  recurring faults for unattended runs, and presenters can trigger any
  declared fault from the dashboard. Both go through the plugin: a trigger is
  a plugin action that emits the real OCSF event and applies the fault through
  a time-bounded run override, so the incident is as real as a scheduled one.
- **Event-driven dashboards:** dashboards can invoke plugin actions (RBAC,
  audit, history through the northbound action model) and subscribe to live
  OCSF events, refreshing their frames within seconds of an event instead of
  waiting for the next poll.
- **As real as possible.** Real public reference data (airports, flight
  numbers, vendor models) is welcome; customer data never is. Every plugin
  splits a device `Source` from the normalizer, and the simulator is just one
  `Source`, so selling a demo means writing the customer's real `Source` and
  keeping the rest. Simulated device addresses stay non-routable so demo
  sweeps never probe the internet.
- **Real detections on drone video:** prove the existing camera analysis
  pipeline end to end with a real off-the-shelf object detector, carry
  multiple detections per frame, deliver them to viewers, draw them on camera
  tiles, and raise alerts from them.
- **Mockup-guided dashboards:** a common frame (incident banner, chip/KPI
  header, visual/detail split) and a presenter strip with the active
  incident, a countdown to the next scheduled fault and a trigger button per
  declared fault. The Wi-Fi and baggage demos share one public airport with a
  fictional carrier.
- **Dashboard video API** (product + dashboard SDK): a `camera.stream.view`
  manifest capability, a host `camera` session API wrapping the existing relay
  and WebRTC signaling, `useCameraStream` / `<CameraTile>` / `<CameraGrid>` in
  the SDK, a camera-source SRQL entity for discovery, an offline harness mock,
  and the CSP and WebRTC/TURN settings needed to play several streams at once.
  Validated first against the UniFi Protect cameras in the `demo` namespace,
  before any drone work depends on it.
- **Dashboard platform additions:** per-frame refresh interval in the manifest
  (today hardcoded to 15 s), a non-geographic deck.gl canvas for plan views,
  and harness fixture resolution so SRQL filter chips work offline.
- **Plugin topology links:** a `serviceradar.topology_links.v1` result contract,
  Go and Rust emitters, and a core ingestor, so a plugin can say "this RTU
  talks through this radio to this tower".
- **Rust SDK parity** with the Go SDK, enforced by a shared conformance suite:
  RTSP over host TCP (with TLS), HTTP `status_body` responses, a WASI build
  target so clocks and sleep work, public API exports, check-descriptor
  builders, and packaged examples.
- **Demo RTSP replayer:** a Bazel-built image deployed in `demo` that pulls
  licensed H.264 clips from a Linode Object Storage bucket and loops them as RTSP
  paths, so drone cameras are real relayed streams without real drones.
- **Network-scale acceptance:** independently owned by `prove-million-device-topology`; this portfolio supplies simkit and plugin topology-link foundations. See design D18.
- **Demos, phased:**
  - P0: Wi-Fi campus twin; drone fleet with map, geofences and a toggleable
    multiview video overlay.
  - P1: airport baggage-handling OT; well-pad / pipeline SCADA-lite (same PLC
    simulator, second scenario pack).
  - P2: data-center hall plan view; cyber + OT interleaved timeline.
  - Later changes (not this one): rail short line and yard/corridor, ranch
    and agriculture district, Midwest row crop (planting and harvest), port,
    retail/stadium, mine site, maritime, public safety, constrained forward
    site -- sharing one IoT asset shape with link quality and last-seen on
    every asset.

## Impact

- Affected specs: `showcase-demos` (new), `dashboard-sdk`, `camera-streaming`,
  `plugin-sdk-go`, `plugin-sdk-rust` (new), `wasm-plugin-system`.
- Affected code and repositories:
  - `carverauto/serviceradar`: new `demo/`; web-ng dashboard host
    (`assets/js/hooks/DashboardWasmHost.js`, `assets/js/lib/camera_relay/`,
    `router.ex` CSP, `dashboard_package_live/show.ex`); core dashboard manifest
    (`dashboards/manifest.ex`); camera relay controllers; SRQL (`rust/srql`) for
    the camera-source entity; a topology-link ingestor beside
    `observability/plugin_result_ingestor.ex`; dashboard CLI harness
    (`js/cli/src/dashboard/`); `helm/serviceradar/values-demo.yaml` (WebRTC/TURN
    settings, trust for the demo upload key).
    Camera analysis: the `camera_analysis_result.v1` contract and
    `Camera.AnalysisResultIngestor` (core), relay analysis branches and
    dispatch (`serviceradar_core_elx/.../camera_relay/`), and a new inference
    worker image.
  - `carverauto/serviceradar-sdk-dashboard`: camera hooks and components,
    plan-view canvas, types, harness mocks.
  - `carverauto/serviceradar-sdk-go`: topology-link emitter.
  - `carverauto/serviceradar-sdk-rust`: parity work and conformance suite.
  - `carverauto/gitops`: `demo` namespace resources (RTSP replayer, inference
    worker).
- Depends on: `restore-unifi-protect-camera-streams` (a working relay in
  `demo`), `fix-dashboard-frame-staleness`, `add-northbound-action-integrations`
  (plugin action descriptors and invocation, used for fault triggers). Coordinates with
  `add-dashboard-sidebar-shell` (web-ng multiview tiles; the SDK grid reuses its
  player library), `add-plugin-alert-rules` (metric rules shipped by plugins),
  and `replace-age-topology-with-dgraph` (topology-link storage stays
  backend-neutral).
- No schema change for demos themselves; the camera-source SRQL entity and
  topology-link ingest may need migrations, owned by those tasks.
