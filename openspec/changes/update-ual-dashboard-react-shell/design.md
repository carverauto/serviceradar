# Design: UAL Dashboard React Shell Migration

## Context

`add-dashboard-sdk-query-state` shipped React primitives (`useDeckMap`, `useDeckLayers`, `useFilterState`, `useIndexedRows`, `useDashboardQueryState`, `useFrameRows`) and surgical perf fixes in UAL. The renderer subtree is still imperative: a `useDashboardController` factory creates a Mapbox map, a `MapboxOverlay`, a frame ingest pipeline, an event handler graph against `data-*` selectors, and an `innerHTML`-rewriting sidebar. The React shell is just a `<DashboardShell>` skeleton that renders empty containers for the imperative code to populate.

This design covers the structural rewrite. The user-facing behavior, the data-frame contracts, the renderer artifact name (`renderer.js`), and the manifest entry (`mountDashboard`) do not change.

## Goals

- Make the UAL renderer the canonical example of a React-first dashboard package.
- Compose every non-WebGL visual element from React components keyed on stable props.
- Drive every SDK roundtrip through SDK hooks rather than imperative `api.srql.update` calls in event listeners.
- Keep the same on-screen pixels and the same parity test outcomes after the refactor.
- Cut the file count under `src/map/` substantially (target: under 8 files for utilities and shapes; the rest become React components or get removed).

## Non-Goals

- A visual redesign. Same colors, layout, controls, popups.
- A new SDK UI library (chrome, sidebar primitives, chip primitives). UAL builds these as internal React components for now. If a second customer dashboard appears and a clear pattern emerges, we extract them in a later proposal.
- Migrating away from `mapboxgl` or `deck.gl`.
- Changing the dashboard manifest, renderer artifact format, or host APIs.

## Removed Scope: WebGL fallback

The original imperative renderer ships a static-map fallback (`staticMapFallback.js`, `staticProjection.js`, `staticTerritories.js`) that triggers when `supportsWebGL()` returns false or when a `webglcontextlost` event fires. This is dead weight: every supported browser ships WebGL, and a `webglcontextlost` event during normal operation should surface as a hard error so the underlying GPU/driver problem is investigated, not papered over with a hand-projected SVG of the United States. The fallback also forces every popup, territory, and click handler to be implemented twice. We delete it. If a client genuinely cannot render WebGL — which has not been observed in any UAL telemetry — the dashboard fails the way any other map-dependent ServiceRadar feature fails.

## Decisions

### Decision: Single React tree rooted at `UalNetworkMap`

Today `UalNetworkMap.jsx` renders `<DashboardShell>` (just `<div>` skeletons) and uses `useDashboardController(createUalMapController, {clearRoot: false})` to attach the imperative controller to that DOM. After the rewrite, `UalNetworkMap` returns a real React tree. The imperative controller goes away. The renderer host still calls `mountDashboard` exactly as before; the change is internal to the package.

**Alternative considered**: keep the imperative controller and incrementally Reactify pieces (e.g. just the sidebar). Rejected because the imperative controller and React tree would both need to coordinate state during the transition, doubling complexity rather than removing it.

### Decision: State lives in React, not in a state object

Today `mapState.js` exposes a mutable `state` object that imperative code reads and writes. After the rewrite, the equivalent state is split between `useFilterState` (filter shape), `useDashboardQueryState` (SRQL query state), `useFrameRows({shape})` (raw row data, projected), and a small set of `useState` for ephemerals (focused site, sidebar collapse, territories visible, full-screen). No top-level mutable container.

**Alternative considered**: keep `mapState.js` as a Zustand-like store. Rejected because the SDK already provides the right hooks; introducing a third state mechanism would compete with both.

### Decision: New SDK primitive `useMapPopup`

Mapbox popups are imperative — `new mapboxgl.Popup({...}).setHTML(...).addTo(map)` and explicit `.remove()`. To render React content inside them cleanly, we add an SDK hook that:

- Creates the popup lazily when first opened
- Mounts a React subtree into the popup's content node via `createRoot`
- Re-renders the subtree when the React content prop changes
- Unmounts and removes the popup on `close()`, on map click outside, or on component unmount
- Exposes the underlying `mapboxgl.Popup` for escape-hatch styling and event hooks

Signature:
```js
const popup = useMapPopup(map, {
  closeOnClick: true,
  className: "ual-site-popup",
  offset: 12,
  onClose: () => setFocused(null),
})

// In effects or event handlers:
popup.open({coordinates: [lng, lat], content: <SitePopup site={focused} />})
popup.close()
```

This avoids each dashboard package re-implementing the popup-React bridge. It lives in `serviceradar-sdk-dashboard/src/react.js` (or a new `popup.js` if the React.js file gets too large) and is the only SDK-level addition this proposal introduces.

**Alternative considered**: build the popup bridge inside UAL only. Rejected because every map dashboard will need this, and the SDK already provides the matching `useMapPopup`-shaped surfaces in its `DashboardPopupApi` contract — but that API is for in-page popups, not Mapbox-anchored ones.

### Decision: Component layout

```
src/
├── main.jsx                          # unchanged: mountReactDashboard(UalNetworkMap)
├── app/
│   ├── UalNetworkMap.jsx             # top-level: composes everything
│   ├── DashboardError.jsx            # unchanged
│   ├── useUalState.js                # filter + query-state composition hook (UAL-internal)
│   ├── useUalFrames.js               # frame-shape projections (UAL-internal)
│   └── components/
│       ├── MapStage.jsx              # useDeckMap + useDeckLayers + useMapPopup
│       ├── Sidebar.jsx               # search + filters + lists
│       ├── Stats.jsx                 # toolbar stat counters
│       ├── FilterChips.jsx           # generic chip group
│       ├── SiteList.jsx              # virtualized site list
│       ├── DeviceList.jsx            # device search results
│       ├── SitePopup.jsx             # popup content for site / cluster
│       ├── HoverTooltip.jsx          # follow-cursor hover tooltip
│       ├── Chrome.jsx                # toolbar buttons (full, territories, reset, theme)
│       └── StaticFallback.jsx        # WebGL fallback wrapper
└── map/
    ├── shapes.js                     # row shape definitions for useFrameRows
    ├── deckSpecs.js                  # layer spec builders consumed by useDeckLayers
    ├── clustering.js                 # pure clusterSites helper
    ├── hitTesting.js                 # pure nearestClickableSite helper
    ├── srqlBuilders.js               # buildWifiSiteSrql, buildFrameSrqlOverrides, hydrateFiltersFromSrql, viewport readers
    ├── styles.js                     # DASHBOARD_STYLES, basemap style helpers
    ├── territories.js                # static territory + exception helpers
    └── constants.js                  # CLUSTER_ONLY_ZOOM, REGION_COLORS, etc.
```

Files retired from `src/map/`: `chromeControls.js`, `createUalMapController.js`, `deckLayers.js`, `filterActions.js`, `filterCounts.js`, `frameData.js`, `mapInteractions.js`, `mapRenderer.js`, `mapState.js`, `mapStyles.js` (folded into `styles.js`), `popups.js`, `sidebarRenderers.js`, `siteActions.js`, `srqlFilters.js`, `srqlQuery.js`, `viewportFilters.js`, `staticMapFallback.js` (becomes `StaticFallback.jsx` component), `staticProjection.js`, `staticTerritories.js`. Roughly 18 imperative files collapse to about 8 utility modules plus the React component tree.

### Decision: Frame data flows through shape projections

Each WiFi frame gets a shape declaration:

```js
// src/map/shapes.js
export const SITE_SHAPE = {
  site_code: (row) => String(row.site_code || row.iata || "").toUpperCase(),
  name: "name",
  region: (row) => normalizeRegion(row.region),
  latitude: (row) => Number(row.latitude ?? row.lat),
  longitude: (row) => Number(row.longitude ?? row.lon),
  ap_count: (row) => Number(row.ap_count || 0),
  // ... etc.
  ap_families: (row) => apFamilies(parseCounts(row.model_breakdown || row.models)),
}
```

Then in components: `const sites = useFrameRows("sites", {shape: SITE_SHAPE})`. The SDK caches projection by `(frame digest, shape identity)`, so repeated renders with unchanged frame digests return the same `sites` reference. The `useIndexedRows(sites, {indexBy: ...})` downstream rebuilds indexes only when that reference changes.

### Decision: Filter state and SRQL state compose, not duplicate

Today the imperative shell tracks filters in `state.filters` and rebuilds SRQL on every change. After the rewrite:

```js
const filters = useFilterState({
  initialState: {regions: new Set(), apFamilies: new Set(), /* ... */, query: ""},
  debounceMs: 350,
  debounceFields: ["query"],
})

const queryState = useDashboardQueryState({
  initialState: filters.debouncedState,
  buildQuery: (state) => buildWifiSiteSrql(state),
  buildFrameQueries: (state) => buildFrameSrqlOverrides(state),
})

useEffect(() => queryState.apply(filters.debouncedState), [filters.debouncedState])
```

`filters.state` drives the immediate sidebar/local filtering response. `filters.debouncedState` drives the SRQL roundtrip via `queryState`. The dedupe in `useDashboardQueryState` prevents redundant host updates when the debounced state's query fingerprint hasn't changed.

### Decision: Layer memoization comes from `useDeckLayers`, not custom caching

The surgical change in the prior proposal added a manual layer cache in `createUalMapController.js`. After the rewrite that disappears: `useDeckLayers` already memoizes per-layer when `data`/`accessors`/`visualProps` references are stable. Components produce the spec via `useMemo` keyed on the things that actually changed.

```js
const data = useMemo(() => clusterIfZoomedOut(filteredSites, viewState), [filteredSites, viewState.zoom])
const accessors = useMemo(() => ({
  getPosition: (site) => [site.longitude, site.latitude],
  getRadius: (site) => siteRadius(site, filters),
}), [filters.downOnly, filters.apFamilies, filters.wlcModels])
const visualProps = useMemo(() => themedVisualProps(theme), [theme])

useDeckLayers(mapHandle, {
  sites: scatter("sites", {data, accessors, visualProps, events: {onClick}}),
})
```

Accessor identity is the perf-critical lever. We accept that `useMemo` deps need to be carefully curated; tests assert layer-instance stability across no-op renders.

### Decision: Delete the WebGL fallback

Today, when `supportsWebGL()` returns false, the imperative controller short-circuits and mounts a static SVG fallback that hand-projects sites onto a US map. The fallback also fires when a `webglcontextlost` event hits the canvas. Both branches double every popup, territory, and click handler. WebGL is universally available in supported browsers, and a context-lost event during normal use indicates a real GPU/driver fault that should be reported, not papered over.

The React shell does not include a fallback. `MapStage` mounts directly. If `mapboxgl` fails to initialize, the same error path that handles any other Mapbox failure handles this one. The fallback files are deleted in Section 8 cleanup.

### Decision: Popups receive React content via `useMapPopup`

Site popups, cluster popups, and AP/WLC detail expansion all become React components rendered inside the Mapbox popup via `useMapPopup`. The popup state (which site is focused, which list is expanded) lives in React state on the parent component. Toggling "show down APs" no longer rewrites the popup HTML — it changes a piece of React state and the popup body re-renders normally.

## Risks and Trade-offs

**Risk: Behavior drift during refactor.** The imperative shell has accumulated specific behaviors (suppress viewport query for 800ms after load, last-deck-click-at debounce against map-canvas clicks, theme-derived `usingStatic` flag transitions, AP/WLC list expansion mutual exclusion in popups). Each must be explicitly ported.

*Mitigation*: enumerate the ported behaviors in `tasks.md` with one-line invariants and add unit/Playwright tests asserting each before deleting the original code. The existing 11 UAL unit tests cover SRQL hydration, viewport sync, drill reset, and click radius — extend them, don't replace them.

**Risk: Memoization deps incorrectly written.** The whole point of `useDeckLayers` memoization is layer-instance stability. If a developer writes `useMemo(() => ..., [filteredSites, filters])` where `filters` is the whole state object that changes on every chip toggle, layers rebuild on every render and the perf win is lost.

*Mitigation*: pull only the load-bearing fields into the deps; document the pattern explicitly; ship a unit test that asserts no layer rebuild occurs across a no-op re-render.

**Risk: Sidebar virtualization regressions.** Currently the sidebar `innerHTML` rewrite handles 500-row site lists in a single DOM rewrite per render. Switching to React `.map(...)` over 500 components could be slower than the rewrite for the *initial* render even if it wins on re-renders.

*Mitigation*: use a virtualization library (e.g. `react-window`) for the site list and the device list. Both lists already cap to small visible windows; virtualization keeps DOM size constant.

**Risk: Mapbox popup React mount lifecycle.** `createRoot` in a popup that opens/closes/reopens needs careful unmount or React warnings (and memory leaks) accumulate.

*Mitigation*: `useMapPopup` owns the createRoot lifecycle; it calls `root.unmount()` synchronously before `popup.remove()`. Tests cover open/close/reopen cycles.

**Risk: Bigger PR than usual.** A 18-file collapse with React adoption is a large diff.

*Mitigation*: stage the refactor in two PRs — first land the SDK `useMapPopup` and the new component tree alongside the imperative one (gated by an env flag), then flip the flag and remove the imperative tree once parity is confirmed. Both PRs are reviewable in isolation.

## Migration Plan

1. SDK `useMapPopup` lands first (small, isolated, easy to review).
2. Build the new component tree under `src/app/components/` while leaving `createUalMapController.js` running. UalNetworkMap renders one or the other based on a build-time flag.
3. Run both trees in parallel against the parity harness; fix gaps in the React tree.
4. Flip the flag default to React. Run parity again.
5. Delete the imperative files and the flag.
6. Archive this OpenSpec change and update the README to point to the React shell as the reference pattern.

Rollback: keep the imperative tree behind the flag for one release; if a serious regression is found, flip the default back. After the next release, delete it.

## Open Questions

- **Sidebar virtualization library choice.** `react-window` is the obvious pick (small, stable, MIT). But it's a runtime dep on the dashboard package. Confirm the host accepts the bundle-size impact.
- **CSS scoping.** Today `DASHBOARD_STYLES` injects via a `<style>` tag at the renderer root. Should we keep that, switch to CSS Modules, or use the host's design tokens directly? Recommend keeping the inline `<style>` for now since it's already shadow-DOM-friendly and matches the renderer artifact contract; revisit when the host design-token API stabilizes.
- **Saved view hydration.** The current `hydrateFiltersFromSrql` parses the host's initial SRQL query string on mount to populate the filter state. After the rewrite, this still runs but lives in `useUalState` instead of `mapState.js`. Confirm the parser regexes survive the move unchanged — they're tested today.
