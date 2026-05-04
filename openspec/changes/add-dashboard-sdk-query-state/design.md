# Design: Dashboard SDK Query State and Rendering Ergonomics

## Goals
- Let dashboard authors express filter state and SRQL mappings declaratively.
- Keep ServiceRadar host synchronization out of dashboard app code.
- Avoid async waterfalls and repeated host refreshes.
- Give dashboard authors stable, memoization-friendly access to frame data without each package shipping its own Arrow decoder, normalizer, or shallow-equality logic.
- Move per-keystroke filter and rendering hot paths off the dashboard package so the same precomputed-index techniques the standalone reference uses are available by default.
- Wrap deck.gl + Mapbox host injection so layer accessors and layer arrays do not churn between renders, eliminating GPU buffer rebuilds on incidental parent re-renders.
- Preserve the renderer model where dashboards can be developed independently and imported as signed/verified packages.

## Non-Goals
- Shipping a UI component library (chrome, sidebars, popups, virtualized lists). Those remain the dashboard package's responsibility for now and may be a follow-up change once these primitives are in.
- Replacing the host's SRQL execution, frame transport, or Phoenix Channel delivery. The SDK still consumes the existing host API contract.
- Polyfilling Arrow decoding for non-React or non-browser hosts. The Arrow surface is a React/browser ergonomic; framework-agnostic consumers receive the bytes and decide.

## Proposed Shape — Query State

The SDK should expose a small core helper and a React hook:

- `createDashboardQueryState(options)`
- `useDashboardQueryState(options)`

The options should include:
- `baseQuery` or `buildQuery(state)`
- `buildFrameQueries(state)`
- `serializeFilters(state)` / `hydrateFilters(query)` where needed
- `debounceMs`
- `onBeforeApply` / `onAfterApply` optional callbacks

The returned controller should expose:
- `query`
- `frameQueries`
- `apply(nextStateOrPatch, options)`
- `reset(options)`
- `flush()`
- `dirty`

### Host Contract
The helper should use `api.srql.update(query, frameQueries)` or `api.setSrqlQuery(query, frameQueries)` through the existing SDK SRQL client. It should dedupe by query plus frame override fingerprint and allow an optimistic host update path so the topbar URL/input updates immediately.

## Proposed Shape — Frame Ergonomics

The SDK should expose React hooks that present frames as stable, decoded, optionally typed views:

- `useDashboardFrame(id)` (existing) returns the raw frame envelope but SHALL bail out of state updates when the incoming frame digest matches the cached one, so consumers no longer receive a fresh array reference for every host push of identical data.
- `useFrameRows(id, options?)` returns the decoded row array. Options: `decode: 'auto' | 'arrow' | 'json'` (default `auto`), `shape?` (a row schema for projection/validation). When `decode` resolves to Arrow and the frame carries Arrow IPC bytes, the SDK SHALL decode lazily without forcing the dashboard package to import Apache Arrow itself.
- `useArrowTable(idOrFrame)` returns the Apache-Arrow `Table` for advanced consumers that want column-oriented access (e.g. zero-copy projections into deck.gl). The SDK MAY load the decoder lazily so dashboards that never opt into Arrow do not pay the bundle cost.

Stability guarantees:
- Hooks SHALL return a referentially equal value across renders when the underlying frame digest has not changed.
- `shape`-projected rows SHALL be cached per frame digest so a second `useFrameRows` call with the same shape on the same frame does not re-project.

## Proposed Shape — Indexed Local Filtering

Reference dashboards (e.g. `tmp/wifi-map/site_inventory_map.html`) achieve responsive filtering by precomputing per-row Sets and a single lowercase haystack string at data load and then applying filters as Set lookups. The SDK should provide that primitive:

- `useIndexedRows(rows, options)` where `options` includes `indexBy` (an array of field selectors or `(row) => values` projections, each producing an inverted index `value → Set<rowIdx>`) and optional `searchText` (a list of fields to merge into a single lowercase haystack per row for substring queries).
- The returned object SHALL expose `applyFilters(filters)` returning a filtered row array, with filter dispatch implemented as Set intersections rather than O(n) linear scans, and SHALL recompute indexes only when the input row reference changes.

A complementary `useFilterState({ schema })` hook SHOULD expose the typical chip/toggle/search/viewport filter state shape with stable `setFilter`/`toggle`/`clear` callbacks and an optional `debounceMs` window for the textual search input. `useDashboardQueryState` and `useFilterState` SHOULD compose so a single state object can drive both the local filter pass and the SRQL roundtrip.

## Proposed Shape — Map Runtime Primitives

Mapbox GL JS, `MapboxOverlay`, and deck.gl layer constructors are injected by the host (`api.libraries`). The SDK should wrap that injection and the lifecycle:

- `useDeckMap(options)` validates the required libraries, instantiates the Mapbox map and the `MapboxOverlay` once, attaches `moveend`/`zoomend` listeners with a configurable throttle, and returns `{ map, overlay, viewState, ready }`. Theme transitions SHALL swap basemap style without tearing down the deck overlay.
- `useDeckLayers(spec)` accepts a layer spec keyed by stable layer IDs, with `data`, `accessors`, and `visualProps` declared separately so the SDK can memoize accessor functions across renders. Layer instances SHALL be reused when the data reference, the accessor identities, and the visual props are unchanged.
- The map runtime primitives SHALL accept theme tokens via `useDashboardTheme()` and recolor layers without rebuilding GPU buffers when only token values change.

## UAL Intended Usage
UAL should use the SDK helpers for:
- sidebar filter changes
- site/cluster drill state
- reset filters
- zoom-out drill reset back to `in:wifi_sites limit:500`
- detail frame overrides for AP/WLC rows
- row-shape projection of `wifi_sites`, `wifi_aps`, `wifi_controllers` frames at the SDK boundary instead of hand-rolled `normalizeSites`/`normalizeDevices`
- precomputed indexes for region, AP family, WLC model, AOS version, RADIUS cluster, and a device search haystack
- deck.gl layer instantiation and accessor memoization for site cluster, site label, and drill-detail layers

UAL-specific code should focus on map rendering decisions (icon design, popup layout, visual tokens), site-domain interactions, and the dashboard's own visual chrome; it should not own general SRQL host synchronization mechanics, generic frame normalization, generic filter index construction, or generic deck.gl/Mapbox bootstrap.

## Risks / Trade-offs
- **Bundle size from Arrow.** Lazy-loading the Apache Arrow decoder mitigates baseline cost; dashboards that never enable Arrow stay on the JSON path. A small bundle-budget regression is expected for dashboards that do enable it; the size is bounded and amortized across all map-style dashboards rather than each one shipping its own copy.
- **Layer memoization API surface.** Declaring `data`/`accessors`/`visualProps` separately is more verbose than constructing layers inline. The trade is correctness — the inline form makes the GPU rebuild bug almost inevitable. The API should provide ergonomic helpers (e.g. `scatter({ data, position, radius, color, onClick })`) that map to the same memoization rules.
- **Coupling to deck.gl/Mapbox.** Wrapping the injected libraries in SDK hooks slightly narrows what dashboards can do directly; the SDK should still expose the raw `map` and `overlay` instances for escape hatches.
- **Scope creep on this change.** The change ID is `add-dashboard-sdk-query-state` but now covers query state, frame ergonomics, indexed filtering, and map runtime. Renaming would force a directory move with no functional benefit; we accept the slightly stretched name in exchange for a single implementation cycle.
