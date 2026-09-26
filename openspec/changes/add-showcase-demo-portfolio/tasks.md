Phases 1-7 are enablers and may run in parallel; every demo phase also needs phase 3. Each demo phase ends with the
demo published and running unattended in the `demo` namespace (`carverauto`
context) for at least 24 hours, with its faults observed opening and resolving
alerts. Dashboards follow the mockup layouts described in design D14. Every PR
goes through the no-mistakes gate.

## 1. Foundations (`demo/` and `simkit`)
- [ ] 1.1 Create `demo/` with `README.md`, a `package_group`, and default visibility restricted to `//demo:__subpackages__`.
- [ ] 1.2 Add the fencing test: no target outside `//demo/...` depends on a demo target; `plugin_inventory.bzl`, the Helm chart and release manifests reference nothing under `demo/`.
- [ ] 1.3 Build `demo/simkit`: seeded RNG and identity minting, time-derived evaluation, closed-form counters, fine-resolution backfill of the elapsed window, inventory cadence gate.
- [ ] 1.4 Fault scheduler with period/phase/duration/jitter, target selectors, overlays and opening/resolving events; a seven-day coverage test (no gap over 10 min, no same-kind overlap, every fault resolves); schedule published as `demo.fault.next_at` / `demo.fault.active` metrics (D13).
- [ ] 1.5 Source boundary (D17): the `Source` interface, the simulated implementation over `simkit` producing device-native shapes, the shared normalizer to product contracts, and a reusable source contract test.
- [ ] 1.6 Emitters over `serviceradar-sdk-go`: device discovery, metric batches via `emit_telemetry` (respecting the 256-record batch cap), OCSF events, Wi-Fi map batches, camera descriptors, topology links (after 7.x).
- [ ] 1.7 Demo guard (D6): fail on publicly routable IPs and public DNS names in emitted records; usable from plugin tests and the fixture exporter.
- [ ] 1.8 Native fixture exporter and the `:fixtures` / `:update_fixtures` / `diff_test` target pattern (`write_source_files`).
- [ ] 1.9 Demo plugin Bazel macro: TinyGo Wasm build, bundle with manifest and config schema, signature with the demo-only upload key.
- [ ] 1.10 Publish run target: signed plugin bundle and dashboard package via the CLI publish APIs, alert-rule install, assignment to the demo agent; token from the client environment; idempotent re-runs.
- [ ] 1.11 gitops: trust the demo upload key in `demo` only; demo agent assignment target.
- [ ] 1.12 Shared dashboard pieces: common frame (incident banner, chip/KPI header, visual/detail split, active SRQL chips) and the presenter strip with countdown and per-fault trigger buttons rendered from action descriptors (D13, D14).
- [ ] 1.13 `simkit` fault injection: the fault-injection and end-fault-early action handlers (opening/resolving events emitted from the action), overlay of active run overrides on every run, guards (maximum duration, one per kind and target, rate limit), schedule on/off per pack.

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

## 3. On-demand actions and event-driven dashboards (D13; depends on `add-northbound-action-integrations`)
- [ ] 3.1 Time-bounded run overrides and event emission from actions: accept overrides in plugin action results, retain per assignment with expiry clamped to the descriptor maximum, pass active overrides to every run, deliver an expired override marked `expired` to runs after expiry until one reports success, end early on a later action; add a host call letting an action entrypoint emit plugin OCSF events through the run-result event path; Go and Rust SDK support and conformance transcripts.
- [ ] 3.2 Dashboard `actions.invoke` capability: list actions for targets, invoke through the northbound action model with RBAC, audit and history, report progress and result to the dashboard.
- [ ] 3.3 Live event subscription for dashboards (OCSF events by filter, RBAC-scoped) and on-demand frame refresh; SDK hooks and types; harness replays fixture events on a timeline.
- [ ] 3.4 Measure trigger-to-screen latency in `demo` (button, action, opening event persisted, dashboard updated) and keep it within a few seconds.

## 4. Camera analysis with a real detector (D16)
- [ ] 4.1 Audit the analysis pipeline end to end in `demo` with the reference worker: branch attach, bounded sampling, dispatch, `camera_analysis_result.v1` ingest, OCSF event; record every gap found and fix it here.
- [ ] 4.2 Extend the result contract additively with `detections[]` (label, confidence, normalized bbox, media timestamp); legacy single `detection` still accepted; ingestor and tests.
- [ ] 4.3 Inference worker: HTTP worker on the analysis contract running an off-the-shelf detector (ONNX runtime, CPU first) with a commercially usable model license recorded beside it; Bazel-built image; register, probe and health-track it in `demo`.
- [ ] 4.4 Relay-session detection feed to authorized viewers with a latency budget (late detections dropped for viewers, still ingested as events).
- [ ] 4.5 Host `onDetections` on the camera API; `<CameraTile>` draws labelled boxes aligned to the frame; harness mock detections.
- [ ] 4.6 Caps: analysis only while a session is active, bounded sample rate, maximum concurrently analysed streams in `demo`.
- [ ] 4.7 Validate on one UniFi Protect stream and one replayed clip before the drone multiview depends on it; confirm detections match the footage and alerts open from configured labels.

## 5. Rust SDK parity (in `serviceradar-sdk-rust`, mirrored in its own OpenSpec)
- [ ] 5.1 Conformance suite: golden host-call transcripts and payloads per capability from the Go SDK; run in both SDKs' CI.
- [ ] 5.2 Move to the `wasm32-wasip1` target; confirm clock and sleep under the agent runtime.
- [ ] 5.3 RTSP transport over host TCP, RTSPS over TLS, Basic/Digest auth.
- [ ] 5.4 HTTP `status_body` response mode; export the default HTTP client and the payload limit.
- [ ] 5.5 Check-descriptor builders (`optional_target_fields`, `schedule_bounds`, `threshold_schema`).
- [ ] 5.6 Packaged examples with `plugin.yaml` and `config.schema.json`, covering the Go examples plus an RTSP example and a northbound-actions example.
- [ ] 5.7 Update `js/cli/templates/plugin-rust/` and `docs/docs/sdks.md`.

## 6. Dashboard platform additions
- [ ] 6.1 Per-frame `refresh_interval_ms` in the manifest, clamped 1-60 s, replacing the hardcoded interval in `dashboard_package_live/show.ex`.
- [ ] 6.2 SDK orthographic plan-view canvas helper sharing layer factories, popups and theme (floorplans, sorter schematic, DC hall).
- [ ] 6.3 Harness fixture resolver for `srql.update`; option to serve map libraries locally.
- [ ] 6.4 Confirm SRQL can return a latest-value-per-asset frame for metrics with coordinates; extend SRQL if it cannot.

## 7. Plugin topology links
- [ ] 7.1 Define `serviceradar.topology_links.v1` (schema, kinds, staleness window).
- [ ] 7.2 Go SDK builder; Rust SDK builder; conformance transcripts.
- [ ] 7.3 Core handler beside the plugin-result contract handlers, targeting the topology read model (backend-neutral with respect to `replace-age-topology-with-dgraph`), with provenance, unresolved-link counter and staleness.
- [ ] 7.4 Tests: resolved link visible, unresolved dropped and counted, stale marking.

## 8. P0 demo: Wi-Fi twin
- [ ] 8.1 Pick the airport venue (public, not the hub of an airline we work with) and define the fictional carrier (an airline designator absent from the public IATA and ICAO designator listings, checked and dated in the pack, flight schedule, flight numbers); both shared with the baggage pack (design D6).
- [ ] 8.2 Scenario pack: concourses and gates, controllers, switches, APs (real vendor models welcome), client load driven by the carrier's departures and arrivals, RF health, roaming; faults: channel saturation, rogue AP, controller partition, AP reboot storm.
- [ ] 8.3 `wifi-campus` plugin: controller-API-shaped simulated source, normalizer to Wi-Fi map batches, metrics and events; alert rules.
- [ ] 8.4 Dashboard from the `react-map` template: site map and indoor floorplan (plan view), AP pins with client-density/interference heat, controller -> switch -> AP topology drawer, roam trail, capacity-forecast strip, AP detail card, SRQL chips.
- [ ] 8.5 Presenter strip wired to the plugin's fault actions; fixtures (steady + each fault); publish; 24 h unattended run in `demo`.

## 9. P0 demo: drone fleet with multiview (after 2.x, 4.x)
- [ ] 9.1 Clip sourcing: licensed footage with detectable content (vehicles, people, infrastructure), H.264 transcode (no B-frames), upload to the Linode bucket, `clips.lock.json`.
- [ ] 9.2 `//demo/rtsp-replayer:image`: fetch and verify locked clips, loop as RTSP paths with per-path start offsets; push to `registry.carverauto.dev`; gitops Deployment and Secret in `demo`.
- [ ] 9.3 Scenario packs: ISR orbit with geofence, pipeline patrol with methane hotspot overlay, survey grid with coverage.
- [ ] 9.4 Faults: lost link (last known position), geofence breach, low battery return-to-base, link degradation; plus detection-driven incidents from 4.x.
- [ ] 9.5 `drone-fleet` plugin: inventory on cadence, position/heading/altitude/speed/battery/link/gimbal as metrics with 1 s backfill, camera descriptors pointing at replayer paths, events; alert rules.
- [ ] 9.6 Dashboard: tactical map with heading-rotated drones, labels, ground stations with range rings, geofences, corridors, methane overlay toggle and mission tracks; popup with sparklines; interpolated motion; corner multiview overlay (toggle, 1/4/9 grid, telemetry HUD and detection boxes per tile, map-tile cross-selection, lost-link tile state, sessions closed when hidden); detail cards (link, battery, gimbal, geofence margin); mission timeline; SRQL chips.
- [ ] 9.7 Fixtures (steady + each fault, harness mock video and detections); publish; 24 h unattended run in `demo`, including relay and analysis session counts returning to zero when no one watches.

## 10. P1 demos: OT PLC family (after 6.2, 7.x)
- [ ] 10.1 `ot-plc` plugin: register-block simulated source (Modbus-shaped), normalizer to metrics and events, firmware and health, process models driven by scenario packs.
- [ ] 10.2 Airport baggage pack: terminal and piers, check-in, screening machines, conveyors, sorters, carousels, bag flow with the fictional carrier's flights and 10-digit bag tags; faults: jam, screening timeout, mis-sort.
- [ ] 10.3 Baggage dashboard: sorter schematic (plan view), KPIs (bags/hour, screening reject rate, transit time), register table, in-flight bag list, controller table, fieldbus topology tab, jam incident with upstream conveyors and last bags.
- [ ] 10.4 Well-pad pack: wells, pump jacks, block valves, RTUs, compressors, radios and backhaul towers with topology links; faults: pressure spike with radio fade, valve failed to close.
- [ ] 10.5 Well-pad dashboard: lease map with trunkline and radio lines to the tower, station cards (pressure, flow, vibration, radio SNR, radio path), backhaul topology drawer, time series.
- [ ] 10.6 Fixtures; publish; 24 h unattended run of each in `demo`.

## 11. P2 demos
- [ ] 11.1 DC hall plan view: PDU phase load, cooling setpoints, aisle temperatures, cage door events; faults: phase imbalance, cooling unit failure.
- [ ] 11.2 Cyber + OT timeline: reuse the baggage or well-pad twin, add firewall-deny and syslog noise, unexpected function-code and firmware-hash-change faults; one interleaved timeline with domain filters (OT, IT syslog, plugin sandbox, RF).
- [ ] 11.3 Fixtures; publish; 24 h unattended run in `demo`.

## 12. Wrap-up
- [ ] 12.1 `demo/README.md`: what each demo shows, a 90-second talk track per demo (event -> alert -> map highlight -> topology -> raw metrics), offline laptop instructions, and for each plugin the real `Source` a customer deployment would need.
- [ ] 12.2 Record follow-up changes for the candidate demos in design D15 (rail short line, rail yard and corridor, ranch, agriculture district, Midwest row crop) and the rest of the backlog (port, retail/stadium, mine site, maritime, public safety, constrained forward site).
- [ ] 12.3 `openspec validate add-showcase-demo-portfolio --strict`; archive after the last phase ships.
