> Remaining unchecked items are intentional follow-up work, not missed checkoffs. They require additional product/backend/iOS work beyond the current Sidekick + persisted-raster implementation: iOS waterfall rendering, interferer classification, active survey/export flows, site/floor grouping, and a final physical iPhone/Pi/backend smoke test.

## 1. Planning and Validation
- [x] 1.1 Confirm the Pi hardware model, OS, kernel, attached Wi-Fi chipsets, and monitor-mode/radiotap support.
- [x] 1.2 Verify the first usable iPhone-to-Pi IP link option. Current lab validation uses LAN reachability on `eth0`/`wlan0`; no USB network interface was visible yet.
- [x] 1.3 Decide the local observation encoding: Apache Arrow IPC record batches in binary WebSocket frames.
- [x] 1.4 Validate this proposal with `openspec validate add-fieldsurvey-sidekick-bridge --strict`.

## 2. Pi Daemon MVP
- [x] 2.1 Add a `rust/fieldsurvey-sidekick` crate and workspace entry.
- [x] 2.2 Implement config loading with persisted paired-device state.
- [x] 2.3 Implement radio discovery and monitor-mode setup for configured interfaces.
- [x] 2.4 Implement AF_PACKET/TPACKET_V3 capture plus radiotap/802.11 beacon and probe-response parsing.
- [x] 2.5 Implement channel hopping with a dual-radio channel plan.
- [x] 2.6 Implement local HTTP endpoints for status, authenticated monitor preparation, pairing, config read/update, and capture control.
- [x] 2.7 Implement the per-radio observation WebSocket stream with binary Arrow IPC batches.
- [x] 2.8 Implement a receive-only HackRF spectrum WebSocket stream with binary Arrow IPC batches.
- [x] 2.9 Add unit tests with captured frame fixtures and a synthetic observation stream test.

## 3. iOS Integration
- [x] 3.1 Add `SidekickClient` status and WebSocket stream handling.
- [x] 3.2 Add a scanner adapter that maps Sidekick observations into `SurveySample` and heatmap points using the latest ARKit pose.
- [x] 3.3 Refactor `RealWiFiScanner` into a Sidekick RF aggregator, preserving mDNS/subnet inventory context but removing native iPhone Wi-Fi and BLE RF survey inputs.
- [x] 3.4 Add settings UI for Sidekick host override, auth token, radio plan, and HackRF spectrum options.
- [x] 3.5 Add Swift tests for observation decoding and sample mapping.
- [x] 3.6 Add iOS raw pose Arrow encoding and relay to the backend pose stream.

## 4. Backend and Data Contract
- [x] 4.1 Add a raw RF observation Arrow ingest schema and decoder for Sidekick batches.
- [x] 4.2 Add Elixir migrations for `platform.survey_rf_observations`, `platform.survey_pose_samples`, and `platform.survey_spectrum_observations`.
- [x] 4.3 Add Ash resources/actions to bulk insert raw RF observations, pose samples, and spectrum observations.
- [x] 4.4 Add a timestamp-keyed RF/pose fusion view for backend heatmap queries.
- [x] 4.5 Ingest raw RF, pose, and spectrum Arrow IPC batches through the direct ADBC/ExArrow path instead of a Rust NIF decoder bridge.
- [x] 4.6 Add backend/API tests for raw RF Arrow batches, pose batches, spectrum batches, and timestamp-keyed fusion.
- [x] 4.7 Archive original Arrow IPC RF, pose, and spectrum frames with decode status and payload hashes for replay/debug.
- [x] 4.8 Remove legacy FieldSurvey RF/pose/spectrum Arrow decoder exports from the God View Rust NIF after the ADBC ingest path became the source of truth.

## 5. Packaging and Docs
- [x] 5.1 Add Bazel/container packaging or a documented systemd install path for the Pi daemon.
- [x] 5.2 Document supported adapters, udev/capability requirements, monitor-mode troubleshooting, and Kismet comparison checks.
- [x] 5.3 Document FieldSurvey pairing and survey workflow.

## 6. Ekahau-Class RF Fidelity
- [ ] 6.1 Add HackRF waterfall/spectrogram surfaces from the last N sweep rows, rendered in iOS and web review as frequency X time X power. Web review has the first persisted waterfall surface; iOS live/review rendering remains.
- [x] 6.2 Persist a backend-derived RF interference raster separately from the Wi-Fi RSSI raster so operators can compare coverage versus noise.
- [x] 6.3 Add per-band/per-channel noise-floor baseline calibration and score interference as power above baseline, not raw dBm only.
- [x] 6.4 Correlate HackRF channel energy with observed Wi-Fi AP channels to flag conflicts such as strong RSSI on a noisy channel.
- [x] 6.5 Move channel scheduling toward the Sidekick daemon with adaptive channel weighting from HackRF spectrum energy plus confirmed per-BSSID Wi-Fi observations.
- [ ] 6.6 Add coarse interferer classification for broad continuous noise, narrow spikes, and bursty activity.
- [ ] 6.7 Keep `hackrf_sweep` for broad 2.4/5 GHz survey mode; defer optional raw-IQ/rustfft analyzer work until focused channel classification needs raw samples.
- [x] 6.8 Apply temporal averaging and outlier rejection before feeding Wi-Fi RSSI and RF interference points into backend rasters.
- [ ] 6.9 Add active survey hooks for latency/throughput tests that can be tied to the same LiDAR pose timeline.
- [ ] 6.10 Add export/reporting surfaces for standard heatmap output and future ESX-like interchange.

## 7. Live Survey UX, AP Placement, and Rasters
- [x] 7.1 Expose Sidekick adaptive scan visibility: current weighted channel plan, spectrum-prioritized channels, per-channel observed BSSID counts, and stale/unseen channels.
- [x] 7.2 Render adaptive scan status in FieldSurvey so an operator can verify the radio is sweeping the expected channels during capture.
- [x] 7.3 Improve AP placement by combining manual AP marks, per-BSSID RSSI gradients, strongest-observation clusters, and path diversity into confidence-scored AP candidates.
- [x] 7.4 Surface AP placement confidence and supporting observations in iOS and web review.
- [x] 7.5 Ensure web dashboard/review uses persisted backend-derived `wifi_rssi` and `rf_interference` rasters as the post-survey source of truth.
- [x] 7.6 Add automatic persisted raster regeneration/retry on review load for sessions whose artifacts or rasters failed during upload/review.
- [x] 7.7 Render the dashboard FieldSurvey card as a real floorplan plus persisted Wi-Fi RSSI raster instead of a synthetic placeholder or summary overlay.
- [x] 7.8 Render dashboard Wi-Fi coverage as a continuous blurred heat surface rather than visible per-cell marker dots.
- [x] 7.9 Persist a backend-generated SVG heat surface with coverage raster records, while allowing dashboard cards to regenerate a card-local surface from persisted cells when they need a different projection.
- [x] 7.10 Normalize the dashboard FieldSurvey projection so floorplan geometry and Wi-Fi raster cells render squared to the dashboard card instead of preserving arbitrary ARKit heading.
- [x] 7.11 Preserve the dashboard FieldSurvey map aspect ratio and prefer floorplan-backed rasters so the overview card matches the review/floorplan source of truth.
- [x] 7.12 Load dashboard data asynchronously and load the FieldSurvey raster summary on its own async path so slow topology/camera/event queries do not delay the whole dashboard or falsely show "no data" while the heatmap is still loading.
- [x] 7.13 Render AP candidate markers on the dashboard FieldSurvey card using the latest persisted session's strongest per-BSSID observations projected into the same floorplan/raster coordinate space.
- [x] 7.14 Avoid synchronous runtime graph refreshes on dashboard load; request a background refresh when the topology cache is empty so FieldSurvey and other dashboard panels can paint without waiting on AGE graph rebuilds.
- [x] 7.15 Keep the dashboard FieldSurvey heatmap card compact and visually paired with Camera Operations, while keeping larger survey inspection surfaces in FieldSurvey Review.
- [x] 7.16 Cache decoded 2D floorplan linework in room artifact metadata for future uploads so dashboard, review, and spatial room scan loads use Postgres JSONB for small projections while NATS Object Store remains reserved for large artifact downloads.
- [x] 7.17 Make FieldSurvey Review and the Spatial room scan scene use cached floorplan metadata instead of re-fetching legacy floorplan GeoJSON objects from NATS.
- [x] 7.18 Avoid downloading point-cloud artifacts in the Spatial room scan scene when cached floorplan geometry is available; use point cloud only as a no-floorplan fallback.
- [x] 7.19 Prefer sessions with cached floorplan geometry in the Spatial room scan scene and scope fallback RoomPlan/point-cloud artifacts to the selected session.
- [x] 7.20 Clip dashboard Wi-Fi heat surfaces to the derived floorplan footprint so coverage does not bleed outside walls on compact cards.
- [x] 7.21 Suppress low-confidence dashboard AP candidates and keep floorplan linework visually dominant over the compact heat surface.
- [x] 7.22 Suppress raw Wi-Fi observation dots in FieldSurvey Review so the persisted/interpolated heat surface is the primary coverage visual, and cluster AP candidates so virtual BSSIDs do not render as separate physical AP markers.
- [x] 7.23 Rectify near-orthogonal RoomPlan floorplan linework so walls that clearly should be square render as clean right angles without destroying intentionally angled geometry.

## 9. Survey Organization and Site/Floor Model
- [ ] 9.1 Add a survey organization model that associates FieldSurvey sessions with site/building/floor labels and arbitrary metadata tags.
- [ ] 9.2 Add settings UI to define dashboard FieldSurvey groups from SRQL-backed filters, such as airport/site, terminal/building, floor, or tag combinations.
- [ ] 9.3 Add floor selectors in FieldSurvey Review and dashboard cards so multi-floor surveys can be cycled without mixing AP/raster data from different floors.
- [ ] 9.4 Add backend queries that summarize latest Wi-Fi/RF rasters by configured survey group instead of globally selecting one latest session.
- [ ] 9.5 Extend iOS upload/session metadata so resumed captures and artifact retries preserve site/building/floor/group attribution.

## 8. Verification
- [x] 8.1 Run Rust `cargo fmt`, `cargo test -p serviceradar-fieldsurvey-sidekick`, and clippy for the new crate.
- [x] 8.2 Run Swift FieldSurvey tests. Added a real `FieldSurveyTests` target plus shared scheme test action; `xcodebuild -project swift/FieldSurvey/FieldSurvey.xcodeproj -scheme FieldSurvey -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.4.1' test CODE_SIGNING_ALLOWED=NO` passed.
- [x] 8.3 Run focused Elixir/web-ng compile checks and direct Arrow/ADBC ingest coverage for raw RF, pose, and spectrum streams.
- [ ] 8.4 Perform an end-to-end iPhone/Pi/backend survey smoke test and confirm inserted rows in `platform.survey_rf_observations`, `platform.survey_pose_samples`, `platform.survey_spectrum_observations`, and the `platform.survey_rf_pose_matches` fusion view. The backend raw RF/pose/spectrum ingest path has been validated against the shared CNPG fixture, and the live Pi emitted Arrow IPC frames for both Wi-Fi radios plus HackRF spectrum; a physical iPhone survey run is still required.
- [x] 8.5 Run the FieldSurvey iOS simulator build with Xcode after installing iOS 26.4 platform support.
- [x] 8.6 Smoke test the deployed Pi daemon against live hardware: `wlan1` and `wlan2` entered monitor mode and emitted binary Arrow IPC RF WebSocket frames; HackRF emitted a binary Arrow IPC spectrum frame after adding explicit `sweep_count` support for this `hackrf_sweep` build.
- [x] 8.7 Add a local web-ng FieldSurvey verification skill/script that connects to demo CNPG via NodePort, NATS Object Store via port-forward, and captures Playwright dashboard/review screenshots without waiting for demo image rebuilds.
- [x] 8.8 Validate the local web-ng FieldSurvey workflow with Playwright against demo data: the dashboard FieldSurvey card renders a persisted raster image plus 45 floorplan segments after the async FieldSurvey load completes.
- [x] 8.9 Validate dashboard AP marker rendering with Playwright against demo data: the FieldSurvey card renders one raster image, 45 floorplan segments, 8 AP candidate markers, and the RSSI legend.
