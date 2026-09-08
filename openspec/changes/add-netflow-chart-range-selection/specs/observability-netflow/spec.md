## ADDED Requirements

### Requirement: NetFlow Time-Series Chart Range Selection
The NetFlow observability page SHALL provide reusable time-range selection on Traffic Over Time in Lines, Grid, Stacked, and 100% modes and on Activity by Protocol and Activity by Application. A committed selection MUST leave exactly one SRQL `time:` clause, preserve all non-time SRQL filters plus the effective limit, compact, talker-CIDR, comparison, geography side, Sankey-prefix, stack, and graph options, patch the same `/observability/netflows` route with `view=explorer`, and load Flow Explorer for the selected interval. The server MUST accept a range only while the current view and graph mode render a supported temporal selector and the ordered bounds exactly match a contiguous span of the currently rendered canonical NetFlow buckets.

#### Scenario: Operator selects Traffic Over Time in any temporal mode
- **GIVEN** Traffic Over Time is populated in Lines, Grid, Stacked, or 100% mode
- **WHEN** an operator commits a pointer, touch, or keyboard range selection
- **THEN** the page SHALL patch its SRQL query with `time:[<start>,<end>]`
- **AND** `<start>` and `<end>` SHALL be the exact inclusive bounds of the selected rendered buckets
- **AND** Flow Explorer SHALL render results for that interval

#### Scenario: Operator selects protocol or application activity
- **GIVEN** Activity by Protocol or Activity by Application is populated
- **WHEN** an operator commits a range selection on that chart
- **THEN** the page SHALL navigate to Flow Explorer with the selected interval
- **AND** SHALL preserve the current graph, stack, comparison, geography, talker, limit, and other non-time query options

#### Scenario: Selection preserves filters and navigates to Flow Explorer
- **GIVEN** the NetFlow query contains a `time:` clause and additional SRQL filters and the page has active view options
- **WHEN** an operator commits a valid range selection
- **THEN** the resulting query SHALL contain exactly one `time:[<start>,<end>]` clause for the selected bounds
- **AND** every non-time SRQL filter SHALL remain unchanged
- **AND** the active view SHALL be `explorer`
- **AND** graph, stack, comparison, compact, talker-CIDR, geography side, Sankey-prefix, and limit options SHALL remain unchanged

#### Scenario: Selection preserves a legacy URL limit
- **GIVEN** the NetFlow URL supplies a valid `limit=<N>` and the SRQL query has no `limit:` token
- **WHEN** an operator commits a valid range selection
- **THEN** the patched URL SHALL retain `limit=<N>`
- **AND** the effective result limit SHALL remain `<N>`

#### Scenario: Selection preserves the preferred SRQL limit
- **GIVEN** the NetFlow SRQL query contains `limit:<M>`
- **WHEN** an operator commits a valid range selection
- **THEN** the query SHALL retain `limit:<M>` unchanged
- **AND** the effective result limit SHALL remain `<M>` even if the incoming URL also contained a legacy `limit=` value

#### Scenario: Plain chart click retains its existing action
- **GIVEN** a range-enabled NetFlow chart is populated
- **WHEN** an operator clicks or taps without crossing the range gesture threshold
- **THEN** Lines and Grid SHALL retain their one-bucket time drill-down
- **AND** Activity by Protocol and Activity by Application SHALL retain their existing series-filter action
- **AND** the UI SHALL NOT emit a range action
- **AND** the current view SHALL remain unchanged

#### Scenario: Completed drag does not activate a click action
- **GIVEN** a NetFlow chart has both range selection and an existing click action
- **WHEN** an operator completes a qualifying drag
- **THEN** the UI SHALL emit exactly one range action
- **AND** SHALL suppress only the synthetic click associated with that completed drag
- **AND** a later ordinary click SHALL remain available

#### Scenario: Final selected bucket excludes the next boundary
- **GIVEN** the final selected bucket has an exclusive end at an exact bucket boundary
- **WHEN** the page constructs the inclusive SRQL interval
- **THEN** `<end>` SHALL be one microsecond before that boundary
- **AND** a flow at the next bucket boundary SHALL NOT be included
- **AND** the same boundary rule SHALL apply to the existing one-bucket drill-down

#### Scenario: Invalid or stale NetFlow range is rejected
- **GIVEN** the server receives missing, malformed, equal, reversed, stale, out-of-window, or well-formed but non-rendered bounds, or the current view and graph mode do not render a supported temporal selector
- **WHEN** it handles the range event
- **THEN** it SHALL NOT patch or navigate
- **AND** a payload containing any key besides `start` and `end` SHALL be rejected wholesale
- **AND** it SHALL NOT accept a client-supplied query fragment, filter field, source card, or destination

#### Scenario: Hidden or empty chart data cannot authorize a range
- **GIVEN** canonical Traffic Over Time buckets exist in server state but the current Lines/Grid, Stacked/100%, Protocol, and Application render guards expose no populated selector
- **WHEN** the server receives otherwise valid canonical bounds
- **THEN** it SHALL NOT patch or navigate
- **AND** hidden base data SHALL NOT be treated as evidence of a rendered selection surface

#### Scenario: Renderer redraws during the first drag
- **GIVEN** an operator has pointer capture on a populated range-enabled NetFlow chart
- **WHEN** a renderer redraw replaces SVG or overlay nodes but leaves the range-root identity, event name, and canonical interval identity unchanged
- **THEN** the active gesture SHALL remain usable
- **AND** a qualifying pointer-up SHALL commit the intended range on the first attempt

#### Scenario: A changed range binding cancels an active gesture
- **GIVEN** an operator has pointer capture on a populated range-enabled NetFlow chart
- **WHEN** the range-root identity, event name, or canonical interval identity changes
- **THEN** the active gesture SHALL be cancelled
- **AND** the stale gesture SHALL NOT emit a range action

#### Scenario: Keyboard operator selects a NetFlow interval
- **GIVEN** a populated range-enabled NetFlow chart has keyboard focus
- **WHEN** the operator moves or extends the active bucket with Arrow keys and commits with Enter
- **THEN** visible selection and polite status feedback SHALL identify the active interval
- **AND** the chart SHALL emit the same bounds as the equivalent pointer gesture

#### Scenario: Non-temporal NetFlow views do not expose range selection
- **GIVEN** the operator views Sankey or another non-time-series NetFlow visualization
- **WHEN** that visualization renders
- **THEN** it SHALL retain its existing interaction model
- **AND** it SHALL NOT expose the time-series range-selection control
