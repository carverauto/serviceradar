## ADDED Requirements

### Requirement: Dashboard SDK query state helper
The dashboard SDK SHALL provide a helper API that lets custom dashboard packages build, apply, debounce, dedupe, and reset SRQL query state with optional per-frame query overrides.

#### Scenario: Apply query state with frame overrides
- **GIVEN** a dashboard package has local filter state for a WiFi site drill
- **WHEN** it applies the state through the SDK query state helper
- **THEN** the helper SHALL call the host SRQL update API with the site query
- **AND** it SHALL include configured AP and controller frame override queries
- **AND** the dashboard package SHALL NOT need to call raw host SRQL APIs directly

#### Scenario: Dedupe repeated query state
- **GIVEN** a dashboard package applies the same query and frame overrides repeatedly
- **WHEN** the SDK query state helper computes the same fingerprint
- **THEN** it SHALL suppress duplicate host updates
- **AND** it SHALL avoid unnecessary dashboard frame reloads

#### Scenario: Debounce rapid query state changes
- **GIVEN** a user rapidly toggles filters or map controls
- **WHEN** the dashboard applies debounced query state updates
- **THEN** the SDK query state helper SHALL emit only the final query state after the debounce interval
- **AND** local UI rendering SHALL remain independent of the debounced host update

### Requirement: React dashboard query state hook
The dashboard SDK SHALL provide an idiomatic React hook for query-driven dashboard packages that integrates with the existing dashboard provider and SRQL client.

#### Scenario: React dashboard uses query state hook
- **GIVEN** a React dashboard package is mounted with `mountReactDashboard`
- **WHEN** a component calls the query state hook
- **THEN** the hook SHALL use the dashboard provider's host API context
- **AND** it SHALL return stable apply, reset, and flush functions suitable for React event handlers and effects

#### Scenario: Reset restores the base dashboard query
- **GIVEN** a React dashboard package has drilled into a subset of map data
- **WHEN** the package calls the hook's reset function
- **THEN** the hook SHALL restore the configured base query
- **AND** it SHALL clear configured frame overrides
- **AND** the ServiceRadar topbar query state SHALL reflect the reset without requiring a full map remount

### Requirement: Stable frame references across identical host pushes
The dashboard SDK SHALL return referentially equal frame and frame-row values across renders when the underlying frame digest has not changed, so dashboard packages do not invalidate downstream `useMemo` or `useCallback` dependencies on every host push of identical data.

#### Scenario: Identical host push is suppressed
- **GIVEN** a dashboard package consumes a frame through the SDK frame hooks
- **WHEN** the host pushes a frame whose digest matches the previously cached frame
- **THEN** the hook SHALL return the same reference it returned on the previous render
- **AND** components depending on that reference SHALL NOT re-render solely due to the host push

#### Scenario: Real frame change still propagates
- **GIVEN** a dashboard package consumes a frame through the SDK frame hooks
- **WHEN** the host pushes a frame whose digest differs from the cached frame
- **THEN** the hook SHALL return a new reference
- **AND** consumers SHALL observe the new rows

### Requirement: Frame row decoding with Arrow and JSON
The dashboard SDK SHALL provide a hook that returns decoded frame rows and accepts an explicit `decode` mode covering Arrow IPC, JSON rows, and an automatic mode that selects based on the frame's encoding metadata, so dashboard packages do not have to import Apache Arrow or branch on frame encoding themselves.

#### Scenario: Arrow IPC frame is decoded by the SDK
- **GIVEN** a frame is delivered with Arrow IPC bytes
- **AND** a component requests rows with `decode: 'auto'` or `decode: 'arrow'`
- **WHEN** the hook resolves
- **THEN** the SDK SHALL decode the Arrow payload and return the decoded row array
- **AND** the dashboard package SHALL NOT need to import or bundle an Arrow decoder itself

#### Scenario: JSON-only frame falls back without decoding
- **GIVEN** a frame is delivered as JSON rows
- **WHEN** a component requests rows with `decode: 'auto'`
- **THEN** the hook SHALL return the JSON rows directly without invoking the Arrow decoder
- **AND** the Arrow decoder SHALL NOT be loaded if no consumer requested Arrow

#### Scenario: Lazy Arrow decoder load
- **GIVEN** a dashboard package never opts into Arrow decoding for any frame
- **WHEN** the package is loaded
- **THEN** the SDK SHALL NOT include the Apache Arrow decoder in the synchronously loaded bundle

### Requirement: Frame row shape projection
The dashboard SDK SHALL allow consumers to declare a row shape that is validated and projected at the SDK boundary, with projected rows cached by frame digest plus shape identity so repeated calls return the same reference.

#### Scenario: Typed row projection
- **GIVEN** a dashboard package declares a row shape mapping frame columns to typed fields
- **WHEN** a component calls the row hook with that shape
- **THEN** the SDK SHALL return rows projected to the declared shape
- **AND** projection results SHALL be cached so a second call with the same frame digest and shape returns the same reference

### Requirement: Indexed local filtering
The dashboard SDK SHALL provide a helper that builds inverted indexes over a row array based on a declared `indexBy` configuration and applies filter sets through Set intersection rather than linear scans, so dashboard packages can filter large row arrays per keystroke without re-scanning the full data set on every render.

#### Scenario: Indexes rebuild only when row reference changes
- **GIVEN** a dashboard package passes a stable row array to the indexed-rows helper
- **WHEN** the parent component re-renders without changing the row reference
- **THEN** the SDK SHALL reuse the previously built indexes
- **AND** it SHALL NOT iterate the row array again

#### Scenario: Filter dispatch uses Set intersection
- **GIVEN** an indexed-rows helper is configured with multiple `indexBy` selectors
- **WHEN** a dashboard package applies multiple active filters at once
- **THEN** the helper SHALL compute the result as the intersection of the relevant index sets
- **AND** it SHALL NOT scan the unmatched rows linearly

#### Scenario: Search text uses precomputed haystack
- **GIVEN** an indexed-rows helper is configured with a `searchText` field list
- **WHEN** a dashboard package applies a substring search
- **THEN** the helper SHALL match against a precomputed lowercase haystack stored per row
- **AND** it SHALL NOT recompute the haystack on every keystroke

### Requirement: Filter state hook
The dashboard SDK SHALL provide a React hook for chip/toggle/search/viewport filter state that returns stable mutator callbacks and supports a debounce window for textual search, so dashboard packages do not hand-roll filter state machines and event-handler memoization.

#### Scenario: Stable mutators across renders
- **GIVEN** a component consumes the filter-state hook
- **WHEN** the component re-renders without filter changes
- **THEN** the returned `setFilter`, `toggle`, and `clear` callbacks SHALL be referentially equal across renders

#### Scenario: Debounced search field
- **GIVEN** the filter-state hook is configured with a `debounceMs` window for the search field
- **WHEN** a user types rapidly
- **THEN** the hook SHALL update the immediate search value on every keystroke
- **AND** it SHALL emit a debounced search value only after the configured window
- **AND** the debounced value SHALL be the one suitable for driving the SRQL roundtrip

### Requirement: Map runtime primitives
The dashboard SDK SHALL provide React hooks that wrap host-injected Mapbox GL JS, `MapboxOverlay`, and deck.gl layer constructors so dashboard packages do not duplicate library validation, lifecycle wiring, or viewport throttling, and do not have to choose between in-line layer construction and manual memoization.

#### Scenario: Library validation
- **GIVEN** a dashboard package mounts a `useDeckMap` hook
- **WHEN** any of the required host libraries are missing from `api.libraries`
- **THEN** the hook SHALL surface a clear error identifying the missing libraries
- **AND** it SHALL NOT silently fail to construct the map

#### Scenario: Throttled viewport callbacks
- **GIVEN** a `useDeckMap` hook is configured with a viewport throttle cadence
- **WHEN** the user pans or zooms continuously
- **THEN** the hook SHALL invoke the viewport callback no more often than the configured cadence
- **AND** the final viewport state after the gesture SHALL still be delivered

#### Scenario: Theme swap preserves deck overlay
- **GIVEN** a dashboard map is mounted via `useDeckMap`
- **WHEN** the dashboard theme changes and a new basemap style is applied
- **THEN** the deck.gl overlay SHALL remain attached
- **AND** layers whose data and accessors have not changed SHALL NOT have their GPU buffers rebuilt

### Requirement: Memoized deck.gl layer factory
The dashboard SDK SHALL provide a `useDeckLayers` hook that accepts a layer specification keyed by stable layer IDs, with `data`, `accessors`, and `visualProps` declared separately, and SHALL reuse the underlying layer instance when none of those reference identities change.

#### Scenario: Layer instance is reused on incidental re-render
- **GIVEN** a dashboard component declares a layer spec with stable `data`, `accessors`, and `visualProps` references
- **WHEN** the parent component re-renders for an unrelated reason
- **THEN** `useDeckLayers` SHALL return the previously constructed layer instance
- **AND** the deck.gl overlay SHALL NOT rebuild GPU buffers for that layer

#### Scenario: Layer rebuilds only when data or props change
- **GIVEN** a dashboard component declares a layer spec
- **WHEN** the `data` reference changes or any value in `visualProps` changes
- **THEN** `useDeckLayers` SHALL produce a new layer instance reflecting the change
- **AND** unrelated layers in the same spec SHALL retain their previous instances

### Requirement: Dashboard developer ergonomics documentation
The dashboard SDK SHALL document the preferred query-state, frame, indexed-filtering, and map runtime integration patterns for custom dashboard developers.

#### Scenario: Developer implements a custom map dashboard
- **GIVEN** a developer is building a dashboard outside the ServiceRadar source tree
- **WHEN** they read the SDK documentation
- **THEN** they SHALL find a concise React example showing filters, query building, frame overrides, reset, and host synchronization
- **AND** they SHALL find a concise React example showing typed frame row consumption with both Arrow and JSON frames
- **AND** they SHALL find a concise React example showing indexed local filtering with a `searchText` haystack
- **AND** they SHALL find a concise React example showing `useDeckMap` and `useDeckLayers` driving a clustered site map without hand-rolled Mapbox or deck.gl bootstrap
- **AND** the examples SHALL avoid direct LiveView, Phoenix hook, or internal ServiceRadar module usage
