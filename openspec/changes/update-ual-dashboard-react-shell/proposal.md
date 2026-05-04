# Change: Migrate UAL dashboard renderer to React-driven shell

## Why

The UAL WiFi map renderer ships under `~/src/ual-dashboard` as the reference customer dashboard package. After `add-dashboard-sdk-query-state` shipped — adding `useDeckMap`, `useDeckLayers`, `useFilterState`, `useDashboardQueryState`, `useFrameRows`, `useIndexedRows`, frame digest stability, and lazy Arrow decode — the SDK is now capable of expressing the dashboard as a React tree. UAL still uses the imperative controller pattern: `createUalMapController.js` orchestrates Mapbox + deck.gl + theme + frames + click handlers in 187 lines, `mapRenderer.js` rewrites sidebar `innerHTML` on every render, `mapInteractions.js` wires `addEventListener` against `data-*` attributes, `frameData.js` hand-rolls `normalizeSites`/`normalizeDevices`. Surgical perf fixes (rAF-coalesced render, indexed filter, layer memo) landed in the prior change, but the structural debt remains.

Two costs come from leaving the structure alone. First, the next dashboard package author will copy the UAL pattern — replicating 18 imperative files because the reference dashboard told them that's how it's done. Second, every visual change to the sidebar still goes through `innerHTML` rewrites that lose focus, lose scroll, and force reflow on the row that the user is actively interacting with. The SDK primitives are designed to remove both of those, but only if the reference dashboard demonstrates them.

This change finishes the migration: the imperative controller and the imperative DOM rewrites go away, replaced by a React subtree rooted at the existing `mountReactDashboard` entrypoint and composed of SDK hooks plus UAL-internal React components for sidebar/popup/chrome. One small SDK addition is needed — a React-mounted Mapbox popup helper — because the dashboard host injects `mapboxgl.Popup` with imperative HTML, and dashboards need a clean way to render React content into it.

## What Changes

- Add `useMapPopup` to the dashboard SDK so dashboards can mount React content inside Mapbox popups with managed lifecycle, proper unmount on close, and stable focus/scroll behavior.
- Rewrite the UAL renderer subtree under `~/src/ual-dashboard/src/` so the React tree owns map runtime, layers, filter state, SRQL roundtrip, frame data, sidebar, popups, hover tooltips, and the device/site lists. The renderer entry (`mountReactDashboard(UalNetworkMap)`) does not change.
- Replace `createUalMapController.js` + `mapInteractions.js` + `mapRenderer.js` + `sidebarRenderers.js` + most of `popups.js` with React components and SDK hooks. Retire the imperative state object (`mapState.js`) in favor of React state.
- Replace `frameData.js` `normalizeSites`/`normalizeDevices` with `useFrameRows({shape})` plus thin domain-specific projections. Keep the WiFi-specific derived helpers (AP family extraction, model-counts parsing) as utility functions consumed by the shape projections.
- Replace `filterCounts.js` linear filtering with `useIndexedRows` driven from a `useFilterState` shape. The query/SRQL roundtrip moves to `useDashboardQueryState` — the surgical `srqlQuery.js` plumbing can be deleted once the React shell drives the SRQL update path.
- Replace `deckLayers.js` raw `new ScatterplotLayer(...)` constructors with `useDeckLayers` specs. The clustering helper (`clusterSites`) and the `nearestClickableSite` hit-testing logic stay as pure utilities the React shell calls.
- Delete the static-map WebGL fallback (`staticMapFallback.js`, `staticProjection.js`, `staticTerritories.js`) and the `supportsWebGL` short-circuit. Every supported browser ships WebGL; the fallback is dead weight that complicates the controller and doubles the popup/territory rendering paths. If WebGL is genuinely unavailable, the dashboard surfaces a Mapbox load error like any other map-dependent ServiceRadar feature.
- Convert the chrome (`chromeControls.js`, theme switcher, fullscreen, territory toggle, reset button, search input) to React components consuming `useDashboardTheme`/`useDashboardCapability`/`useDashboardNavigation`.
- Drop the `data-*` attribute selectors that the imperative shell relied on. The `DashboardShell.jsx` render-only skeleton becomes a real component tree with props.
- Preserve every user-facing behavior verified by the existing parity harness: SRQL hydration on mount, server-driven filters, drill into site / cluster, zoom-out drill reset, popup contents, AP/WLC detail rows, fleet migration trend, freshness indicator, full-screen toggle, sidebar collapse, search-as-you-type.

## Impact

- Affected specs: dashboard-sdk
- Affected code:
  - `/home/mfreeman/src/serviceradar-sdk-dashboard/src/react.js`, `react.d.ts`, README, tests — `useMapPopup` addition
  - `/home/mfreeman/src/ual-dashboard/src/` — broad restructure of `app/` and `map/` directories
  - `/home/mfreeman/src/ual-dashboard/tests/` — unit and Playwright parity tests updated against the new component tree
- Follow-up validation: SDK unit tests for `useMapPopup`, UAL unit tests for the new components, UAL harness parity, Docker/local web-ng Playwright checks, per-keystroke filter latency capture against the standalone reference (`tmp/wifi-map/site_inventory_map.html`)
