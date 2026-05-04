# Change: Add dashboard SDK query state and rendering ergonomics

## Why
Custom dashboard authors currently have to hand-roll SRQL state synchronization, frame query overrides, reset semantics, dedupe, debouncing, and host topbar/URL updates. The UAL WiFi map integration shows that this plumbing is too easy to get wrong and makes otherwise straightforward React map/dashboard code look contrived.

A parity audit of the UAL WiFi map against the standalone reference at `tmp/wifi-map/site_inventory_map.html` further showed that the same plumbing burden extends well beyond SRQL. Dashboard authors are also rebuilding generic frame normalization and Arrow decoding, per-keystroke local filter passes against unindexed row arrays, and deck.gl/Mapbox bootstrap with manual layer memoization. Each of these surfaces a perf cliff (GPU buffer rebuild on every render, full O(n×m) filter scans, frame-array reference churn that invalidates downstream `useMemo`) that a customer writing their first dashboard will hit without any signal that the SDK should have absorbed the work. The SDK needs primitives at the same level of abstraction as the host APIs it already proxies.

## What Changes
- Add a React-friendly dashboard SDK primitive for query-driven dashboard state.
- Provide a small framework-agnostic helper for building, deduping, debouncing, resetting, and applying SRQL query updates with optional per-frame overrides.
- Add a frame ergonomics surface so dashboard packages receive stable row references between identical host pushes, can request Arrow IPC decode without shipping their own Apache Arrow integration, and can declare a row shape that is validated and projected at the SDK boundary.
- Add an indexed-rows helper that builds inverted indexes once per data refresh so filter application becomes Set-intersection against precomputed indexes rather than O(n×m) linear scans on every render.
- Add map runtime primitives that wrap Mapbox + deck.gl host injection, validate the required libraries, own the lifecycle, and return memoized layer factories so accessor functions and layer instances do not churn on every parent render.
- Document the intended integration pattern so custom dashboard packages can preserve renderer portability while using ServiceRadar host capabilities naturally.
- Update UAL dashboard integration to consume the helpers after approval; the consumption refactor should retire the equivalent plumbing in `ual-dashboard/src/map/` rather than ship in parallel.

## Impact
- Affected specs: dashboard-sdk
- Affected code: `/home/mfreeman/src/serviceradar-sdk-dashboard/src/*`, UAL dashboard package React/map code (notably `frameData.js`, `mapState.js`, `filterCounts.js`, `createUalMapController.js`, `deckLayers.js`, `srqlQuery.js`), dashboard SDK README/tests
- Follow-up validation: SDK unit tests, UAL unit/parity tests, Docker/local web-ng Playwright checks
