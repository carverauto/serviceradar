## ADDED Requirements

### Requirement: Reusable Time-Series Chart Range Selection
The web UI SHALL provide an opt-in, renderer-independent range-selection behavior for time-series charts. An enabled chart MUST supply one or more buckets with finite, strictly increasing rendered x-coordinates, parseable RFC3339 bounds, and `start < end` for every exact inclusive interval. The behavior MUST normalize gesture direction, snap to supplied buckets rather than interpolate timestamps, and emit only the selected `{start, end}` bounds to a chart-owned action.

#### Scenario: Pointer gesture selects rendered buckets
- **GIVEN** a time-series chart opts into range selection with one or more valid bucket intervals
- **WHEN** an operator drags horizontally with a mouse, pen, or touch pointer across one or more rendered buckets
- **THEN** the UI SHALL visibly highlight the contiguous selected bucket indexes
- **AND** SHALL emit the earliest selected bucket start and latest selected bucket inclusive end as ordered RFC3339 values
- **AND** SHALL produce the same bounds when the operator drags in the reverse direction

#### Scenario: Missing time buckets are not interpolated
- **GIVEN** adjacent rendered points represent non-adjacent wall-clock buckets
- **WHEN** an operator selects between those rendered points
- **THEN** the range endpoints SHALL come from the chart-supplied bucket metadata
- **AND** the client SHALL NOT derive either endpoint by linearly interpolating wall-clock time from plot width

#### Scenario: One rendered bucket forms a valid range
- **GIVEN** a chart has one valid bucket interval or a gesture resolves to one rendered bucket
- **WHEN** the operator commits that selection
- **THEN** the UI SHALL emit that bucket's supplied start and inclusive end bounds

#### Scenario: Keyboard operator selects a range
- **GIVEN** an enabled range-selection surface has keyboard focus
- **WHEN** an operator moves between buckets with Left or Right Arrow, extends a range with Shift plus Left or Right Arrow, and commits with Enter
- **THEN** the UI SHALL expose visible focus and selection feedback
- **AND** SHALL emit the same ordered bounds as the equivalent pointer gesture
- **AND** accessible instructions and status text SHALL describe the active interval and controls

#### Scenario: Selection is cancelled or too small
- **GIVEN** an operator has started a pointer or keyboard selection
- **WHEN** the pointer is cancelled, capture is lost, Escape is pressed, or pointer movement stays below the gesture threshold
- **THEN** the UI SHALL clear transient selection feedback
- **AND** SHALL NOT emit a range action

#### Scenario: Bucket metadata is not selectable
- **GIVEN** a chart supplies absent, malformed, empty, non-finite, unordered, or invalid-interval bucket metadata
- **WHEN** the chart renders or receives that metadata through a LiveView patch
- **THEN** its range-selection surface SHALL NOT become focusable or selectable
- **AND** SHALL NOT emit a range action

#### Scenario: LiveView refreshes an enabled chart
- **GIVEN** a range-enabled chart receives new bucket metadata through a LiveView patch
- **WHEN** the hook update completes
- **THEN** subsequent selection SHALL use the new rendered buckets
- **AND** hook teardown SHALL remove listeners and transient pointer state

### Requirement: Events Over Time Range Drill-Down
The `/dashboard` Events Over Time chart SHALL use reusable range selection to open the canonical Events observability surface for the selected hourly buckets. The server MUST validate the client-supplied timestamps against the currently rendered Events bucket boundaries and MUST construct the SRQL query rather than accepting a query fragment or destination from the client.

#### Scenario: Selected event buckets open an explicit SRQL range
- **GIVEN** the Events Over Time chart contains one or more hourly buckets
- **WHEN** an operator commits a valid range selection
- **THEN** the dashboard SHALL navigate to `/observability/events` with an encoded `q` value shaped as `in:events time:[<start>,<end>] sort:time:desc limit:20`
- **AND** `<start>` SHALL equal the earliest selected bucket start
- **AND** `<end>` SHALL equal the latest selected bucket inclusive end
- **AND** the Events page SHALL use that explicit range instead of its default time window

#### Scenario: Final hourly bucket does not include the next hour
- **GIVEN** the final selected event bucket begins at an exact hour boundary
- **WHEN** the dashboard constructs the selected range
- **THEN** the inclusive end SHALL represent the final microsecond of that hour
- **AND** an event at the following hour boundary SHALL NOT be included by the selected range

#### Scenario: Malformed event range is rejected
- **GIVEN** the dashboard receives missing, malformed, equal, reversed, stale, out-of-window, or well-formed but non-rendered timestamp bounds from the client
- **WHEN** it handles the range-selection event
- **THEN** it SHALL NOT navigate
- **AND** it SHALL NOT incorporate client-supplied query fragments or destinations

#### Scenario: Operator opens all Events without selecting a range
- **GIVEN** the Events Over Time panel is populated or empty
- **WHEN** the operator activates the separate View all events action
- **THEN** the dashboard SHALL navigate to `/observability/events`
- **AND** the action SHALL remain keyboard accessible without competing with the chart selection gesture
