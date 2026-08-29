# Design: NetFlow Chart Range Selection

## Context

`/observability/netflows` is rendered by `LogLive.Index`. Its Traffic Over Time card has two renderer families: Lines and Grid use a server-rendered SVG with the `NetflowTrafficTooltip` hook, while Stacked and 100% use the D3-owned `NetflowStackedAreaChart` hook. Activity by Protocol and Activity by Application use that same D3 hook and retain series-click filtering.

The current `netflow_bucket` event accepts any two parseable timestamps and patches the SRQL time filter. It also sends `bucket_start + bucket_seconds` as the end of an inclusive SRQL interval, which reaches the next bucket boundary. The stacked point payload contains only a timestamp and values, and the dormant D3 brush interpolates continuous timestamps from the client scale without the shared selector's accessibility, threshold, validation, or LiveView lifecycle behavior.

All three requested cards are derived from the canonical Traffic Over Time buckets. That gives the server one authoritative interval sequence for client metadata and payload validation even though the renderers compute x coordinates differently. The implementation must also account for LiveView allowing only one hook per element and for the D3 renderer clearing and rebuilding SVG children during redraws.

The initial implementation and two follow-up pointer fixes passed their fake-DOM suites but operators can still produce a first drag that highlights no usable range or requires an immediate retry. The symptom occurs on Lines/Grid and on the D3 charts, so renderer-specific brush behavior is not the common boundary. All six supported surfaces compose `ChartRangeSelectionController`; the remaining design work therefore belongs to the controller's browser lifecycle and to the adapters' readiness handoff.

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

### Decision 1: The stable chart root owns one controller lifecycle

`ChartRangeSelection`, `NetflowTrafficTooltip`, and `NetflowStackedAreaChart` will continue to compose one project-owned `ChartRangeSelectionController`. The stable hook root, rather than a renderer-owned SVG node, owns pointer-down, keyboard, and click-arbitration listeners for the controller's lifetime. SVG, overlay, status, plot geometry, and ordered `{x, start, end}` buckets are a replaceable binding supplied by the current renderer.

A binding becomes ready atomically only after all required nodes, valid buckets, geometry callbacks, and the event callback exist. Until then the root remains non-selectable and exposes `aria-disabled="true"`. The server SVG adapter refreshes the binding after each LiveView update; the D3 adapter refreshes it only after a complete draw. Neither adapter owns gesture state or adds a second range-selection hook.

On an accepted in-plot pointer-down, the controller records the pointer identity, original client sample, anchor bucket, and semantic binding identity, and immediately installs stable document-level move/up/cancel tracking. Explicit pointer capture may remain threshold-gated so a sub-threshold protocol/application tap retains its native series target. Pointer-up displacement still participates in the six-pixel threshold, allowing a coalesced fast drag to commit when no qualifying pointer-move was delivered.

Semantic identity is the stable root, event name, enabled state, and ordered canonical interval sequence. A compatible update may replace SVG, overlay, status, dimensions, x geometry, or other renderer-owned nodes while preserving the active pointer transaction; continuations use the latest geometry. A semantic identity change cancels the stale transaction, releases capture and document tracking, and emits nothing. Every accepted transaction has exactly one terminal outcome: commit once or cancel cleanly.

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

### Decision 6: Test native browser routing as a required boundary

Pure JavaScript tests will continue to cover interval parsing, renderer-supplied geometry, pointer threshold behavior, click suppression, keyboard selection, semantic-binding cancellation, and cleanup. Adapter tests will protect tooltips, legends, series clicks, and the existing device-detail brush mode.

Those tests are not sufficient for this regression: their manual fake nodes do not implement native bubbling, Pointer Event retargeting, SVG hit testing, layout, or capture loss when a node is removed. A Bazel Playwright acceptance target will load the production server-SVG and D3 hooks in real Chromium. Each table-driven case starts from a fresh page, presses inside the first bucket, forces a compatible SVG/overlay redraw before release, and releases through raw Chromium input without relying on an intervening in-plot move. The first attempt must emit exactly one range action. A second case establishes capture before redraw and verifies the same exactly-once outcome.

Elixir tests will continue to cover exact inclusive interval metadata, all four Traffic modes, both activity cards, valid and invalid payloads, current-bucket validation, and URL state preservation. Deployed verification must exercise the first gesture immediately after mount and immediately after a renderer redraw on both renderer families, with an explicit failure branch and the exact running image digest.

## Alternatives Considered

### Enable the existing D3 brush

Rejected because it only covers the D3 renderer, derives continuous timestamps client-side, lacks the shared accessibility and validation contract, and can consume protocol/application series clicks. It would leave Lines and Grid with a second implementation.

### Add separate pointer implementations to each hook

Rejected because gesture thresholds, keyboard behavior, lifecycle fixes, and click arbitration would drift between the Events chart and the two NetFlow renderers.

### Place a second LiveView hook around each existing chart hook

Rejected because hook ordering would create an implicit data handoff between parent and child hooks, while D3 redraws delete SVG children and compute final x geometry only after mount/update. Direct controller composition gives each renderer an explicit interface.

## Risks / Trade-offs

- **D3 redraws can invalidate overlay nodes.** Skip redraws whose render fingerprint is unchanged; after a necessary redraw, supply the current overlay and bucket geometry to the long-lived controller.
- **A chart can be visible before its current interaction binding is ready.** Keep the stable root disabled until the adapter publishes one complete binding, then enable it atomically.
- **A drag can trigger an existing chart click.** Suppress only the immediate post-commit click; do not suppress sub-threshold gestures or later clicks.
- **Different renderers use different x scales.** Require each renderer to provide its actual x positions while the server remains authoritative for time bounds.
- **Inclusive SRQL can cross the next bucket boundary.** Subtract one microsecond from the exclusive bucket end for both ranges and one-bucket clicks.
- **Client metadata and payloads can be tampered with or become stale.** Match both bounds against the current canonical server bucket sequence before patching.
- **Shared-controller refactoring could regress Events.** Keep the standalone hook contract stable and run its complete existing test suite alongside both renderer adapters and the real-browser gate.

## Migration Plan

1. Capture the failing browser lifecycle at the shared controller boundary and add the real-Chromium regression before changing production behavior.
2. Move pointer-start ownership to the stable root and make renderer bindings atomic, preserving the standalone Events adapter contract.
3. Protect server-SVG, D3, ordinary click, keyboard, touch-scroll, redraw, and teardown behavior with focused tests.
4. Run the Chromium, asset, Elixir, Bazel, and repository gates.
5. Produce one immutable Bazel build, roll it to farm01 and CarverAuto demo, and verify first-attempt behavior against the exact digest before completing the remaining tasks.

Rollback removes the NetFlow opt-in/controller composition and restores the previous one-bucket and series-click surfaces. It requires no data or schema rollback.

## Open Questions

None.
