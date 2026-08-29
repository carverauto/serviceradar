## MODIFIED Requirements

### Requirement: Reusable Time-Series Chart Range Selection
The web UI SHALL provide an opt-in, renderer-independent range-selection behavior for time-series charts. An enabled chart MUST supply one or more buckets with finite, strictly increasing rendered x-coordinates, parseable RFC3339 bounds, and `start < end` for every exact inclusive interval. The behavior MUST normalize gesture direction, snap to supplied buckets rather than interpolate timestamps, and emit only the selected `{start, end}` bounds to a chart-owned action. A qualifying pointer drag MUST commit on its first attempt without requiring a prior warm-up gesture, including when pointer-up is the first event sample beyond the drag threshold. The shared interaction lifecycle MUST preserve an active gesture across renderer-owned node replacement while the range root, action identity, and ordered bucket interval identity remain unchanged, and MUST cancel the gesture when any of those semantic identities changes.

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
- **WHEN** the pointer is cancelled, the stable lifecycle owner loses capture without a compatible transfer, Escape is pressed, or pointer movement stays below the gesture threshold
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

#### Scenario: First qualifying drag commits without a warm-up gesture
- **GIVEN** a populated range-enabled chart has mounted or rebound and no earlier gesture has occurred
- **WHEN** a valid in-plot pointer-down is followed by a pointer-move or pointer-up whose horizontal displacement crosses the gesture threshold
- **THEN** the UI SHALL highlight the resolved bucket span and emit exactly one range action on that first attempt
- **AND** pointer-up SHALL be accepted as the first qualifying sample when no qualifying pointer-move was delivered
- **AND** this behavior SHALL be identical for server-rendered SVG and client-rendered chart surfaces

#### Scenario: Compatible renderer replacement preserves an active gesture
- **GIVEN** a valid pointer-down has started a range gesture
- **WHEN** the renderer replaces its SVG, overlay, status, or geometry nodes while the range root, action identity, and ordered bucket interval identity remain unchanged
- **THEN** the interaction SHALL preserve the pointer identity, original start sample, anchor bucket, and stable pointer tracking
- **AND** subsequent samples SHALL use the current renderer geometry
- **AND** a qualifying pointer-up SHALL commit exactly one range action

#### Scenario: Active gesture can finish outside renderer-owned nodes
- **GIVEN** a range gesture began inside the current plot bounds
- **WHEN** a qualifying continuation or pointer-up occurs outside the plot or after the original renderer node was replaced
- **THEN** the interaction SHALL continue tracking that pointer on a stable lifecycle target
- **AND** SHALL project and clamp its horizontal endpoint through the current plot geometry
- **AND** SHALL commit the resolved bucket span when that endpoint is usable

#### Scenario: Changed semantic binding cancels an active gesture
- **GIVEN** a range gesture is active
- **WHEN** the range root, action identity, ordered bucket interval identity, or enabled state changes
- **THEN** the interaction SHALL cancel the stale gesture
- **AND** SHALL release capture, remove temporary tracking, and clear transient feedback
- **AND** SHALL NOT emit a range action from the stale gesture

#### Scenario: Post-drag click suppression is bounded
- **GIVEN** a committed range drag can produce a synthetic browser click
- **WHEN** that associated click is dispatched or no associated click occurs before the next independent interaction
- **THEN** the interaction SHALL suppress at most the associated click
- **AND** SHALL expire suppression before any later ordinary click
