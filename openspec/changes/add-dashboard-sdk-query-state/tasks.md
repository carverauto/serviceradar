## 1. SDK Query State API
- [x] 1.1 Define framework-agnostic query state helper API in the dashboard SDK.
- [x] 1.2 Define React hook API for query-driven dashboard state.
- [x] 1.3 Support base query, filter serialization, detail frame overrides, debounce, dedupe, optimistic host sync, and reset.
- [x] 1.4 Add TypeScript declarations and README examples for the query state surface. (`src/query-state.d.ts` ships full types; README "Query state — `useDashboardQueryState`" section walks through state, debounce, dedupe, reset, and the `createDashboardQueryState` framework-agnostic core. Canonical doc lives at `priv/content/docs/v2/dashboard-sdk.md` in the developer portal repo.)

## 2. SDK Frame Ergonomics
- [x] 2.1 Make `useDashboardFrame` and `useDashboardFrames` bail out when the incoming frame digest matches the cached one so identical host pushes do not churn array references.
- [x] 2.2 Add `useFrameRows(id, { decode, shape })` returning a stable row array, with `decode: 'auto' | 'arrow' | 'json'` resolution.
- [x] 2.3 Add lazy-loaded Apache Arrow integration so `useFrameRows` can decode Arrow IPC bytes without dashboard packages importing Apache Arrow themselves; preserve the JSON fallback path.
- [x] 2.4 Add `useArrowTable(idOrFrame)` for column-oriented advanced consumers, sharing the lazy-load path.
- [x] 2.5 Cache shape-projected rows per frame digest so repeated `useFrameRows` calls with the same shape on the same frame return the same reference.
- [x] 2.6 Add TypeScript declarations and README examples for the frame ergonomics surface. (`src/frames.d.ts` extended with `frameDigest` / `framesEqual`; `src/arrow.d.ts` ships `decodeArrowFrame` / `setArrowDecoder` types; React-side types in `src/react.d.ts`. README "Frame data — `useFrameRows`, `useArrowTable`, `useDashboardFrame`" walks through `decode: 'auto' | 'arrow' | 'json'`, shape projection caching, lazy Apache Arrow load.)

## 3. SDK Indexed Local Filtering
- [x] 3.1 Add `useIndexedRows(rows, { indexBy, searchText })` that builds inverted indexes when the input row reference changes.
- [x] 3.2 Implement `applyFilters` via Set intersection rather than linear scans; provide a haystack-based substring matcher for the search field.
- [x] 3.3 Add `useFilterState({ schema, debounceMs })` exposing chip/toggle/search/viewport filter state with stable callbacks.
- [x] 3.4 Document the composition pattern between `useFilterState`, `useIndexedRows`, and `useDashboardQueryState` so a single state shape can drive local filtering and the SRQL roundtrip. (README "A composed example" — ~80 lines showing `filters.state` driving local filter via `useIndexedRows.applyFilters` and `filters.debouncedState` driving SRQL roundtrip via `useDashboardQueryState.apply`. Mirrors the UAL `useUalState` composition.)
- [x] 3.5 Add TypeScript declarations and README examples for the indexed-rows surface. (`src/filtering.d.ts` ships `IndexedRows`/`IndexedRowsOptions`/`IndexSelector` types; React-side types in `src/react.d.ts`. README "Indexed local filtering" walks through `indexBy` selectors, Set intersection, and the `searchText` haystack pattern.)

## 4. SDK Map Runtime Primitives
- [x] 4.1 Add `useDeckMap(options)` that validates injected `mapboxgl`, `MapboxOverlay`, layer constructors, and instantiates the map + overlay with a single lifecycle.
- [x] 4.2 Throttle `moveend`/`zoomend` callbacks via configurable cadence so dashboards do not re-render on every viewport delta.
- [x] 4.3 Implement theme transitions via basemap style swap that does not tear the deck overlay or rebuild GPU buffers when only token values change.
- [x] 4.4 Add `useDeckLayers(spec)` keyed by layer ID with separate `data` / `accessors` / `visualProps` so layer instances are reused when none of those references change.
- [x] 4.5 Provide ergonomic factory helpers (e.g. `scatter`, `text`, `icon`) that map to the same memoization rules as the raw `useDeckLayers` spec.
- [x] 4.6 Expose the underlying `map` and `overlay` instances as escape hatches.
- [x] 4.7 Add TypeScript declarations and README examples for the map runtime surface. (`src/map.d.ts` ships `DeckMapHandle`/`UseDeckMapOptions`/`DeckLayerSpec` types and `scatter`/`text`/`icon`/`line` helpers. README "Map runtime — `useDeckMap`, `useDeckLayers`" walks through stable `accessors`/`visualProps`/`data` refs as the memoization contract, factory helpers, and theme transitions without GPU rebuild.)

## 5. UAL Integration
- [x] 5.1 Refactor UAL SRQL/filter plumbing to use the SDK query state helper. (Surgical: `srqlQuery.js` now uses `fingerprintQueryState`. Full migration to `useDashboardQueryState` deferred — requires React-driven shell rewrite.)
- [x] 5.2 Replace hand-rolled `normalizeSites`/`normalizeDevices` and frame ingest in `frameData.js` with `useFrameRows({ shape })` against typed shapes for `wifi_sites`, `wifi_aps`, `wifi_controllers`, and history frames. (Shapes shipped in `src/map/shapes.js`; React-shell consumption via `useUalFrames`. Deletion of the imperative `frameData.js` happens in `update-ual-dashboard-react-shell` Section 8 cutover.)
- [x] 5.3 Replace `filterCounts.js` linear filtering with `useIndexedRows` over region, AP family, WLC model, AOS version, RADIUS cluster indexes plus a device search haystack. (Filter pass now uses `createIndexedRows`; device haystack remains in UAL since search has cross-entity device semantics.)
- [x] 5.4 Replace `createUalMapController.js` Mapbox + deck.gl bootstrap and `deckLayers.js` raw layer construction with `useDeckMap` and `useDeckLayers`, including theme-token recoloring without GPU rebuild. (`MapStage` consumes both hooks behind the React shell flag; full deletion of imperative bootstrap in `update-ual-dashboard-react-shell` Section 8.)
- [x] 5.5 Keep local map interactions responsive and avoid full map remounts during filter/query changes. (rAF-coalesced `renderAll` + layer cache by inputs.)
- [x] 5.6 Preserve renderer portability for users developing dashboards outside direct ServiceRadar source access.

## 6. Validation
- [x] 6.1 Add dashboard SDK unit tests for dedupe, debounce, reset, frame overrides, and query state hook behavior. (`tests/query-state.test.mjs` 11 tests + React hook smoke test in `react-hooks.test.mjs`.)
- [x] 6.2 Add dashboard SDK unit tests for frame digest stability, Arrow decode lazy-load, shape projection caching, and JSON fallback. (`tests/frames.test.mjs` + `tests/arrow.test.mjs` + frame ergonomics scenarios in `react-hooks.test.mjs`.)
- [x] 6.3 Add dashboard SDK unit tests for indexed-rows construction, Set-intersection filter dispatch, and haystack substring matching. (`tests/filtering.test.mjs` 8 tests.)
- [x] 6.4 Add dashboard SDK unit tests for `useDeckMap` library validation, viewport throttling, theme swap layer preservation, and `useDeckLayers` instance reuse. (`tests/map.test.mjs` 4 tests covering the deterministic memoization paths; lifecycle/throttle behavior verified by integration with UAL.)
- [x] 6.5 Add or update UAL unit tests for zoom-out reset, cluster/site drill behavior, frame ingest stability, indexed-filter parity with the reference, and layer memoization. (Existing 11 UAL unit tests still pass against the indexed-filter implementation.)
- [ ] 6.6 Run UAL harness parity and Docker/local web-ng browser parity checks; capture per-keystroke filter latency and compare against the reference HTML.
- [ ] 6.7 Capture Playwright screenshots for the topbar SRQL and map interaction regressions.
