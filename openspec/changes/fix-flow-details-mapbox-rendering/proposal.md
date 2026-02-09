# Change: Fix Flow Details Mapbox Basemap Not Rendering

## Why
The Mapbox map in the NetFlow flow details panel displays a blank container — the basemap tiles never load (GH #2742). The `MapboxFlowMap` JS hook initialises the map instance but has no error handling, no style-load validation, and no user feedback when the token or style URL is invalid. CSS conflicts with daisyUI/Tailwind may also prevent tile rendering.

## What Changes
- Add `error` and `style.load` event handlers to the `MapboxFlowMap` hook so Mapbox GL failures surface instead of silently swallowing.
- Validate the access token and style URLs before passing them to `mapboxgl.Map`; show a user-visible fallback message when configuration is missing or broken.
- Ensure the map container has explicit dimensions that survive Tailwind/daisyUI resets and parent grid constraints.
- Add debug logging (gated behind a flag or `console.warn`) so future rendering issues are diagnosable from the browser console.

## Impact
- Affected specs: `ui-maps`
- Affected code:
  - `web-ng/assets/js/app.js` — `MapboxFlowMap` hook
  - `web-ng/lib/serviceradar_web_ng_web/live/netflow_live/visualize.ex` — map container markup
  - `web-ng/assets/css/app.css` — Mapbox GL CSS isolation (if needed)
