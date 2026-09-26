Phases 1-3 are enablers and may run in parallel. Each demo phase ends with the
demo published and running unattended in the `demo` namespace (`carverauto`
context) for at least 24 hours, with its faults observed opening and resolving
alerts. Every PR goes through the no-mistakes gate.

## 1. Foundations (`demo/` and `simkit`)
- [ ] 1.1 Create `demo/` with `README.md`, a `package_group`, and default visibility restricted to `//demo:__subpackages__`.
- [ ] 1.2 Add the fencing test: no target outside `//demo/...` depends on a demo target; `plugin_inventory.bzl`, the Helm chart and release manifests reference nothing under `demo/`.
- [ ] 1.3 Build `demo/simkit`: seeded RNG and identity minting, time-derived evaluation, closed-form counters, fine-resolution backfill of the elapsed window, inventory cadence gate.
- [ ] 1.4 Fault scheduler with period/phase/duration/jitter, target selectors, overlays and opening/resolving events; a seven-day coverage test (no gap over 10 min, no same-kind overlap, every fault resolves).
- [ ] 1.5 Emitters over `serviceradar-sdk-go`: device discovery, metric batches via `emit_telemetry` (respecting the 256-record batch cap), OCSF events, Wi-Fi map batches, camera descriptors, topology links (after 5.x).
- [ ] 1.6 Synthetic-data guard (IP, MAC, hostname, site-code, coordinate-bounds rules from design D6), usable from plugin tests and the fixture exporter.
- [ ] 1.7 Native fixture exporter and the `:fixtures` / `:update_fixtures` / `diff_test` target pattern (`write_source_files`).
- [ ] 1.8 Demo plugin Bazel macro: TinyGo Wasm build, bundle with manifest and config schema, signature with the demo-only upload key.
- [ ] 1.9 Publish run target: signed plugin bundle and dashboard package via the CLI publish APIs, alert-rule install, assignment to the demo agent; token from the client environment; idempotent re-runs.
- [ ] 1.10 gitops: trust the demo upload key in `demo` only; demo agent assignment target.

## 2. Dashboard video API (validated with UniFi Protect in `demo`)
- [ ] 2.1 Extract the relay player's signaling, retry and WebCodecs/MSE fallback from `CameraRelayStatusStream.js` into a shared module; keep the LiveView hook on it.
- [ ] 2.2 Add `camera.stream.view` to the dashboard manifest capability allowlist and staged-import review.
- [ ] 2.3 Host `api.camera.open/attach/close/onState` in `DashboardWasmHost.js`, RBAC-checked, per-renderer session cap (default 9), close-all on destroy and on hidden tab.
- [ ] 2.4 SRQL camera-source entity (sources, owning device, availability, viewable stream profiles) with RBAC filtering, plus any migration it needs.
- [ ] 2.5 CSP: add `blob:` and `mediastream:` to `media-src` only.
- [ ] 2.6 Wire `camera_relay_webrtc_enabled` and ICE/TURN servers into `runtime.exs` and Helm values; set them for `demo` in gitops.
- [ ] 2.7 SDK: `useCameraStream`, `<CameraTile>`, `<CameraGrid>`, TypeScript types, README section; harness mock camera API.
- [ ] 2.8 `demo/camera-wall` test dashboard; confirm two or more UniFi Protect streams play concurrently in `demo` and sessions close on navigation (check relay session counts after close, not just the UI).
- [ ] 2.9 Tests: host capability and permission rejection, session cap, close-on-destroy; SDK component tests; harness mock.

## 3. Rust SDK parity (in `serviceradar-sdk-rust`, mirrored in its own OpenSpec)
- [ ] 3.1 Conformance suite: golden host-call transcripts and payloads per capability from the Go SDK; run in both SDKs' CI.
- [ ] 3.2 Move to the `wasm32-wasip1` target; confirm clock and sleep under the agent runtime.
- [ ] 3.3 RTSP transport over host TCP, RTSPS over TLS, Basic/Digest auth.
- [ ] 3.4 HTTP `status_body` response mode; export the default HTTP client and the payload limit.
- [ ] 3.5 Check-descriptor builders (`optional_target_fields`, `schedule_bounds`, `threshold_schema`).
- [ ] 3.6 Manifest model parity in both SDKs: `notify:v1`, `actions`, `integrations`.
- [ ] 3.7 Packaged examples with `plugin.yaml` and `config.schema.json`, covering the Go examples plus an RTSP example and a northbound-actions example.
- [ ] 3.8 Update `js/cli/templates/plugin-rust/` and `docs/docs/sdks.md`.

## 4. Dashboard platform additions
- [ ] 4.1 Per-frame `refresh_interval_ms` in the manifest, clamped 1-60 s, replacing the hardcoded interval in `dashboard_package_live/show.ex`.
- [ ] 4.2 SDK orthographic plan-view canvas helper sharing layer factories, popups and theme.
- [ ] 4.3 Harness fixture resolver for `srql.update`; option to serve map libraries locally.
- [ ] 4.4 Confirm SRQL can return a latest-value-per-asset frame for metrics with coordinates; extend SRQL if it cannot.

## 5. Plugin topology links
- [ ] 5.1 Define `serviceradar.topology_links.v1` (schema, kinds, staleness window).
- [ ] 5.2 Go SDK builder; Rust SDK builder; conformance transcripts.
- [ ] 5.3 Core handler beside the plugin-result contract handlers, targeting the topology read model (backend-neutral with respect to `replace-age-topology-with-dgraph`), with provenance, unresolved-link counter and staleness.
- [ ] 5.4 Tests: resolved link visible, unresolved dropped and counted, stale marking.

## 6. P0 demo: Wi-Fi campus twin
- [ ] 6.1 Scenario pack: fictional campus plus branch sites, controllers, APs, client load curves by time of day, RF health, roaming; safe coordinate bounds and placement rationale.
- [ ] 6.2 Faults: channel saturation, rogue AP, controller partition, AP reboot storm.
- [ ] 6.3 `wifi-campus` plugin emitting Wi-Fi map batches, metrics and events; alert rules.
- [ ] 6.4 Dashboard from the `react-map` template: site clusters, AP heat by clients or interference, controller-to-AP overlay, roam path, capacity forecast strip, SRQL chips.
- [ ] 6.5 Fixtures (steady + each fault); publish; 24 h unattended run in `demo`.

## 7. P0 demo: drone fleet with multiview (after 2.x)
- [ ] 7.1 Clip sourcing: licensed footage, H.264 transcode (no B-frames), upload to the Linode bucket, `clips.lock.json`.
- [ ] 7.2 `//demo/rtsp-replayer:image`: fetch and verify locked clips, loop as RTSP paths with per-path start offsets; push to `registry.carverauto.dev`; gitops Deployment and Secret in `demo`.
- [ ] 7.3 Scenario packs: ISR orbit with geofence, pipeline patrol with methane hotspot overlay, survey grid with coverage; each with safe bounds.
- [ ] 7.4 Faults: lost link (last known position), geofence breach, low battery return-to-base, link degradation.
- [ ] 7.5 `drone-fleet` plugin: inventory on cadence, position/heading/battery/link as metrics with 1 s backfill, camera descriptors pointing at replayer paths, events; alert rules.
- [ ] 7.6 Dashboard: map with drones, ground stations, geofences and mission tracks; popup with sparklines; interpolated motion; corner multiview overlay (toggle, 1/4/9 grid, map-tile cross-selection, lost-link tile state, sessions closed when hidden); mission timeline; SRQL chips.
- [ ] 7.7 Fixtures (steady + each fault, harness mock video); publish; 24 h unattended run in `demo`, including relay session counts returning to zero when no one watches.

## 8. P1 demos: OT PLC family (after 4.2, 5.x)
- [ ] 8.1 `ot-plc` plugin: controllers, register blocks as metrics, firmware and health, process models driven by scenario packs.
- [ ] 8.2 Airport baggage pack: fictional terminal and piers, conveyors, sorters, screening machines, carousels, bag flow; faults: jam, screening timeout, mis-sort.
- [ ] 8.3 Baggage dashboard: plan view (no basemap), bag flow per pier, jam incident with upstream conveyors and last bags, controller table.
- [ ] 8.4 Well-pad pack: wells, pump jacks, block valves, RTUs, radios and backhaul towers with topology links; faults: pressure spike with radio fade, valve failed to close.
- [ ] 8.5 Well-pad dashboard: lease map, pressure/flow/vibration series, RTU-radio-tower topology path.
- [ ] 8.6 Fixtures; publish; 24 h unattended run of each in `demo`.

## 9. P2 demos
- [ ] 9.1 DC hall plan view: PDU phase load, cooling setpoints, aisle temperatures, cage door events; faults: phase imbalance, cooling unit failure.
- [ ] 9.2 Cyber + OT timeline: reuse the baggage or well-pad twin, add firewall-deny and syslog noise, unexpected function-code and firmware-hash-change faults; one interleaved timeline of RF, PLC and security events.
- [ ] 9.3 Fixtures; publish; 24 h unattended run in `demo`.

## 10. Wrap-up
- [ ] 10.1 `demo/README.md`: what each demo shows, a 90-second talk track per demo (event -> alert -> map highlight -> topology -> raw metrics), offline laptop instructions.
- [ ] 10.2 Record follow-up changes for the deferred demos (port/rail yard, retail/stadium, mine site, maritime, public safety, constrained forward site).
- [ ] 10.3 `openspec validate add-showcase-demo-portfolio --strict`; archive after the last phase ships.
