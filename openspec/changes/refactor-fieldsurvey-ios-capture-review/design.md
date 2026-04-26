# Design: FieldSurvey iOS Capture and Review

## Context
The Sidekick daemon and raw ingest path solve RF collection. The iOS app should no longer attempt to infer survey-grade Wi-Fi data from iPhone radios or render RF objects inside the live AR camera view.

The iPhone's primary responsibilities are:
- RoomPlan/ARKit capture and pose sampling.
- Sidekick pairing/control and RF stream relay.
- Local session persistence for offline work.
- Operator feedback that confirms data is flowing without overloading capture.

## Goals
- Keep live capture responsive while walking.
- Make Sidekick status and sample counts obvious.
- Save a complete local survey bundle containing room geometry, pose samples, Sidekick RF batches, and derived preview samples.
- Provide a 2D top-down review for quick field validation.
- Stream raw RF and pose data to ServiceRadar when backend auth is available.

## Non-Goals
- Full production-grade RF interpolation in the iOS capture view.
- 3D AP placement, glowing RF billboards, or AR signal orbs.
- Using iPhone Wi-Fi APIs as a backup RF scanner.
- Replacing the ServiceRadar/web-ng historical survey viewer.

## Decisions
- The live capture screen shall prioritize RoomPlan/ARKit and show only minimal telemetry: Sidekick connected state, RF batch/sample counts, pose quality, elapsed time, and save/upload controls.
- The 2D review shall be a SwiftUI/CoreGraphics or Canvas view, not SceneKit, unless profiling proves a native 2D approach is insufficient.
- RF heatmap rendering shall use downsampled/fused points for preview. Raw RF and pose data remain the source of truth.
- ServiceRadar/web-ng shall own the richer saved-survey view over backend fused tables.

## Risks / Trade-offs
- A simple 2D preview may be less visually impressive than AR overlays, but it is much easier to validate and keep responsive during capture.
- RoomPlan geometry export may not provide a perfect floorplan in all rooms; the review should degrade to a walked-path heatmap when wall geometry is incomplete.
- Offline saved sessions need a stable format so local review and later upload do not diverge.

## Migration Plan
1. Stabilize current capture by disabling native iPhone RF inputs and heavy 3D RF rendering.
2. Split capture, review, and settings into separate screens with explicit state.
3. Add the 2D review over existing `SurveySession` and `WiFiHeatmapPoint` data.
4. Add ServiceRadar/web-ng saved survey viewer over raw/fused backend tables.
5. Remove dead AR RF visualization code after the replacement review is validated.
