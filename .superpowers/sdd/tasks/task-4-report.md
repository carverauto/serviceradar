# Task 4 Report: Protocol and Application Activity Integration

## Result

Implemented OpenSpec Task 4 for Activity by Protocol and Activity by Application. The Traffic view now renders both cards through a focused public `netflow_activity_cards/1` component seam. Each populated card opts the existing `NetflowStackedAreaChart` hook into the reviewed shared range controller with exact canonical base Traffic Over Time intervals and the common `netflow_range_selected` event. Their existing `protocol_group` and `app` series actions, points, keys, colors, legends, tooltips, empty messages, and URL state remain intact.

No shared controller, production D3 hook, range payload, LiveView event handler, query path, Sankey consumer, or other chart consumer changed.

## Files

- `elixir/web-ng/lib/serviceradar_web_ng_web/live/log_live/index.ex`
- `elixir/web-ng/assets/js/hooks/charts/NetflowStackedAreaChart.test.js`
- `elixir/web-ng/test/phoenix/live/log_live/netflow_chart_range_components_test.exs`
- `elixir/web-ng/test/phoenix/live/log_live/netflow_range_navigation_test.exs`
- `openspec/changes/add-netflow-chart-range-selection/tasks.md` (Task 4 checkboxes only)
- `.superpowers/sdd/tasks/task-4-report.md`

## TDD Evidence

### Component and real call-site RED

Command:

```text
SERVICERADAR_ALLOW_DB_FREE_TESTS=1 mix test test/phoenix/live/log_live/netflow_chart_range_components_test.exs --trace
```

Result before production opt-in: `9 tests, 3 failures`. All three new activity component tests failed with `UndefinedFunctionError` for the not-yet-created public `Index.netflow_activity_cards/1` seam. Existing Traffic component tests remained green. This was the expected missing production boundary.

### D3 arbitration test-first result

The new table-driven production-hook tests were added before the activity markup opt-in. After the worktree was connected to the primary checkout's existing `node_modules`, the corrected tests passed against the reviewed Task 3 hook/controller without a production JavaScript change. They exercise both `series_field="protocol_group"` and `series_field="app"` through the actual frame, range overlay, series callback, legend callback, tooltip lifecycle, controller, and root capture arbiter.

Two interim failures were test setup errors, not product gaps: the keyboard sequence retained a prior pointer anchor. Adding Escape and deriving the intended full-range keystrokes from the controller state corrected the fixture. The final pre-opt-in focused result was `12 tests, 0 failures`.

### Direct-socket URL test-first result

The isolated Protocol-only and Application-only direct `Phoenix.LiveView.Socket` tests were added before production opt-in. An initial run failed because the fixture used unsupported `sankey_prefix=20`; NetFlow supports `16` or `24`. After correcting the fixture to `16`, both new tests passed against the existing Task 2 common `netflow_range_selected` handler. This confirms no card-specific event/query path was needed or added.

### GREEN

Focused shared JavaScript:

```text
./node_modules/.bin/vitest run js/hooks/charts/NetflowStackedAreaChart.test.js js/hooks/charts/ChartRangeSelectionController.test.js js/hooks/charts/ChartRangeSelection.test.js js/hooks/charts/NetflowTrafficTooltip.test.js
```

Result: `4 passed files`, `37 passed tests`.

Focused database-free Elixir:

```text
SERVICERADAR_ALLOW_DB_FREE_TESTS=1 mix test test/phoenix/live/log_live/netflow_chart_range_components_test.exs test/phoenix/live/log_live/netflow_range_navigation_test.exs test/phoenix/live/log_live/netflow_range_selection_test.exs
```

Result: `24 tests, 0 failures`.

## Verification Gates

- Targeted stacked-chart JavaScript lint: PASS.
  - `./node_modules/.bin/eslint js/hooks/charts/NetflowStackedAreaChart.js js/hooks/charts/NetflowStackedAreaChart.test.js`
- Elixir formatting: PASS.
  - `unbuffer` was unavailable, so the required fallback was used: `mix format --check-formatted`.
- Bazel web-ng unit suite: PASS.
  - `bazel test -c opt --config=remote //elixir/web-ng:unit_tests`
  - Result: `8 out of 8 tests pass`.
- Bazel production JavaScript bundle: PASS.
  - `bazel build -c opt --config=remote //elixir/web-ng/assets:js_bundle`
- Strict OpenSpec validation: PASS.
  - `openspec validate add-netflow-chart-range-selection --strict`
- Whitespace validation: PASS.
  - `git diff --check`

## Self-review

- The two real Traffic-view call sites each pass `RangeSelection.canonical_intervals(@timeseries.points)` and `range_event="netflow_range_selected"`.
- Activity metadata tests use literal gapped base-bucket expectations, including each bucket's own `bucket_end - 1 microsecond`; they do not infer an end from the next occupied bucket.
- Populated Protocol and Application roots have distinct accessible names and instructions, one existing hook, `phx-update="ignore"`, `touch-pan-y`, focus/group semantics, and polite status output.
- Empty activity cards keep `No protocols samples in this window.` and `No apps samples in this window.` and expose no hook, range metadata, focus target, or status.
- Range events contain only `{start, end}`. Ordinary series actions retain server-authored `protocol_group` or `app` fields through the separate existing `netflow_stack_series` event.
- Forward/reverse drags, background and series-target synthetic clicks, subsequent ordinary clicks, keyboard selection, colors, legend toggles, tooltips, and cleanup are covered for both activity series fields through the production hook path.
- No Sankey or non-temporal consumer was opted in.

## Temporary setup and cleanup

The worktree had only an incomplete ignored `assets/node_modules/.vite` directory. It was moved aside and replaced temporarily with a symlink to the primary checkout's existing dependency tree for Vitest and ESLint, then the symlink and moved-aside directory were removed. `elixir/web-ng/assets/node_modules` is absent at handoff.

One early `bunx vitest` attempt resolved the runner in Bun's external cache and then failed because project `d3` was unavailable. It did not modify a project lockfile, install project dependencies, or leave a worktree artifact. Subsequent JavaScript commands used the existing dependency-tree symlink directly.

## Commit

The local commit uses subject `feat(web-ng): add activity chart range selection`. Its immutable SHA is reported to the parent after commit creation. No push was performed.

## Concerns

The new D3 arbitration and isolated URL contracts were already satisfied by the reviewed Task 3 controller/hook and Task 2 common LiveView handler once their test fixtures were correct. The only expected product RED was the missing activity component/call-site opt-in. This is why the implementation intentionally contains no JavaScript controller or LiveView handler change.

## Review correction: Sankey opt-in and independent empty branches

The Task 4 review identified that the public activity-card seam did not receive the active graph mode. Consequently, a valid `view=traffic&graph=sankey` render advertised focusable Protocol and Application range controls even though the common server predicate correctly rejects every Sankey range. The review also required empty-state coverage for each card when either render guard fails independently, rather than only when both points and keys are empty together.

### Corrective RED

The component tests were expanded first with:

- both populated activity charts under `graph_mode="sankey"`, retaining their hook, data, colors, and series fields while expecting no range event/intervals, `touch-pan-y`, group/focus semantics, instructions, or status;
- both populated activity charts under each supported temporal Traffic graph mode (`lines`, `grid`, `stacked`, and `stacked100`), expecting normal range opt-in;
- four independent empty guards: Protocol points empty, Protocol keys empty, Application points empty, and Application keys empty, each with the other card populated and interactive.

Command:

```text
SERVICERADAR_ALLOW_DB_FREE_TESTS=1 mix test test/phoenix/live/log_live/netflow_chart_range_components_test.exs --trace
```

Observed RED: `12 tests, 1 failure`. The Sankey test received `data-range-event="netflow_range_selected"` instead of no attribute. All four independent empty-guard cases passed and proved the existing component's empty branches were already inert.

### Corrective implementation

The real `netflow_summary/1` call now passes `@graph_mode` into `netflow_activity_cards/1`. That seam keeps both ordinary activity charts rendered for every Traffic graph mode, but supplies canonical intervals and `netflow_range_selected` only when the graph is not Sankey. No handler, shared controller, D3 hook, series payload, or Sankey chart code changed.

### Corrective GREEN and gates

- Focused component RED-to-GREEN: PASS, `12 tests, 0 failures`.
- Focused database-free NetFlow suite: PASS, `27 tests, 0 failures`.
  - `SERVICERADAR_ALLOW_DB_FREE_TESTS=1 mix test test/phoenix/live/log_live/netflow_chart_range_components_test.exs test/phoenix/live/log_live/netflow_range_navigation_test.exs test/phoenix/live/log_live/netflow_range_selection_test.exs`
- Focused shared JavaScript: PASS, `4 passed files`, `37 passed tests`.
  - `./node_modules/.bin/vitest run js/hooks/charts/NetflowStackedAreaChart.test.js js/hooks/charts/ChartRangeSelectionController.test.js js/hooks/charts/ChartRangeSelection.test.js js/hooks/charts/NetflowTrafficTooltip.test.js`
- Targeted stacked-chart JavaScript lint: PASS.
  - `./node_modules/.bin/eslint js/hooks/charts/NetflowStackedAreaChart.js js/hooks/charts/NetflowStackedAreaChart.test.js`
- Elixir formatting: PASS.
  - `mix format --check-formatted`
- Bazel web-ng unit suite: PASS, `8 out of 8 tests pass`.
  - `bazel test -c opt --config=remote //elixir/web-ng:unit_tests`
- Bazel production JavaScript bundle: PASS.
  - `bazel build -c opt --config=remote //elixir/web-ng/assets:js_bundle`
- Strict OpenSpec and whitespace checks were rerun after this report update and passed.
  - `openspec validate add-netflow-chart-range-selection --strict`
  - `git diff --check`
- The corrective local commit uses subject `fix(web-ng): gate activity ranges from Sankey`; its immutable SHA is reported to the parent after commit creation. No push was performed.
