## 1. Reusable Range-Selection Behavior

- [x] 1.1 Add failing Vitest coverage for client-to-viewBox coordinate mapping, nearest-bucket snapping, reverse drags producing ordered bounds, single-bucket ranges, missing time buckets, plot-edge clamping, movement below the drag threshold, and rejected absent/malformed/unordered bucket metadata.
- [x] 1.2 Implement a pure chart range-selection helper that consumes ordered `{x, start, end}` bucket metadata and returns normalized inclusive bounds without interpolating timestamps.
- [x] 1.3 Add failing hook tests for mouse/pen/touch Pointer Events, pointer cancellation and capture loss, the defined keyboard anchor/move/extend/cross/commit model, prevented default key behavior, Escape, LiveView `updated()` metadata refresh/reset, and `destroyed()` cleanup.
- [x] 1.4 Implement and register the `ChartRangeSelection` hook with configurable LiveView event emission and no renderer- or SRQL-specific behavior.
- [x] 1.5 Add selection-overlay, instruction, status, focus-visible, and touch-action styling using existing web-ng design tokens in both light and dark themes.

## 2. Events Range Intent

- [x] 2.1 Add failing Elixir tests for construction of an Events observability intent containing `in:events time:[<start>,<end>] sort:time:desc limit:20` and for correct URL encoding through `ObservabilityPaths`.
- [x] 2.2 Add a project-owned helper that accepts validated DateTimes and constructs the fixed selected-range Events intent URL.
- [x] 2.3 Add failing dashboard LiveView tests proving an ordered payload matching current rendered buckets navigates while malformed, equal, reversed, stale, out-of-window, and well-formed but non-rendered bounds do not navigate. Reverse-gesture normalization remains covered by the hook tests in 1.1 and 1.3.
- [x] 2.4 Add the dashboard range-selection event handler, parse ISO 8601 bounds server-side, require exact boundary matches for a contiguous span of the current rendered Events buckets, and navigate valid selections with `push_navigate/2`.

## 3. Events Over Time Integration

- [x] 3.1 Add failing component tests for the hook id/attributes, ordered bucket metadata, exact inclusive hourly bounds, accessible instructions/status, separate View all action, one-bucket data, missing-hour data, and the empty state.
- [x] 3.2 Derive each rendered Events bucket's `{x, start, end}` metadata from the same point order and geometry used by the SVG, with the inclusive end computed as `bucket_start + 1 hour - 1 microsecond` rather than from the next rendered bucket.
- [x] 3.3 Replace the populated chart's whole-surface link with the opt-in range-selection surface, server-rendered overlay/status markup, and a separate `/observability/events` fallback link available in populated and empty states.
- [x] 3.4 Add regression coverage proving existing chart paths, axes, legend, responsive layout, and dashboard drill-down accessibility remain intact.
- [x] 3.5 Reconcile the active `update-dashboard-drilldown-actions` clickable-panel wording so its generic drill-down contract explicitly permits a range-enabled chart surface with a separate View all action before either change is archived.

## 4. Verification

- [x] 4.1 Run the new chart range helper and `ChartRangeSelection` hook Vitest files alongside the complete `elixir/web-ng/assets` test suite.
- [x] 4.2 Run `mix format --check-formatted` and focused database-free ExUnit coverage for the Events panel component, dashboard range event/navigation, and `ObservabilityPaths` selected-range intent helper.
- [x] 4.3 Verify pointer, touch-sized, and keyboard interaction in a browser with populated and empty Events data, including light/dark themes and a dashboard async refresh.
- [x] 4.4 Run `make lint` and the repository-wide `make test` Bazel gate.
