## Context
The dashboard/fullscreen NetFlow map and the topology God View both render operator-facing network maps, but their interaction implementations are separate.

NetFlow is currently a canvas surface with SVG world/interaction overlays and a viewBox camera model, not deck.gl. Its interaction code is still the best existing behavior reference for topology controls:
- `scaledViewBox/3` preserves the point under the cursor by changing the viewBox origin and dimensions together.
- `translatedViewBox/3` pans from pointer deltas with clamped bounds.
- wheel events are non-passive and prevent page scroll while the map owns the gesture.
- pointer panning uses a movement threshold before suppressing clicks.
- controls expose zoom in, zoom out, reset, and world extent actions.

God View uses deck.gl with `controller: false` and manual `viewState` updates. Its pan path is close to the NetFlow model, but wheel zoom only changes `viewState.zoom`; it does not adjust `target` based on the pointer focal point. Its tier buttons also combine camera scale, topology presentation tier, and LiveView control state in ways that are hard to reuse.

On the backend, `GodViewStream.latest_snapshot/1` currently enforces a real-time budget in a way that can drop a valid freshly built snapshot. That is useful as telemetry but wrong as first-load availability behavior.

## Goals
- Keep `/topology` first-load behavior aligned with the existing 3-second first usable frame SLO.
- Make over-budget snapshot builds observable without converting valid payloads into unavailable responses.
- Reduce `TopologyLive.GodView` to a thin LiveView with idiomatic Elixir modules for state and workflows.
- Bring NetFlow-like interaction semantics to God View's deck.gl orthographic map without changing NetFlow code.
- Preserve God View zoom tiers and packet-flow readability while improving camera control behavior.

## Non-Goals
- Replacing the NetFlow map renderer with deck.gl in this change.
- Changing the topology snapshot schema version or Arrow payload contract.
- Changing camera relay authorization semantics.
- Reworking the entire God View renderer or layout engine beyond camera/control integration.

## Proposed Module Shape
Elixir:
- `ServiceRadarWebNGWeb.TopologyLive.GodView` remains the LiveView entrypoint and should contain mount, render delegation, small event forwarding clauses, and `handle_info/2`.
- `GodViewTemplate` or component modules own HEEx and presentation helpers.
- `GodView.StreamState` owns stream stats normalization, startup retry/error classification, and client perf alert emission.
- `GodView.MtrOverlay` owns MTR graph loading, normalization, caching, and push-event payload construction.
- `GodView.CameraRelay` owns single relay session open/close/refresh workflows.
- `GodView.CameraRelayTiles` owns cluster/tiled relay workflows and notices.
- `GodView.ControlState` owns zoom/layer/filter assign transformations and push-event payloads.

JavaScript:
- `god_view/deck_camera_controls.js` owns pure math for clamping, focal zoom, pointer-to-canvas conversion, and orthographic pan state.
- God View delegates wheel/pan/control actions to the deck camera helper and maps resulting zoom values back to zoom-tier presentation.
- NetFlow remains unchanged; its interaction model is used only as the reference for expected behavior.

## Key Decisions
- The real-time snapshot budget is telemetry and backpressure guidance, not a reason to reject a valid payload on the initial request.
- Auto-fit reset in God View should clear `userCameraLocked` and recompute bounds from the latest graph; explicit zoom/pan should set `userCameraLocked`.
- The God View tier buttons may remain as presentation shortcuts, but direct map controls must exist and behave consistently with NetFlow.
- The shared map modules should be pure/testable first. Renderer-specific DOM work should stay in adapters.

## Risks
- God View control changes could regress existing zoom-tier presentation. Mitigate with existing God View tests plus new pure camera helper tests.
- God View focal zoom math can feel inverted if deck.gl target conversion is wrong. Mitigate with unit tests that verify world point preservation around the cursor.
- A large Elixir refactor can mask behavior changes. Mitigate by moving code in small responsibility slices and keeping LiveView tests focused on observable events/assigns.
