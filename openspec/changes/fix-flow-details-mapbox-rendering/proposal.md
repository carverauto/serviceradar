# Change: Fix Flow Details Mapbox Basemap Not Rendering

## Why
The Mapbox map in the NetFlow flow details panel displays a blank/black container with a globe outline but no basemap tiles (GH #2742). The root cause is the Content Security Policy in `router.ex` — `img-src` only allows `'self' data:` which blocks Mapbox tile images from `api.mapbox.com` and `*.tiles.mapbox.com`. Additionally, `worker-src` and `script-src blob:` are missing, which Mapbox GL JS v3 needs for its web workers that decode tiles.

Secondary issues: the `MapboxFlowMap` JS hook had no error handling, no `map.resize()` after mount, and no user-visible fallback when configuration is missing or broken — making the CSP issue invisible to diagnose without browser DevTools.

## What Changes
- **CSP fix**: Add Mapbox domains to `img-src`, add `worker-src blob:` and `script-src blob:` for Mapbox GL web workers.
- **Error handling**: Add `map.on("error", ...)` handler and user-visible fallback messages to the `MapboxFlowMap` hook.
- **Container sizing**: Add `position: relative`, explicit `min-height`, and `map.resize()` calls to ensure the canvas fills the container after LiveView mount.

## Impact
- Affected specs: `ui-maps`
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/router.ex` — CSP policy
  - `elixir/web-ng/assets/js/app.js` — `MapboxFlowMap` hook
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/netflow_live/visualize.ex` — map container markup
