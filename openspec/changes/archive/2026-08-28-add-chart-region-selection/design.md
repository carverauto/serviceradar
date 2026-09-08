# Design: Reusable Chart Region Selection

## Context

The dashboard Events Over Time panel is a server-rendered SVG whose populated state is currently wrapped in a link to `/observability/events`. Its data comes from hourly database buckets, and its x positions are assigned by point index. If an hour has no events, the chart omits that bucket and visually closes the gap. A client implementation that linearly interpolates wall-clock time from the chart width would therefore produce the wrong query range.

ServiceRadar also has server-rendered Timeseries SVG charts and D3 NetFlow charts. NetFlow already has a local `d3.brushX` implementation, but that implementation owns D3 scales and the NetFlow `chart_zoom` workflow. Reusing it would couple this feature to one renderer and would not establish touch, keyboard, or LiveView lifecycle behavior for other charts.

The Events list already accepts absolute SRQL ranges through the canonical observability intent URL. The dashboard trend does not need to change data sources: it can continue using its existing hourly aggregate/raw-event query while the selected drill-down uses SRQL. The trend currently retains at most 48 occupied buckets; selection deliberately covers only the buckets actually rendered, not unrendered history outside that cap.

## Goals / Non-Goals

### Goals

- Define one small, opt-in interaction contract that works with server-rendered SVG and can be adopted by other chart renderers.
- Preserve exact chart bucket semantics, including missing time buckets and single-bucket selections.
- Provide equivalent pointer, touch, and keyboard operation with visible focus and selection feedback.
- Treat client payloads as untrusted and construct the Events query on the server.
- Use Events Over Time as the first complete consumer without coupling the shared layer to Events or SRQL.

### Non-Goals

- Replace ServiceRadar's existing chart renderers with a universal chart component.
- Rewrite the dashboard event trend to query through SRQL.
- Add range selection to sysmon, interface, NetFlow, or authored-dashboard charts in this change.
- Change SRQL absolute-range syntax or inclusive comparison semantics.
- Persist a dashboard selection in URL or server state after navigation.

## Decisions

### Decision 1: Charts supply ordered intervals, not only timestamps

An opt-in chart root will attach a `ChartRangeSelection` LiveView hook and expose:

- a unique DOM id;
- `data-range-buckets`, a JSON array ordered by rendered position with entries shaped as `{x, start, end}`;
- `data-range-event`, the LiveView event name to emit; and
- an SVG selection overlay plus accessible instruction/status elements owned by the chart markup.

`x` is expressed in the chart's SVG viewBox coordinate system. `start` and `end` are inclusive RFC3339 bounds for the represented bucket. The hook maps browser coordinates into the SVG viewBox, snaps both gesture endpoints to the nearest supplied bucket, normalizes reverse selections, and emits only `{start, end}`. It does not derive timestamps, build queries, or navigate.

A valid metadata array contains one or more buckets with finite, strictly increasing `x` values. Every `start` and `end` must parse as RFC3339, and every bucket must satisfy `start < end`. An absent, malformed, empty, unordered, or otherwise invalid array disables the selection control and cannot emit an action.

For the Events chart, each hourly bucket starts at its database bucket timestamp and ends at `bucket_start + 1 hour - 1 microsecond`, regardless of which bucket is rendered next. PostgreSQL and Elixir timestamps use microsecond precision, so this represents the complete nominal hour without including an event exactly at the next hour boundary. A one-bucket selection therefore still has a valid `start < end` interval.

This contract intentionally follows rendered bucket order. Missing hours remain missing visual intervals instead of silently stretching the selection across a wall-clock scale the chart does not render.

### Decision 2: Use Pointer Events with bucket snapping and a drag threshold

The reusable hook will use Pointer Events and pointer capture for mouse, pen, and touch. It will allow vertical page movement on touch surfaces while recognizing a horizontal selection gesture. A small CSS-pixel movement threshold distinguishes a range gesture from an incidental click or tap. Pointer cancellation, loss of capture, and Escape clear the pending overlay without emitting an event.

The selected interval is always a contiguous span of rendered bucket indexes. Drag direction does not affect the emitted order. Coordinates outside the plot clamp to the first or last selectable bucket.

### Decision 3: Provide a keyboard range model on the same surface

The chart will expose a focusable HTML range-selection control distinct from the SVG's image semantics and from the separate View all link. It will have an accessible name, reference its instructions with `aria-describedby`, and report the highlighted interval through a polite live status.

On first focus, the active index is the latest rendered bucket with no extended range. An unmodified Left or Right Arrow moves the active index by one and collapses any pending range to that bucket. Shift plus Left or Right Arrow anchors at the pre-move active index when no anchor exists, then moves the active endpoint; further Shift movements extend or contract the range, including across the anchor. Enter commits the inclusive span between anchor and active, or the active bucket alone when no anchor exists. Escape clears the anchor and transient highlight while retaining focus and the active index. The hook prevents default browser behavior for handled Arrow, Enter, and Escape keys.

The keyboard path uses the same bucket-index selection helper and emits the same payload as Pointer Events. A chart without valid bucket metadata does not expose an active selection control.

### Decision 4: The LiveView owns validation, query construction, and navigation

The Events chart configures a dashboard-specific event name. The dashboard LiveView parses both payload values as ISO 8601 timestamps, requires an ordered non-empty interval, and requires `start` and `end` to match the boundaries of a contiguous span in the currently rendered Events bucket metadata. It ignores malformed, equal, reversed, stale, out-of-window, or otherwise non-rendered input. Reverse gestures are normalized by the hook before emission; the server does not normalize a reversed untrusted payload. It never accepts query fragments or destination URLs from the browser.

For a valid selection, the server constructs this fixed query shape:

```text
in:events time:[<start>,<end>] sort:time:desc limit:20
```

It then uses `ObservabilityPaths.path("events", %{q: query})` and `push_navigate/2` to reach the canonical `/observability/events` route. Because the query is explicit, the result does not depend on the Events page's default time window or sorting behavior.

### Decision 5: Range selection and whole-list navigation are separate actions

The chart will no longer be nested inside a whole-surface link because link activation conflicts with drag and keyboard range input. A conventional "View all events" link remains available next to the chart guidance and is added to the empty state. This retains the dashboard drill-down action while giving the chart surface one unambiguous interaction role.

The active `update-dashboard-drilldown-actions` change broadly describes rich dashboard panels as clickable. Before either change is archived, that requirement must be clarified so a range-enabled panel satisfies generic drill-down through its separate View all action while the chart surface remains dedicated to range selection.

### Decision 6: Keep the hook live across LiveView patches

The hook reads bucket metadata and reacquires its rendered overlay/status elements in both `mounted()` and `updated()`. It may change only transient attributes, text, and styles on server-rendered overlay/status nodes; it does not append persistent SVG or DOM nodes. On metadata change it clears transient visual/keyboard state before using the new buckets. It removes listeners, pointer state, and transient selection state in `destroyed()`. The chart subtree remains LiveView-owned; the design does not use `phx-update="ignore"`, so refreshed dashboard data and theme markup continue to patch normally.

## Alternatives Considered

### Extend the existing D3 brush

Rejected because it depends on a D3 time scale, is embedded in the NetFlow renderer, and does not supply the accessibility or lifecycle contract needed by the Events SVG and shared Timeseries charts.

### Convert Events Over Time to D3 first

Rejected because renderer replacement is unnecessary for bucket selection and would enlarge the change without improving the operator outcome.

### Implement Events, sysmon, and interface selection together

Rejected for this change. Sysmon already accepts absolute SRQL windows, while interface charts currently hard-code their query window and bucket. Each needs a separate page-state and reload decision. The shared event contract is the reusable seam; those consumer decisions can be reviewed independently.

### Interpolate timestamps from plot width

Rejected because the Events chart spaces occupied buckets by index. Interpolation would return incorrect boundaries whenever hours are absent.

## Risks / Trade-offs

- **Gesture conflicts with page scrolling or fallback navigation.** Use horizontal Pointer Events, `touch-action: pan-y`, a movement threshold, and a separate View all link.
- **Client metadata can be modified.** Match submitted bounds against the currently rendered server-side bucket metadata, accept no query fragments, and build the fixed query on the server.
- **Inclusive SRQL end bounds can include the next bucket.** Supply an inclusive bucket end one microsecond before the next hour rather than sending an end-exclusive boundary to an inclusive query.
- **LiveView can replace hook-owned nodes during async refreshes.** Re-read metadata and DOM references in `updated()`, reset transient state, and keep all persistent markup server-owned.
- **A shared hook could become a universal chart abstraction.** Keep its public contract limited to ordered bucket geometry and one emitted event.

## Migration Plan

1. Add the pure range-selection helper and hook with focused Vitest coverage.
2. Add server-side Events range validation and canonical intent-path coverage.
3. Opt the Events Over Time chart into the hook and add component/LiveView coverage.
4. Verify pointer, touch, keyboard, empty-state, and theme behavior before running the repository test and lint gates.

Rollback removes the Events opt-in markup and restores the separate dashboard link behavior. No stored data, schema, query grammar, or external API requires migration.

## Open Questions

None. Additional chart families will make their own navigation or reload behavior explicit when they adopt the shared selection contract.
