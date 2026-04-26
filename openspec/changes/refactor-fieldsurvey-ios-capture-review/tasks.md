## 1. Stabilize Capture
- [x] 1.1 Stop using iPhone Wi-Fi APIs for RF survey measurements.
- [x] 1.2 Remove BLE RF survey ingestion from the capture path.
- [x] 1.3 Disable heavy 3D AP/RF objects in the live capture view.
- [x] 1.4 Throttle live visualization updates and preserve live Sidekick preview data on stop/restart.
- [x] 1.5 Remove AR AP auto-detection, tap-assist halos, manual landmark halos, and 3D AP node construction from capture.
- [x] 1.6 Add a plain manual "mark AP here" capture control that stores the current LiDAR pose without drawing AR markers.
- [x] 1.7 Stop SceneKit rendering during LiDAR capture; reserve SceneKit for explicit map/review mode only.
- [x] 1.8 Throttle Sidekick preview decode and published batch counters so RF streams do not drive SwiftUI updates per packet batch.
- [x] 1.9 Throttle RoomPlan/ARKit state publishing and reserve display-link rendering for map/review mode.
- [ ] 1.10 Smoke test physical iPhone LiDAR capture after Sidekick preview stop/start.
- [x] 1.11 Preserve autosaved survey state when Sidekick preview stops/restarts.
- [x] 1.12 Expand default Sidekick 2.4 GHz channel hopping beyond 1/6/11 so nonstandard home AP channels are captured.
- [x] 1.13 Use all monitor-capable USB radios in automatic Sidekick radio assignment, splitting 5 GHz and 2.4 GHz work across adapters.

## 2. Capture Workflow
- [ ] 2.1 Split the current survey screen into explicit setup, capture, and review states.
- [ ] 2.2 Add capture status counters for Sidekick connection, active radios, RF batches, RF observations, pose samples, elapsed time, and backend/offline mode.
- [ ] 2.3 Make start/stop survey state deterministic for offline preview and backend streaming.
- [ ] 2.4 Add a "discard live RF preview" action that clears derived preview state without deleting saved sessions.
- [ ] 2.5 Add an RF Update mode that reuses an existing room/survey review baseline, captures new Sidekick RF with lightweight pose tracking, and avoids RoomPlan mesh reconstruction unless the operator explicitly remaps geometry.
- [ ] 2.6 Add a manual alignment/relocalization step for RF Update mode so new walk-path coordinates can be aligned to the saved room coordinate space before comparing heatmaps.

## 3. 2D In-App Review
- [x] 3.1 Add a 2D top-down survey review view over saved `SurveySession` data.
- [x] 3.2 Project room geometry, walked path, AP labels, and RF heatmap points into a stable floor-plane coordinate space.
- [x] 3.3 Render signal strength with a bounded color legend and downsampled grid/cell interpolation.
- [x] 3.4 Support review of local offline sessions without a backend connection.
- [x] 3.5 Support pan/zoom and simple multi-floor filtering in the local signal map.
- [x] 3.6 Add per-BSSID signal map filtering and AP observation counts so dominant APs do not hide weaker/less frequent observations.
- [x] 3.7 Add Sidekick spectrum summary stream consumption for live iOS spectrum telemetry.
- [x] 3.8 Add a compact spectrum analyzer panel in capture and Live Signal Map.
- [x] 3.9 Add a separate RF interference overlay in Live Signal Map from saved spectrum summaries and timestamps.
- [x] 3.10 Persist local spectrum summaries in autosaved survey sessions.
- [x] 3.11 Add Gaussian-process/Kriging-style derived Wi-Fi coverage and confidence overlays from sparse Sidekick heat points.

## 4. Backend/Web Review
- [ ] 4.1 Add or extend ServiceRadar/web-ng route for saved FieldSurvey sessions.
- [ ] 4.2 Query backend RF/pose fusion data for a session and return 2D heatmap-ready points.
- [ ] 4.3 Render a ServiceRadar survey heatmap comparable to the target screenshot.

## 5. Verification
- [ ] 5.1 Run FieldSurvey iPhone build and install.
- [ ] 5.2 Run focused Swift tests for Sidekick URL/error handling and session review projection.
- [ ] 5.3 Perform an iPhone/Pi capture smoke test and verify local save/review.
- [ ] 5.4 Perform an iPhone/Pi/backend smoke test and verify ServiceRadar saved-survey review.
