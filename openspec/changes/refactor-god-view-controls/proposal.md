# Change: Refactor God View controls and snapshot reliability

## Why
God View currently mixes LiveView lifecycle, stream telemetry, MTR overlay loading, camera relay orchestration, template rendering, and control state in one oversized module. Its deck.gl zoom behavior also diverges from the proven NetFlow map interaction model: NetFlow preserves the cursor focal point on wheel zoom and exposes direct zoom/reset controls, while God View changes only zoom and relies on tier buttons.

The recent startup failure was not only a cosmetic loading issue. A valid topology snapshot can be built after the configured real-time budget, then be reported as unavailable and deferred to the next stream tick. That violates the existing first usable frame SLO when the backend already has a usable snapshot.

## What Changes
- Refactor the God View LiveView into responsibility-focused modules so the LiveView owns mount/event delegation and assign orchestration, while template, stream state, MTR overlays, client perf telemetry, and camera relay workflows live in dedicated project modules.
- Change God View snapshot budget handling so valid snapshots are served even when they exceed the real-time budget, while telemetry still records the over-budget condition.
- Add runtime and Helm configuration for snapshot budget/coalescing so supported environments can tune the reliability/performance tradeoff without code changes.
- Use the NetFlow map as a behavioral reference, but keep NetFlow code unchanged in this change. Implement topology-specific deck.gl orthographic controls for God View.
- Update God View zoom controls to use the same direct interaction model as NetFlow: pointer-focal wheel zoom, thresholded pan, zoom in/out, reset/fit, and stable auto-fit semantics while preserving God View zoom-tier presentation.
- Add focused Elixir and JavaScript regression coverage for the snapshot budget behavior, LiveView module boundaries, NetFlow control parity, and God View deck.gl controls.

## Impact
- Affected specs: `topology-god-view`, `build-web-ui`
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng/topology/god_view_stream.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/topology_live/**`
  - `elixir/web-ng/assets/js/lib/god_view/**`
  - web-ng tests and Helm runtime configuration
