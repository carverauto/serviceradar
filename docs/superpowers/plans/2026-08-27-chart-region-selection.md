# Chart Region Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a reusable chart range-selection interaction and use it to navigate from Dashboard Events Over Time to an exact absolute-range Events query.

**Architecture:** A pure JavaScript range helper validates chart-supplied bucket geometry and normalizes index ranges. A renderer-independent LiveView hook owns pointer and keyboard state while mutating only transient attributes on server-rendered overlay/status nodes. A pure Elixir `EventRange` module produces the same hourly bucket boundaries for rendering and server validation; the dashboard handler accepts only boundaries found in its current trend assign and constructs navigation through `ObservabilityPaths`.

**Tech Stack:** Phoenix LiveView/HEEx, Elixir `DateTime`, vanilla JavaScript LiveView hooks, Vitest, ExUnit/LazyHTML, ServiceRadar CSS tokens, Bazel.

**Spec:** `openspec/changes/add-chart-region-selection/design.md` and `openspec/changes/add-chart-region-selection/specs/build-web-ui/spec.md`

## Global Constraints

- Work only in `/private/tmp/serviceradar-gh-4084-chart-region-selection` on `codex/add-chart-region-selection`; never push directly to `staging`.
- Follow strict red-green-refactor: every production behavior starts with a focused test that is run and observed failing for the expected missing behavior.
- Add no dependency. Reuse `hoverPosition` and `plotGeometryFromDataset` from `assets/js/utils/chart_hover_geometry.js`, Phoenix navigation helpers, and existing ServiceRadar CSS tokens.
- The generic client contract is ordered `{x, start, end}` buckets plus a configurable event name. It never builds SRQL, chooses a route, fetches data, or appends persistent DOM/SVG nodes.
- Valid client metadata is a non-empty array with finite strictly increasing `x`, strict parseable RFC3339 strings, and `start < end` for every bucket. Invalid metadata disables focus and emission.
- The Events producer computes each inclusive end as `bucket_start + 3_600 seconds - 1 microsecond`, never from the next rendered bucket.
- The server parses payload timestamps, rejects equal/reversed values, and requires exact start/end boundary matches spanning the currently rendered `security_trend` buckets. It never normalizes a reversed client payload.
- The selected query is exactly `in:events time:[<start>,<end>] sort:time:desc limit:20` and is encoded through `ObservabilityPaths.path/2`.
- Every new external hook has a unique DOM id and is registered in `assets/js/hooks/index.js`. The hook does not own persistent DOM, so the server-rendered subtree remains patchable rather than using `phx-update="ignore"`.
- Every new ExUnit module is database-free, async where possible, and carries `@moduletag :db_free`. Test rendered behavior with LazyHTML selectors rather than source-text assertions.
- Visual direction: preserve the existing operations-dashboard typography and severity palette. The signature interaction is a restrained ServiceRadar-green forensic selection band with crisp boundary rails; surrounding chart layout stays quiet. Provide visible `:focus-visible`, light/dark contrast, `touch-action: pan-y`, and no decorative animation.

## File Map

- Create `elixir/web-ng/assets/js/hooks/charts/chart_range_selection.js`: pure validation, nearest-bucket, normalized-range, and overlay-boundary functions.
- Create `elixir/web-ng/assets/js/hooks/charts/chart_range_selection.test.js`: helper contract and edge-case tests.
- Create `elixir/web-ng/assets/js/hooks/charts/ChartRangeSelection.js`: reusable LiveView hook and transient interaction state.
- Create `elixir/web-ng/assets/js/hooks/charts/ChartRangeSelection.test.js`: pointer, keyboard, lifecycle, accessibility-state, and event tests.
- Modify `elixir/web-ng/assets/js/hooks/index.js`: register `ChartRangeSelection`.
- Create `elixir/web-ng/lib/serviceradar_web_ng_web/live/dashboard_live/event_range.ex`: canonical Events bucket metadata and submitted-bound validation.
- Create `elixir/web-ng/test/phoenix/live/dashboard_live/event_range_test.exs`: interval, geometry, gap, invalid input, and selection tests.
- Modify `elixir/web-ng/lib/serviceradar_web_ng_web/observability_paths.ex`: add `events_range_path/2` for already validated `DateTime` values.
- Modify `elixir/web-ng/test/phoenix/observability_paths_test.exs`: assert the exact literal intent URL.
- Modify `elixir/web-ng/lib/serviceradar_web_ng_web/live/dashboard_live/index.ex`: validate the hook event and `push_navigate/2`.
- Create `elixir/web-ng/test/phoenix/live/dashboard_live/events_range_navigation_test.exs`: event-handler navigation and rejection tests.
- Modify `elixir/web-ng/lib/serviceradar_web_ng_web/live/dashboard_live/index/events_panel.ex`: hook data, accessible surface, overlay/status, and separate fallback link.
- Create `elixir/web-ng/test/phoenix/live/dashboard_live/events_panel_test.exs`: rendered contract for populated, one-bucket, gapped, invalid, and empty states.
- Modify `elixir/web-ng/assets/css/app.css`: selection band, instructions/status/action layout, focus, touch, responsive, and light-theme styling.
- Modify `openspec/changes/update-dashboard-drilldown-actions/specs/build-web-ui/spec.md`: clarify that a range-enabled chart keeps general drill-down in a separate accessible action.

---

### Task 1: Pure Chart Range Contract

**Files:**
- Create: `elixir/web-ng/assets/js/hooks/charts/chart_range_selection.js`
- Create: `elixir/web-ng/assets/js/hooks/charts/chart_range_selection.test.js`

**Interfaces:**
- Consumes: ordered serialized bucket metadata and chart viewBox x coordinates.
- Produces: `parseRangeBuckets(serialized)`, `nearestRangeBucketIndex(buckets, viewX)`, `rangeForBucketIndexes(buckets, anchorIndex, activeIndex)`, and `overlayForBucketIndexes(buckets, anchorIndex, activeIndex, plotLeft, plotRight)`.

- [ ] **Step 1: Write the failing pure-helper tests**

Create literal fixtures for three occupied buckets with a missing wall-clock hour:

```javascript
const buckets = [
  {x: 36, start: "2026-08-27T10:00:00Z", end: "2026-08-27T10:59:59.999999Z"},
  {x: 326, start: "2026-08-27T12:00:00Z", end: "2026-08-27T12:59:59.999999Z"},
  {x: 616, start: "2026-08-27T13:00:00Z", end: "2026-08-27T13:59:59.999999Z"},
]
```

Assert these observable contracts:

```javascript
expect(parseRangeBuckets(JSON.stringify(buckets))).toEqual(buckets)
expect(nearestRangeBucketIndex(buckets, 300)).toBe(1)
expect(nearestRangeBucketIndex(buckets, -100)).toBe(0)
expect(nearestRangeBucketIndex(buckets, 900)).toBe(2)
expect(rangeForBucketIndexes(buckets, 2, 0)).toEqual({
  start: "2026-08-27T10:00:00Z",
  end: "2026-08-27T13:59:59.999999Z",
  startIndex: 0,
  endIndex: 2,
})
expect(overlayForBucketIndexes(buckets, 0, 0, 36, 616)).toEqual({x: 36, width: 145})
```

Use table-driven invalid cases for malformed JSON, non-array and empty values, duplicate/decreasing/non-finite x positions, impossible or non-RFC3339 dates, and `start >= end`; each must return `null`.

- [ ] **Step 2: Run the helper test and observe RED**

Run:

```bash
cd elixir/web-ng/assets
sfw bunx vitest run js/hooks/charts/chart_range_selection.test.js
```

Expected: FAIL because `chart_range_selection.js` or its named exports do not exist.

- [ ] **Step 3: Implement the minimal pure helper**

Implement strict metadata normalization without altering supplied timestamp strings. Use a bounded RFC3339 matcher plus calendar-component validation so values such as February 31 are rejected. Select ties deterministically toward the lower index. Compute overlay edges from neighbor midpoints, clamped to `plotLeft`/`plotRight`:

```javascript
export function rangeForBucketIndexes(buckets, anchorIndex, activeIndex) {
  if (!Array.isArray(buckets) || buckets.length === 0) return null

  const startIndex = Math.max(0, Math.min(anchorIndex, activeIndex))
  const endIndex = Math.min(buckets.length - 1, Math.max(anchorIndex, activeIndex))
  const first = buckets[startIndex]
  const last = buckets[endIndex]

  if (!first || !last) return null
  return {start: first.start, end: last.end, startIndex, endIndex}
}
```

`overlayForBucketIndexes/5` must use half-distance boundaries around selected rendered anchors and return a non-negative `{x, width}` literal object.

- [ ] **Step 4: Run the helper test and observe GREEN**

Run the Step 2 command. Expected: every helper test passes with no warnings.

- [ ] **Step 5: Self-review mutations and commit**

Confirm tests fail if x-order validation is removed, reverse indexes are not normalized, or overlay edges use timestamps instead of x anchors. Then commit only the two helper files:

```bash
git add elixir/web-ng/assets/js/hooks/charts/chart_range_selection.js elixir/web-ng/assets/js/hooks/charts/chart_range_selection.test.js
git commit -m "feat(web-ng): add chart range selection geometry"
```

### Task 2: Reusable LiveView Range Hook

**Files:**
- Create: `elixir/web-ng/assets/js/hooks/charts/ChartRangeSelection.js`
- Create: `elixir/web-ng/assets/js/hooks/charts/ChartRangeSelection.test.js`
- Modify: `elixir/web-ng/assets/js/hooks/index.js`

**Interfaces:**
- Consumes: Task 1 helper exports; root `data-range-buckets`, `data-range-event`, chart geometry data attributes, `[data-range-svg]`, `[data-range-overlay]`, and `[data-range-status]`.
- Produces: registered `ChartRangeSelection` hook that emits ordered `{start, end}` through `this.pushEvent(eventName, payload)`.

- [ ] **Step 1: Write failing hook lifecycle and pointer tests**

Build a small real event-target fake whose `addEventListener`, `removeEventListener`, `dispatch`, `setPointerCapture`, and `releasePointerCapture` mutate observable state. Supply a 640-pixel SVG rect and the Task 1 three-bucket fixture.

Assert that mounting valid metadata sets `tabindex="0"`; a forward or reverse pointer drag farther than the exact `6` CSS-pixel threshold renders the same normalized overlay and emits the same payload; a sub-threshold move, `pointercancel`, or `lostpointercapture` emits nothing and clears the overlay. Assert mouse, pen, and touch pointer types all use the same contract.

Example observable assertion:

```javascript
expect(pushEvent).toHaveBeenCalledWith("select_events_range", {
  start: "2026-08-27T10:00:00Z",
  end: "2026-08-27T13:59:59.999999Z",
})
expect(overlay.getAttribute("x")).toBe("36")
expect(overlay.getAttribute("width")).toBe("580")
```

- [ ] **Step 2: Write failing keyboard, invalid-state, and LiveView-update tests**

Assert the exact approved keyboard model: focus starts at the latest bucket; unmodified Left collapses to the preceding bucket; Shift+Left anchors there and extends left; continued Shift movement can cross an anchor; Enter commits the active/anchored span; Escape clears transient state but retains focus. Every handled key must call `preventDefault`. The polite status text must contain the selected literal bounds.

Change `data-range-buckets`, call `updated()`, and assert old overlay/status state is cleared and subsequent input uses the new buckets. Call `destroyed()` and assert every listener is removed. Mount malformed metadata and assert `tabindex` is absent, `aria-disabled="true"`, and no event can be emitted.

- [ ] **Step 3: Run the hook tests and observe RED**

Run:

```bash
cd elixir/web-ng/assets
sfw bunx vitest run js/hooks/charts/ChartRangeSelection.test.js
```

Expected: FAIL because `ChartRangeSelection.js` and hook registration do not exist.

- [ ] **Step 4: Implement and register the minimal hook**

Use `hoverPosition` and `plotGeometryFromDataset` for client-to-viewBox mapping. Keep all state on the hook instance, bind listeners once per current root, and reset/rebind in `updated()`:

```javascript
import {hoverPosition, plotGeometryFromDataset} from "../../utils/chart_hover_geometry"
import {
  nearestRangeBucketIndex,
  overlayForBucketIndexes,
  parseRangeBuckets,
  rangeForBucketIndexes,
} from "./chart_range_selection"

const DRAG_THRESHOLD_PX = 6

export default {
  mounted() {
    this.bindRangeSelection()
  },
  updated() {
    this.bindRangeSelection()
  },
  destroyed() {
    this.rangeCleanup?.()
    this.rangeCleanup = null
  },
}
```

The production object must implement `bindRangeSelection`, pointer handlers, the approved keyboard state machine, overlay/status reset, and event emission. It may set attributes/text/classes only on existing nodes and must never append chart markup. Register it in `assets/js/hooks/index.js` under the exact `ChartRangeSelection` name.

- [ ] **Step 5: Run focused and neighboring hook tests and observe GREEN**

Run:

```bash
cd elixir/web-ng/assets
sfw bunx vitest run js/hooks/charts/chart_range_selection.test.js js/hooks/charts/ChartRangeSelection.test.js js/hooks/charts/TimeseriesChart.test.js
```

Expected: all tests pass with no warnings.

- [ ] **Step 6: Commit the hook unit**

```bash
git add elixir/web-ng/assets/js/hooks/charts/ChartRangeSelection.js elixir/web-ng/assets/js/hooks/charts/ChartRangeSelection.test.js elixir/web-ng/assets/js/hooks/index.js
git commit -m "feat(web-ng): add reusable chart range hook"
```

### Task 3: Server-Side Events Range Contract

**Files:**
- Create: `elixir/web-ng/lib/serviceradar_web_ng_web/live/dashboard_live/event_range.ex`
- Create: `elixir/web-ng/test/phoenix/live/dashboard_live/event_range_test.exs`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/observability_paths.ex`
- Modify: `elixir/web-ng/test/phoenix/observability_paths_test.exs`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/dashboard_live/index.ex`
- Create: `elixir/web-ng/test/phoenix/live/dashboard_live/events_range_navigation_test.exs`

**Interfaces:**
- Consumes: dashboard trend points with `bucket: DateTime.t() | NaiveDateTime.t()`, submitted `%{"start" => binary, "end" => binary}`, and current `socket.assigns.security_trend`.
- Produces: `EventRange.x/2`, `EventRange.buckets/1 :: {:ok, [map()]} | :error`, `EventRange.selection/2 :: {:ok, {DateTime.t(), DateTime.t()}} | :error`, `ObservabilityPaths.events_range_path/2`, and the `select_events_range` LiveView handler.

- [ ] **Step 1: Write failing EventRange tests**

Create database-free async tests with literal UTC and naive fixtures. For three trend points at 10:00, 12:00, and 13:00, assert:

```elixir
assert {:ok,
        [
          %{x: 36, start: "2026-08-27T10:00:00Z", end: "2026-08-27T10:59:59.999999Z"},
          %{x: 326, start: "2026-08-27T12:00:00Z", end: "2026-08-27T12:59:59.999999Z"},
          %{x: 616, start: "2026-08-27T13:00:00Z", end: "2026-08-27T13:59:59.999999Z"}
        ]} = EventRange.buckets(points)
```

Assert a one-point chart remains valid, an invalid bucket makes the entire result `:error`, exact boundary pairs return parsed UTC DateTimes, and malformed/equal/reversed/non-rendered/stale pairs return `:error`.

- [ ] **Step 2: Write failing intent-path and LiveView handler tests**

Add a literal `ObservabilityPaths.events_range_path/2` assertion whose expected URL is:

```text
/observability/events?q=in%3Aevents+time%3A%5B2026-08-27T10%3A00%3A00Z%2C2026-08-27T12%3A59%3A59.999999Z%5D+sort%3Atime%3Adesc+limit%3A20
```

Construct a Phoenix LiveView socket with `security_trend` and assert `Index.handle_event("select_events_range", ordered_params, socket)` sets a live navigation redirect to that path. For malformed, equal, reversed, and well-formed non-rendered params, assert the returned socket has no redirect.

- [ ] **Step 3: Run the focused Elixir tests and observe RED**

Run:

```bash
cd elixir/web-ng
mix test test/phoenix/live/dashboard_live/event_range_test.exs test/phoenix/live/dashboard_live/events_range_navigation_test.exs test/phoenix/observability_paths_test.exs
```

Expected: FAIL because `EventRange`, `events_range_path/2`, and `select_events_range` do not exist. If `unbuffer` is available, prefix the command with it; do not install a new tool solely for output buffering.

- [ ] **Step 4: Implement the pure Elixir range module**

Use plain functions and pattern matching; no process or stateful component is needed:

```elixir
defmodule ServiceRadarWebNGWeb.DashboardLive.EventRange do
  @moduledoc false

  @plot_left 36
  @plot_width 580

  @spec x(non_neg_integer(), pos_integer()) :: integer()
  def x(index, count) do
    @plot_left + round(@plot_width * index / max(count - 1, 1))
  end
end
```

Complete `buckets/1` with `Enum.reduce_while/3` so any invalid point rejects the array. Convert a `%NaiveDateTime{}` as UTC. Compute end with `DateTime.add(start, 3_600, :second)` followed by `DateTime.add(-1, :microsecond)`. `selection/2` must parse both values, require `DateTime.compare(start, end) == :lt`, find exact emitted boundary strings in the current bucket list, and require `start_index <= end_index`.

- [ ] **Step 5: Implement the fixed path and LiveView navigation**

Add this public shape to `ObservabilityPaths`:

```elixir
@spec events_range_path(DateTime.t(), DateTime.t()) :: String.t()
def events_range_path(%DateTime{} = start_time, %DateTime{} = end_time) do
  query =
    "in:events time:[#{DateTime.to_iso8601(start_time)},#{DateTime.to_iso8601(end_time)}] " <>
      "sort:time:desc limit:20"

  path("events", %{q: query})
end
```

Add the dashboard callback before generic event clauses:

```elixir
def handle_event("select_events_range", params, socket) do
  case EventRange.selection(socket.assigns.security_trend, params) do
    {:ok, {start_time, end_time}} ->
      target = ObservabilityPaths.events_range_path(start_time, end_time)
      {:noreply, push_navigate(socket, to: target)}

    :error ->
      {:noreply, socket}
  end
end
```

- [ ] **Step 6: Run focused tests and observe GREEN**

Run the Step 3 command. Expected: the three test files execute and pass with zero failures.

- [ ] **Step 7: Format and commit the server unit**

Run `mix format` on the six touched Elixir files, re-run Step 3, then commit:

```bash
git add elixir/web-ng/lib/serviceradar_web_ng_web/live/dashboard_live/event_range.ex elixir/web-ng/lib/serviceradar_web_ng_web/observability_paths.ex elixir/web-ng/lib/serviceradar_web_ng_web/live/dashboard_live/index.ex elixir/web-ng/test/phoenix/live/dashboard_live/event_range_test.exs elixir/web-ng/test/phoenix/live/dashboard_live/events_range_navigation_test.exs elixir/web-ng/test/phoenix/observability_paths_test.exs
git commit -m "feat(web-ng): validate dashboard event ranges"
```

### Task 4: Events Panel Integration and Visual Treatment

**Files:**
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/dashboard_live/index/events_panel.ex`
- Create: `elixir/web-ng/test/phoenix/live/dashboard_live/events_panel_test.exs`
- Modify: `elixir/web-ng/assets/css/app.css`
- Modify: `openspec/changes/update-dashboard-drilldown-actions/specs/build-web-ui/spec.md`

**Interfaces:**
- Consumes: `EventRange.buckets/1`, `EventRange.x/2`, registered `ChartRangeSelection`, and `ObservabilityPaths.path("events")`.
- Produces: `#dashboard-events-range-selector`, JSON `data-range-buckets`, `data-range-event="select_events_range"`, server-rendered overlay/status/instructions, and `#dashboard-events-view-all` in populated and empty states.

- [ ] **Step 1: Write failing rendered-component tests**

Render `EventsPanel.render/1` with `embedded: true`, parse with LazyHTML, and assert selectors/attributes rather than raw source text. Decode `data-range-buckets` with `Jason.decode!/1` and compare literal values for one bucket and for the 10:00/12:00/13:00 gapped fixture.

Required selectors and outcomes:

```text
#dashboard-events-range-selector[phx-hook='ChartRangeSelection'][tabindex='0']
#dashboard-events-range-selector[data-range-event='select_events_range']
#dashboard-events-range-selector [data-range-svg]
#dashboard-events-range-selector [data-range-overlay]
#dashboard-events-range-selector [data-range-status][aria-live='polite']
#dashboard-events-range-instructions
#dashboard-events-view-all[href='/observability/events']
```

Assert the populated surface is not an anchor, the SVG paths/axis/legend remain present, and the empty state contains `#dashboard-events-view-all` but no hooked selector.

- [ ] **Step 2: Run the component test and observe RED**

Run:

```bash
cd elixir/web-ng
mix test test/phoenix/live/dashboard_live/events_panel_test.exs
```

Expected: FAIL because the range-selector contract and empty-state action are absent.

- [ ] **Step 3: Integrate canonical bucket metadata and accessible markup**

Alias `EventRange` and `ObservabilityPaths`. Derive one `range_buckets` result per render, encode it once with `Jason.encode!/1`, and use `EventRange.x/2` inside `event_xy/4` so SVG and metadata cannot drift.

The populated markup must follow this structure, with the existing SVG paths/axes/legend retained inside it:

```heex
<div
  id="dashboard-events-range-selector"
  phx-hook="ChartRangeSelection"
  class="sr-ops-security-chart sr-ops-events-range-selector"
  tabindex="0"
  role="group"
  aria-label="Select an Events Over Time range"
  aria-describedby="dashboard-events-range-instructions"
  data-range-buckets={Jason.encode!(@range_buckets)}
  data-range-event="select_events_range"
  data-chart-width="640"
  data-chart-left-pad="36"
  data-chart-right-pad="24"
>
  <svg data-range-svg class="sr-ops-events-area-chart" viewBox="0 0 640 220">
    <rect data-range-overlay class="sr-ops-events-range-overlay" x="36" y="26" width="0" height="154" />
  </svg>
  <div class="sr-ops-events-range-footer">
    <p id="dashboard-events-range-instructions" class="sr-ops-events-range-instructions">
      Drag across the plot, or use Shift + arrow keys and press Enter, to inspect a time range.
    </p>
    <span data-range-status class="sr-ops-events-range-status" aria-live="polite"></span>
    <.link id="dashboard-events-view-all" navigate={ObservabilityPaths.path("events")} class="sr-ops-events-view-all">
      View all events
    </.link>
  </div>
</div>
```

Render a separate View all link in the empty state. Do not add `phx-update="ignore"`: the hook only touches transient state on markup rendered here and must receive async chart patches.

- [ ] **Step 4: Add the restrained selection-band styling**

Use the existing `--sr-color-*` tokens and ServiceRadar green (`rgb(62 207 135)`) already present in dashboard CSS. The overlay is a translucent fill with a crisp non-scaling stroke; the focus ring and View all link use the same accent. Keep instructions/status compact, prevent horizontal gesture handling from blocking vertical touch scroll, and add explicit light-theme contrast. Use no new gradient and no animation.

```css
.sr-ops-events-range-selector {
  touch-action: pan-y;
}

.sr-ops-events-range-overlay {
  pointer-events: none;
  fill: rgb(62 207 135 / 0.14);
  stroke: rgb(62 207 135 / 0.92);
  stroke-width: 1.5;
  vector-effect: non-scaling-stroke;
  opacity: 0;
}

.sr-ops-events-range-overlay.is-active {
  opacity: 1;
}
```

Add responsive wrapping for the footer and a visible `:focus-visible` outline without moving layout.

- [ ] **Step 5: Reconcile the active dashboard drill-down requirement**

Amend the active requirement so its generic click contract explicitly permits range-enabled chart surfaces to keep general navigation in a separate accessible View all action. Do not modify the canonical `openspec/specs/build-web-ui/spec.md` requirement because this overlap exists only between active changes.

- [ ] **Step 6: Run focused integration tests and observe GREEN**

Run:

```bash
cd elixir/web-ng
mix test test/phoenix/live/dashboard_live/events_panel_test.exs test/phoenix/live/dashboard_live/dashboard_layout_test.exs test/phoenix/live/dashboard_live/event_range_test.exs test/phoenix/live/dashboard_live/events_range_navigation_test.exs test/phoenix/observability_paths_test.exs
```

Then run:

```bash
cd elixir/web-ng/assets
sfw bunx vitest run js/hooks/charts/chart_range_selection.test.js js/hooks/charts/ChartRangeSelection.test.js js/hooks/charts/TimeseriesChart.test.js
```

Expected: all named tests pass with no warnings.

- [ ] **Step 7: Format, validate OpenSpec, and commit the integration**

Run `mix format` on the panel and its test, then:

```bash
openspec validate add-chart-region-selection --strict
```

Commit only the integration files:

```bash
git add elixir/web-ng/lib/serviceradar_web_ng_web/live/dashboard_live/index/events_panel.ex elixir/web-ng/test/phoenix/live/dashboard_live/events_panel_test.exs elixir/web-ng/assets/css/app.css openspec/changes/update-dashboard-drilldown-actions/specs/build-web-ui/spec.md
git commit -m "feat(web-ng): select dashboard event ranges"
```

## Final Verification After Task Reviews

The controller performs these after Tasks 1-4 pass their task-scoped reviews:

1. Run the complete asset suite from `elixir/web-ng/assets` with `sfw bun run test`.
2. Run the database-free web-ng Bazel target: `bazel test -c opt --config=remote //elixir/web-ng:unit_tests`.
3. Use the local web-ng/demo CNPG workflow and Playwright to verify pointer, touch-sized viewport, keyboard, light/dark, populated/empty, and LiveView refresh behavior on `/dashboard`.
4. Run `make lint` and `make test` from the worktree, reading the final pass/fail summaries.
5. Mark every completed item in `openspec/changes/add-chart-region-selection/tasks.md`, rerun `openspec validate add-chart-region-selection --strict`, and commit the task-state update.
6. Dispatch a broad whole-branch code review, address its findings through one reviewed fix wave, then use the development-branch finishing workflow.
