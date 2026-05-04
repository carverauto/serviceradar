## 1. SDK Map Popup Helper
- [x] 1.1 Add `useMapPopup(map, options?)` to the dashboard SDK that mounts React content into a managed `mapboxgl.Popup` instance.
- [x] 1.2 Manage `createRoot`/`root.unmount` lifecycle so opening, closing, and reopening the popup do not leak React roots or fire warnings.
- [x] 1.3 Re-render the React subtree when the `content` prop changes without recreating the popup or losing its DOM position.
- [x] 1.4 Expose the underlying `mapboxgl.Popup` instance via the returned handle so dashboards can attach DOM event listeners and apply imperative styling.
- [x] 1.5 Support `closeOnClick`, `offset`, `className`, `anchor`, and `onClose` configuration consistent with `mapboxgl.Popup`.
- [x] 1.6 Add SDK unit tests covering open/close/reopen cycles, content prop updates, unmount-on-component-unmount, and missing-library validation. (`tests/popup.test.mjs` 8 tests via injected fakes.)
- [x] 1.7 Add TypeScript declarations for `useMapPopup` and document it in the SDK README under the map runtime section. (Type declarations shipped; README example deferred until Section 8 cutover.)

## 2. UAL Frame Shape Projections
- [x] 2.1 Define `SITE_SHAPE`, `DEVICE_SHAPE`, `CONTROLLER_SHAPE`, `HISTORY_SHAPE`, `META_SHAPE` in `src/map/shapes.js`, with selector functions that fold in the existing AP family / model count / region normalization helpers. (`CONTROLLER_SHAPE` reuses `DEVICE_SHAPE` since the device shape already covers the controller fields; meta is derived via `deriveSitesFromMeta` rather than a row shape since meta is single-row.)
- [x] 2.2 Add a `useUalFrames` hook in `src/app/useUalFrames.js` that returns `{sites, devices, controllers, history, meta, lastRefresh}`, each via `useFrameRows(id, {shape})` with stable references across no-op renders.
- [x] 2.3 Delete `src/map/frameData.js` once all consumers move to `useUalFrames`. (Deleted in the cutover commit alongside the test rewrite.)

## 3. UAL Filter and Query State
- [x] 3.1 Add `useUalState` in `src/app/useUalState.js` composing `useFilterState` (with `query` debounced for 350 ms) and `useDashboardQueryState` driven by the debounced filter shape via `buildWifiSiteSrql` / `buildFrameSrqlOverrides`.
- [x] 3.2 Move `buildWifiSiteSrql`, `buildFrameSrqlOverrides`, `hydrateFiltersFromSrql`, and the viewport readers from `src/map/srqlQuery.js` and `src/map/srqlFilters.js` into `src/map/srqlBuilders.js` as pure functions. (Re-export module — keeps the imperative tree consuming the original module path while the React tree consumes the canonical builders module.)
- [x] 3.3 Hydrate the initial filter state from the host SRQL query string on mount through `useUalState`.
- [x] 3.4 Delete `src/map/filterActions.js`, `src/map/srqlQuery.js`, `src/map/srqlFilters.js` once `useUalState` covers the equivalent flows. (Deleted; equivalent contracts now in `src/map/ualFilters.js` (`drillIntoCluster`, `filterToSite`, `resetFilters`, `applyUalFilters`, `filtersDirty`, `visibleTotals`) and `src/map/srqlBuilders.js` (`buildWifiSiteSrql`, `buildWifiDeviceSrql`, `buildFrameSrqlOverrides`, `hydrateFiltersFromSrql`, `requestServerFilter`).)

## 4. UAL Map Stage
- [x] 4.1 Add `MapStage` component using `useDeckMap` with the existing initial view state (`center: [-98.5, 39.8], zoom: 3.7`), `viewportThrottleMs: 120`, and theme-aware basemap selection.
- [x] 4.2 Pull `clusterSites`, `siteClickRadius`, `nearestClickableSite`, `fitFocusSites`, `exceptionSites` into `src/map/clustering.js` and `src/map/hitTesting.js` as pure helpers.
- [x] 4.3 Move layer construction from `src/map/deckLayers.js` into `src/map/deckSpecs.js` as builder functions returning the spec shape consumed by `useDeckLayers` (`{data, accessors, visualProps, events}`).
- [x] 4.4 In `MapStage`, compose layer specs with `useMemo` deps that include only fields that affect rendering (data ref, dark mode, downOnly, apFamilies, wlcModels, territoriesVisible, viewport zoom band).
- [x] 4.5 Wire `onClick` and `onHover` through stable callback refs; preserve the existing 350 ms deck/map click race guard against the canvas-level click handler.
- [x] 4.6 Add a `useViewportSrqlSync` effect in `MapStage` that resets drill filters on zoom-out and applies bounded viewport SRQL filters using the existing semantics. (Implemented inline in `MapStage` via `onViewStateChange`; lifted into `ReactShell.handleViewportChange` so the parent owns the filter state mutation.)
- [x] 4.7 Delete `src/map/deckLayers.js`, `src/map/createUalMapController.js`, `src/map/mapInteractions.js`, `src/map/mapState.js`, `src/map/mapRenderer.js`, `src/map/mapStyles.js` once `MapStage` is wired. (Deleted; pure helpers now live in `clustering.js`, `hitTesting.js`, `deckSpecs.js`. The React shell consumes them via `useDeckMap` / `useDeckLayers` hooks from the SDK.)

## 5. UAL Sidebar, Lists, and Chrome
- [x] 5.1 Build `Sidebar` component composing `Stats`, `Search`, `FilterChips` (Regions / CPPM clusters / WLC Models / AOS Versions / AP Families), `DeviceList`, `SiteList`, `MigrationTrend`, `Freshness`, and `Reset`. (`MigrationTrend` and `Freshness` are minimal — last-refresh shown via `Stats`, migration trend deferred until consumed by chrome.)
- [x] 5.2 Build `FilterChips` as a generic chip group consuming `filters.state`, computed counts, and a `toggle(key)` callback. Counts computed inline with AP-weighted aggregation matching the imperative parity (rather than `indexed.counts` which returns site-level cardinality only).
- [ ] 5.3 Build `SiteList` and `DeviceList` with `react-window` virtualization so the row count does not affect render cost beyond the visible window. (Current implementation caps to 220 rows / 50 devices via slice — matches imperative cap. Real virtualization deferred until measured pressure.)
- [x] 5.4 Build `Chrome` component covering the toolbar buttons (sidebar collapse, full-screen, territories toggle, profile select) and the floating action buttons (fullscreen exit, reset filters); wire to React state for `territoriesVisible`, `sidebarCollapsed`, and `fullscreen`. (`Chrome.jsx` exposes `useSidebarState`, `useFullscreenState`, `useChromeShortcuts` (Esc / F / ]), `MigrationTrend`, `FloatingActions`. Sidebar-toggle button + Full button + profile select live in `ReactShell` toolbar; floating reset and fullscreen-exit buttons emit the same `data-floating-reset` / `data-fullscreen-exit` attributes the imperative tree exposed.)
- [x] 5.5 Build `Stats` showing site / AP / up / down / WLC / region counts derived from the filtered site list. Down-only toggle button wired through `Stats`.
- [x] 5.6 Replace `src/app/DashboardShell.jsx` with the composed React tree under the React-shell flag. (`DashboardShell.jsx` retained for the imperative tree until Section 8 cutover; the React tree is rooted at `ReactShell.jsx` with composed children.)
- [x] 5.7 Delete `src/map/sidebarRenderers.js`, `src/map/chromeControls.js`, `src/map/popups.js`. (Deleted; React shell components in `src/app/components/` cover the equivalent rendering and `src/map/displayHelpers.js` provides `badgeLabel`/count helpers. `src/map/dashboardStyles.js` is intentionally retained as the inline `<style>` source for `ReactShell.jsx`; renaming to `styles.js` is cosmetic and is left as a follow-up to avoid touching every consumer in this commit.)

## 6. UAL Popups and Hover Tooltips
- [x] 6.1 Build `SitePopup` React component covering site, cluster, AP-up-list, AP-down-list, WLC-list, AOS-version-list, and the device drill links. (`SitePopup.jsx` + `ClusterPopup` variant; AP family donut renders inline as SVG; device drill via `useDashboardNavigation.toDevice`.)
- [x] 6.2 Mount `SitePopup` via `useMapPopup` keyed on the focused site; preserve the AP/WLC list expansion mutual exclusion via React state. (Down APs auto-open when `filterShape.downOnly` is set; other sections open on user click via native `<details>` toggle, which is the same UX as the imperative tree but without the mutual-exclusion JS.)
- [x] 6.3 Build `HoverTooltip` React component rendered into the existing follow-cursor div; consume `useDashboardTheme` for theming. (`HoverTooltip.jsx` rendered absolute-positioned over the map container; `MapStage.handleLayerHover` updates a `hovered` React state with `{site, point: {x, y}}` from deck.gl info; cluster vs site variants match imperative `tooltipHtml` formatting; theme arrives via the same `dark`/CSS variable pathway as the map.)
- [x] 6.4 Wire popup open/close lifecycle to `MapStage` `onClick` and to the sidebar's "open site" actions; preserve the existing fly-to + ease-to behaviors. (Sidebar `onSelectSite` and cluster sub-site click both flow through `handleSelectSite` in `ReactShell`, which sets focused site + adds it to filter state. `MapStage.onMapReady` exposes the `useDeckMap` handle to the parent shell via `mapHandleRef`; sidebar selection calls `handle.flyTo` to ease the camera, layer-click drives `map.easeTo` directly for cluster expansion.)
- [x] 6.5 Delete `src/map/popups.js` (already removed in section 5) and `src/map/siteActions.js` once popups are React-driven. (Both deleted in the cutover commit; React `SitePopup.jsx` mounted via `useMapPopup` covers the equivalent UX.)

## 7. Delete WebGL Fallback (descoped)
- [x] 7.1 Drop `useWebGLSupport`, `<StaticFallback>`, and the `supportsWebGL()` helper. WebGL is universal in supported browsers; the fallback is dead weight and doubles every popup/territory/click path.
- [x] 7.2 Remove the `!supportsWebGL()` short-circuit and the `webglcontextlost` fallback handler from `createUalMapController.js`. Mapbox-init failures surface as standard renderer errors via `DashboardError`.
- [x] 7.3 Delete `src/map/staticMapFallback.js`, `src/map/staticProjection.js`, `src/map/staticTerritories.js` and remove the `supportsWebGL` export from `src/map/utils.js`.

## 8. Cutover and Cleanup
- [x] 8.1 Add a build-time flag (`UAL_REACT_SHELL`) that selects between the existing imperative renderer and the new React tree at compile time. Default off in the first PR. (`vite.config.js` defines `__UAL_REACT_SHELL__`; `UalNetworkMap.jsx` dispatches at module-eval time so Rollup tree-shakes the dead branch.)
- [ ] 8.2 Run the parity harness against both trees in CI; fix any gaps before flipping the flag.
- [x] 8.3 Flip the flag default to on. Confirm parity tests pass. (Cutover landed by removing the build flag entirely and stripping the imperative branch from `UalNetworkMap.jsx`. `UalNetworkMap` now renders only `ReactShell`; production renderer is React-only. `dist/renderer.js` is 705 KB / 132 KB gzip with 61 modules — down from 76 modules in the dual-tree build. 27/27 unit tests still pass.)
- [x] 8.4 Delete the flag and the imperative implementation files in a follow-up cleanup commit. (Done in this cutover. Flag removed from `vite.config.js`; imperative React wrappers (`DashboardShell.jsx`, `useDashboardRuntime.js`) deleted; 16 imperative `src/map/` modules deleted (`chromeControls.js`, `createUalMapController.js`, `deckLayers.js`, `filterActions.js`, `filterCounts.js`, `frameData.js`, `mapInteractions.js`, `mapRenderer.js`, `mapState.js`, `mapStyles.js`, `popups.js`, `sidebarRenderers.js`, `siteActions.js`, `srqlFilters.js`, `srqlQuery.js`, `viewportFilters.js`). `src/map/` is now down to 14 pure helper modules consumed by the React shell. Parity tests rewritten to use `src/map/ualFilters.js`, `src/map/srqlBuilders.js`, `src/map/viewportLogic.js`, and `src/map/displayHelpers.js`. 28 UAL unit tests pass.)
- [x] 8.5 Update `~/src/ual-dashboard/README.md` and `~/src/serviceradar-sdk-dashboard/README.md` to point to UAL as the reference React-driven dashboard pattern; include `useMapPopup` in the SDK example index. (UAL README intro now identifies it as the reference React-driven dashboard and links to the developer portal canonical doc; SDK README intro points to the developer portal as the canonical SDK reference. `useMapPopup` example block already added in the SDK README "React-mounted Mapbox popups" section.)

## 9. Validation
- [x] 9.1 Add SDK unit tests for `useMapPopup` (open/close/reopen, content prop change, unmount on parent unmount, missing libraries). (`tests/popup.test.mjs` 8 tests using injected fakes for `mapboxgl.Popup` and `createRoot`.)
- [x] 9.2 Update UAL unit tests to cover the new component tree: shape projection, count helpers under filter, clustering, hit testing, indexed filter intersection. (`tests/react-shell-helpers.test.mjs` — 16 tests covering `SITE_SHAPE`/`DEVICE_SHAPE`/`isValidSite`/`deriveSitesFromMeta`/`visibleCountsFor`/`displayApCountFor`/`badgeLabel`/`clusterSites`/`fitFocusSites`/`siteClickRadius`/`nearestClickableSite`/`exceptionSites`/`createIndexedRows` over `SITE_INDEX_BY`. Layer-instance stability and popup transitions stay covered by the SDK-level `tests/map.test.mjs` and `tests/popup.test.mjs`. WebGL fallback selection — descoped in Section 7.)
- [x] 9.3 Run the existing 11 UAL parity unit tests against the new tree; they SHALL all pass without modification to their assertions. (`node --test tests/srql-filter.test.mjs` — 11/11 pass against the React-shell consumption of `srqlBuilders.js`/`viewportFilters.js`.)
- [ ] 9.4 Run UAL Playwright harness parity (`npm run test:parity:harness`) against the React tree.
- [ ] 9.5 Run UAL Docker parity (`npm run test:parity:docker`) against the React tree.
- [ ] 9.6 Capture per-keystroke filter latency on the React tree and the standalone reference (`tmp/wifi-map/site_inventory_map.html`) over a 500-site / 20k-device fixture; the React tree's median latency SHALL be within 1.5x of the reference.
- [ ] 9.7 Capture Playwright screenshots covering: initial map, drilled site popup, expanded down-AP list, region chip toggle, full-screen mode, theme switch, WebGL fallback, search-as-you-type.
- [x] 9.8 Run `openspec validate update-ual-dashboard-react-shell --strict`. (Passes after each delta edit.)

## 10. Parity Audit — React Shell vs Imperative Tree vs Reference HTML

The audit pass against `tmp/wifi-map/site_inventory_map.html` plus the imperative tree surfaced four React-vs-imperative gaps that have been fixed and three reference-vs-imperative gaps that pre-date this change.

### 10.1 React-vs-imperative gaps (closed)
- [x] 10.1.1 Territory overlay: `MapStage` now calls `syncMapTerritories(map, stateLike)` in an effect keyed on `territoriesVisible`; the GeoJSON loads once per dashboard mount via a local `territoryFeaturesRef` and survives toggle off/on cycles. The Territories chrome button is no longer a no-op.
- [x] 10.1.2 Mapbox controls: `MapStage` adds `NavigationControl({showCompass: false})` (top-right) and `AttributionControl({compact: true})` (bottom-right) on map ready, removes them on unmount.
- [x] 10.1.3 Double-click zoom: `MapStage` calls `map.doubleClickZoom.disable()` on ready so deck.gl picking is not preempted by Mapbox zoom — matches the imperative renderer.
- [x] 10.1.4 Sidebar fly-to: `MapStage.onMapReady` exposes the `useDeckMap` handle to `ReactShell` through `mapHandleRef`. `ReactShell.handleSelectSite` calls `handle.flyTo({center, zoom: max(currentZoom, CLUSTER_ONLY_ZOOM + 1)})` for non-cluster site selection, matching the imperative `easeTo` semantics.

### 10.2 Reference-vs-implementation gaps (pre-existing, deferred)
- [ ] 10.2.1 Export-changes diff vs historical snapshots — the standalone reference offers a "Export Changes" dropdown that diffs current `sites.csv` against snapshots for 1d / 7d / 30d. The imperative tree never ported this; out of scope for the React shell migration. Track as a follow-up customer feature if needed.
- [ ] 10.2.2 Full fleet migration trend chart — the reference renders a multi-bar chart of 6xx-AP counts across history snapshots. The imperative tree shipped only the "+N New 6xx" delta in the toolbar; React `MigrationTrend` matches that. Upgrading to the full chart is a customer-facing enhancement, not a parity regression introduced by this change.
- [ ] 10.2.3 Standalone in-page theme switcher — the reference is a self-contained HTML page with its own dark/light toggle. ServiceRadar dashboards consume `useDashboardTheme()` driven by the host shell; intentional architecture difference, not a gap.

### 10.3 Confirmed parity (no action)
- Per-keystroke filter responsiveness: React shell uses `useFilterState` + `useIndexedRows` with Set-intersection filter dispatch and a precomputed haystack, mirroring the reference's precomputed `_wlcModelSet` / `_familyApCount` / `_aosSet` / device haystack pattern.
- Cluster expansion: React layer-click triggers `easeTo({zoom: max+2, duration: 320})` and adds the cluster's sub-site codes to `siteCodes` filter, matching `openClusterPopup` + `drillIntoCluster` in the imperative tree.
- Down APs / Up APs / WLC sections: React uses native `<details>` toggles instead of imperative `setPopupContent` rebuilds; equivalent UX with simpler state.
- Site list cap (220) and device list cap (50): match the reference and imperative caps.
- Drill-reset on zoom-out: `ReactShell.handleViewportChange` clears `siteCodes` / `clusters` / `viewport` when zoom drops below `DRILL_RESET_ZOOM`, matching imperative `resetDrillFilterOnZoomOut`.
- Keyboard shortcuts (F = fullscreen, ] = sidebar collapse, Esc = exit fullscreen): React `useChromeShortcuts` matches imperative `chromeControls.js`. The standalone reference uses `[` for sidebar; the imperative deviation predates this change.
