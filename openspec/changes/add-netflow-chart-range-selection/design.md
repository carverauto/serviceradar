# Design: NetFlow Chart Range Selection

## Context

`/observability/netflows` is rendered by `LogLive.Index`. Its Traffic Over Time card has two renderer families: Lines and Grid use a server-rendered SVG with the `NetflowTrafficTooltip` hook, while Stacked and 100% use the D3-owned `NetflowStackedAreaChart` hook. Activity by Protocol and Activity by Application use that same D3 hook and retain series-click filtering.

The current `netflow_bucket` event accepts any two parseable timestamps and patches the SRQL time filter. It also sends `bucket_start + bucket_seconds` as the end of an inclusive SRQL interval, which reaches the next bucket boundary. The stacked point payload contains only a timestamp and values, and the dormant D3 brush interpolates continuous timestamps from the client scale without the shared selector's accessibility, threshold, validation, or LiveView lifecycle behavior.

All three requested cards are derived from the canonical Traffic Over Time buckets. That gives the server one authoritative interval sequence for client metadata and payload validation even though the renderers compute x coordinates differently. The implementation must also account for LiveView allowing only one hook per element and for the D3 renderer clearing and rebuilding SVG children during redraws.

## Goals / Non-Goals

### Goals

- Enable the reusable range interaction on all temporal Traffic Over Time modes and both activity cards.
- Map gestures to exact rendered buckets without estimating time from container width.
- Patch the same `/observability/netflows` URL with `view=explorer`, preserve non-time investigation state, and load Flow Explorer for the selected interval.
- Keep existing tooltips, legends, one-bucket clicks, and protocol/application series clicks.
- Make the interaction work on the first attempt through LiveView updates, resize redraws, and ordinary pointer/touch/keyboard input.
- Treat range payloads as untrusted and accept only boundaries represented by the current server state.

### Non-Goals

- Add range selection to Sankey, topology, talker, device-detail, BGP, or authored-dashboard charts.
- Replace NetFlow's renderers with a universal chart component.
- Change SRQL absolute-range syntax or its inclusive comparison semantics.
- Persist a transient overlay after the URL is patched and Flow Explorer renders.
- Remove the existing opt-in `data-zoomable` D3 behavior used by device-detail flows.

## Decisions

### Decision 1: Factor the shared interaction into a composable controller

The existing `ChartRangeSelection` LiveView hook will remain the adapter used by server-owned charts, but its pointer, keyboard, overlay, click-suppression, and lifecycle state will be factored into a project-owned controller that can also be instantiated by an existing chart hook. The controller accepts resolved root, SVG, overlay, status, event callback, geometry callback, and ordered `{x, start, end}` buckets. It exposes update and destroy operations and a narrow way for a chart click handler to recognize the click immediately following a committed drag.

`NetflowTrafficTooltip` and `NetflowStackedAreaChart` will compose this controller inside their existing hooks. This avoids illegal dual hooks on one element and keeps tooltip and D3 renderer ownership intact. The standalone `ChartRangeSelection` adapter and existing Events consumer will retain their current public data attributes and behavior.

The controller will preserve an active gesture across a renderer redraw when the range root identity, event name, and canonical serialized interval identity are unchanged, even when the renderer replaces the SVG, overlay, or geometry nodes. A change to the root, event, or canonical intervals cancels transient ownership before rebinding. The final pointer-up displacement also participates in the six-pixel drag threshold so a coalesced fast drag can commit even if no qualifying pointer-move event arrived first. Those generic lifecycle corrections are a prerequisite bugfix under `add-chart-region-selection`; this proposal owns only the NetFlow consumer's lifecycle and click-arbitration outcomes.

### Decision 2: The server supplies intervals and each renderer supplies x geometry

The canonical NetFlow interval for a point begins at `bucket_start` and ends at `bucket_end - 1 microsecond`. The server will expose those exact RFC3339 values for every selectable point.

For the server SVG, one pure geometry helper will drive both rendered marks and selection metadata. Lines will place multi-point buckets at `index / (count - 1) * width`, with a single bucket centered at `width / 2`; the polyline and circle for a bucket will use that same x. Grid will divide the plot into `count` fitted bands and use each band's center as the selectable x. This removes the current disagreement between the grid rectangle start, polyline point, and offset circle center and keeps every selectable coordinate inside the plot.

For Stacked, 100%, Protocol, and Application, `NetflowStackedAreaChart` will combine the server-supplied intervals with the actual D3 time scale after dimensions are known. It will then update the shared controller with the resulting x coordinates. Missing buckets remain missing rendered positions; the controller snaps to supplied points and never interpolates a timestamp from plot width.

The D3 hook will fingerprint the inputs that affect its rendering, including data, series configuration, overlays, units, and dimensions. An `updated()` callback with the same fingerprint will preserve the existing SVG nodes and active controller state. When a real data or size change requires a redraw, the SVG root remains stable and the completed draw provides the controller its current overlay node, plot geometry, and bucket x positions.

The legacy `data-zoomable="true"` brush remains available to existing device-detail consumers. The NetFlow analytics cards opt into shared range selection instead, and the hook will not enable both interaction modes on the same chart.

### Decision 3: One validated event opens Flow Explorer

All requested cards emit `netflow_range_selected` with exactly `{start, end}`. `LogLive.Index` first requires at least one supported selector to be rendered by the current assigns. In `overview` or `traffic`, Lines/Grid are eligible only with non-empty canonical Traffic Over Time points, while Stacked/100% are eligible only with non-empty stacked points and keys. In `traffic`, each activity card is independently eligible only with non-empty points and keys. Sankey and the remaining views are never eligible. This predicate mirrors the component render guards rather than treating hidden base data as a visible interaction surface.

The handler then parses both values, requires `start < end`, derives the current inclusive bucket intervals from `socket.assigns.netflow_timeseries.points`, and requires the submitted start and end to match a contiguous ordered span in that sequence. Missing, malformed, equal, reversed, stale, or non-rendered bounds are ignored. A payload containing any key besides `start` and `end` is rejected wholesale, so the server never accepts a query fragment, field name, source card, or destination from the client.

For a valid committed range, the handler uses the existing NetFlow filter patch path to replace only `time:` with `[<start>,<end>]`, preserves all other SRQL tokens plus the current effective limit, compact/talker, compare, geography, Sankey-prefix, stack, and graph options, explicitly sets `view=explorer`, and `push_patch`es the same `/observability/netflows` route. `netflow_params/3` will preserve limit precedence explicitly: an SRQL `limit:` token remains untouched, while a query without that token carries the current effective limit in the legacy `limit=` URL parameter instead of resetting it to the default. Normal parameter handling then loads the Flow Explorer result surface for the selected interval.

The existing `netflow_bucket` path will use the same interval validation helper, but it retains the current view rather than taking the committed-range navigation path. Its rendered values will use the corrected inclusive end, so a plain one-bucket click remains supported without including a record at the next bucket boundary.

### Decision 4: A drag and a click remain distinct actions

Pointer capture and the existing six-CSS-pixel threshold distinguish a selection from a tap. Only a committed range gesture suppresses the browser click generated immediately afterward. A movement below threshold remains an ordinary click/tap and emits no range event.

Range starts remain strict to the renderer's plot bounds. After a valid pointer-down, move and pointer-up samples project their horizontal coordinate onto the plot even when their vertical coordinate has left it. This matches ordinary brush behavior and ensures a fast/coalesced drag still has a usable endpoint when the browser's first qualifying sample lands in an axis margin or just outside the SVG.

Consequently:

- Lines and Grid retain the existing one-bucket time drill-down in the current view.
- Activity by Protocol and Activity by Application retain their `protocol_group` and `app` series filters in the current view.
- Stacked and 100% Traffic Over Time retain their current no-op plain-click behavior.
- Tooltips, legend toggles, and page scrolling remain available.

Pointer cancellation, capture loss, and Escape clear only transient range state. An unrelated LiveView patch with unchanged binding metadata does not cancel the active pointer gesture.

### Decision 5: NetFlow adopts the shared keyboard and accessibility model

Each populated requested chart will expose a focusable range-selection surface, shared instructions, visible focus and selection feedback, and polite status text. Left/Right Arrow moves the active bucket, Shift plus Arrow extends or contracts from an anchor, Enter commits, and Escape clears the transient range. Pointer, touch, and keyboard paths emit the same validated event payload. Empty or invalid metadata leaves the surface non-selectable.

### Decision 6: Test the interaction at controller, renderer, and LiveView boundaries

Pure JavaScript tests will cover interval parsing, renderer-supplied geometry, pointer threshold behavior including coalesced pointer-up movement inside and outside the plot, click suppression, keyboard selection, redraw updates, and cleanup. The first-drag regression will prove that a redraw with unchanged range-root, event, and canonical-interval identities retains gesture ownership through pointer-up, while a real root, event, or interval identity change cancels it. Hook tests will cover both NetFlow renderers while protecting tooltips, legends, series clicks, and the existing device-detail brush mode.

Elixir tests will cover exact inclusive interval metadata, all four Traffic modes, both activity cards, valid and invalid payloads, current-bucket validation, non-time SRQL/URL state preservation while setting `view=explorer`, and the corrected single-bucket boundary. A browser pass will verify each requested card reaches Flow Explorer and that a first-attempt drag survives a qualifying renderer redraw before the Bazel and rollout gates run.

## Alternatives Considered

### Enable the existing D3 brush

Rejected because it only covers the D3 renderer, derives continuous timestamps client-side, lacks the shared accessibility and validation contract, and can consume protocol/application series clicks. It would leave Lines and Grid with a second implementation.

### Add separate pointer implementations to each hook

Rejected because gesture thresholds, keyboard behavior, lifecycle fixes, and click arbitration would drift between the Events chart and the two NetFlow renderers.

### Place a second LiveView hook around each existing chart hook

Rejected because hook ordering would create an implicit data handoff between parent and child hooks, while D3 redraws delete SVG children and compute final x geometry only after mount/update. Direct controller composition gives each renderer an explicit interface.

## Risks / Trade-offs

- **D3 redraws can invalidate overlay nodes.** Skip redraws whose render fingerprint is unchanged; after a necessary redraw, supply the current overlay and bucket geometry to the long-lived controller.
- **A drag can trigger an existing chart click.** Suppress only the immediate post-commit click; do not suppress sub-threshold gestures or later clicks.
- **Different renderers use different x scales.** Require each renderer to provide its actual x positions while the server remains authoritative for time bounds.
- **Inclusive SRQL can cross the next bucket boundary.** Subtract one microsecond from the exclusive bucket end for both ranges and one-bucket clicks.
- **Client metadata and payloads can be tampered with or become stale.** Match both bounds against the current canonical server bucket sequence before patching.
- **Shared-controller refactoring could regress Events.** Keep the standalone hook contract stable and run its complete existing test suite alongside the new consumers.

## Migration Plan

1. Land the shared first-drag lifecycle and final-pointer threshold correction, then archive the completed `add-chart-region-selection` prerequisite.
2. Extract the composable controller without changing the archived generic contract, with existing Events behavior protected by tests.
3. Add the NetFlow interval/validation helper and failing LiveView/component tests.
4. Integrate Lines/Grid, then the D3 temporal/activity charts with focused JavaScript tests.
5. Run browser, Bazel, and repository gates before producing one immutable build for farm01 and CarverAuto demo.

Rollback removes the NetFlow opt-in/controller composition and restores the previous one-bucket and series-click surfaces. It requires no data or schema rollback.

## Open Questions

None.
