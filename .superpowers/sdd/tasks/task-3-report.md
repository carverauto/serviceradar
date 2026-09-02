# Task 3 Report: Traffic Over Time Integration

## Result

Implemented OpenSpec Task 3 for Traffic Over Time in Lines, Grid, Stacked, and 100% modes. Both existing chart hooks compose the shared `ChartRangeSelectionController`; no second LiveView hook or gesture implementation was added. Protocol/Application cards remain unselected for Task 4. Existing tooltip, one-bucket click, legend, resize, and device-detail brush paths are retained, with zoomable D3 charts taking precedence over shared range selection.

## Files

- `elixir/web-ng/lib/serviceradar_web_ng_web/netflow/range_selection.ex`
- `elixir/web-ng/lib/serviceradar_web_ng_web/live/log_live/index.ex`
- `elixir/web-ng/assets/js/hooks/charts/NetflowTrafficTooltip.js`
- `elixir/web-ng/assets/js/hooks/charts/NetflowTrafficTooltip.test.js`
- `elixir/web-ng/assets/js/hooks/charts/NetflowStackedAreaChart.js`
- `elixir/web-ng/assets/js/hooks/charts/NetflowStackedAreaChart.test.js`
- `elixir/web-ng/test/phoenix/live/log_live/netflow_chart_range_components_test.exs`
- `openspec/changes/add-netflow-chart-range-selection/tasks.md` (Task 3 checkboxes only)

## TDD Evidence

### RED: component boundary

Command:

```text
SERVICERADAR_ALLOW_DB_FREE_TESTS=1 mix test test/phoenix/live/log_live/netflow_chart_range_components_test.exs --trace
```

Observed: `6 tests, 6 failures`. Lines/Grid failed because the focused component seam was still private; Stacked failed because the geometry-free canonical interval API and focused component seam did not yet exist. These were the expected pre-implementation gaps. The first two local Mix attempts also established the required invocation mode: the normal alias skipped without an enable flag, and `SERVICERADAR_REQUIRE_DB_TESTS=1` correctly required unavailable CNPG; the documented DB-free flag ran the tests.

### RED: JavaScript hook/controller boundary

Command:

```text
bunx vitest run js/hooks/charts/NetflowTrafficTooltip.test.js js/hooks/charts/NetflowStackedAreaChart.test.js
```

Observed: `2 failed files`, `10 failed tests`. Traffic tests failed because the hook had no shared controller, keyboard/pointer event emission, or post-drag click arbiter. D3 tests failed because actual-scale interval mapping, a complete render fingerprint, controller lifecycle composition, and unchanged-render skipping did not exist; the unchanged update/resize test observed three destructive draws instead of one.

### GREEN

Focused JavaScript plus shared controller/adapter regression command:

```text
bunx vitest run js/hooks/charts/NetflowTrafficTooltip.test.js js/hooks/charts/NetflowStackedAreaChart.test.js js/hooks/charts/ChartRangeSelectionController.test.js js/hooks/charts/ChartRangeSelection.test.js
```

Result: `4 passed files`, `31 passed tests`.

Focused component and canonical range-helper command:

```text
SERVICERADAR_ALLOW_DB_FREE_TESTS=1 mix test test/phoenix/live/log_live/netflow_chart_range_components_test.exs test/phoenix/live/log_live/netflow_range_selection_test.exs
```

Result: `12 tests, 0 failures`.

## Verification Gates

- Targeted chart JS lint: PASS
  - `bunx eslint js/hooks/charts/NetflowTrafficTooltip.js js/hooks/charts/NetflowTrafficTooltip.test.js js/hooks/charts/NetflowStackedAreaChart.js js/hooks/charts/NetflowStackedAreaChart.test.js`
- Elixir formatting: PASS
  - `unbuffer` was unavailable on this host, so the mandated fallback was used: `mix format --check-formatted`.
- Bazel web-ng unit suite: PASS
  - `bazel test -c opt --config=remote //elixir/web-ng:unit_tests`
  - Result: `8 out of 8 tests pass`.
- Bazel production JavaScript bundle: PASS
  - `bazel build -c opt --config=remote //elixir/web-ng/assets:js_bundle`
- OpenSpec strict validation: PASS
  - `openspec validate add-netflow-chart-range-selection --strict`
- Whitespace validation: PASS
  - `git diff --check`

## Temporary Environment Setup

The worktree lacked `elixir/web-ng/assets/node_modules`. A temporary symlink to the primary checkout's existing dependency tree was used only for focused Vitest/ESLint and Tailwind execution during the original implementation and test-correction passes. It was removed before each commit. No dependencies were installed or changed.

## Reviewer Corrections

The Task 3 review found that an unchanged fingerprint alone was not a sufficient redraw guard for existing non-`phx-update="ignore"` consumers, and requested stronger lifecycle coverage plus touch/click/title corrections.

### Corrective RED

JavaScript command:

```text
bunx vitest run js/hooks/charts/NetflowStackedAreaChart.test.js
```

Observed: `8 tests`, `2 failures`. The unchanged-fingerprint lifecycle test removed the D3 render root and still observed only one draw instead of the required second draw. The click-arbitration test observed no capture-phase click listener on the chart root.

Component command:

```text
SERVICERADAR_ALLOW_DB_FREE_TESTS=1 mix test test/phoenix/live/log_live/netflow_chart_range_components_test.exs --trace
```

Observed: `6 tests`, `3 failures`. Lines and ranged D3 roots lacked explicit `touch-pan-y`; the native SVG Grid title displayed the exclusive `bucket_end` (`10:05:00Z`) instead of the canonical inclusive end (`10:04:59.999999Z`).

### Corrective implementation and stronger coverage

- The unchanged-fingerprint skip now also requires an exact SVG fingerprint marker and the production `data-netflow-stacked-render-root`. If LiveView clears the server-owned SVG children, the missing root forces a redraw even when data and dimensions are unchanged.
- Production draw records `data-netflow-stacked-interaction="range|brush|static"`, creates the render-root marker, and supplies each newly created range overlay to the existing shared controller.
- One chart-root capture-phase click arbiter is mounted and removed with the hook lifecycle. It consumes the first synthetic background/SVG click after a completed drag; the D3 series path no longer consumes a second time, so the next ordinary series click remains available.
- Lines/Grid and ranged D3 roots use Tailwind's `touch-pan-y`, preserving horizontal selection while allowing vertical page scrolling.
- Native SVG titles now receive the same canonical inclusive end used by click values and the JavaScript tooltip.
- The strengthened D3 lifecycle test no longer replaces `_draw`. It traverses production `_renderIfChanged` and `_draw`, with narrow fakes only for DOM-heavy rendering operations. It proves intact-tree skip, cleared-tree redraw, current-overlay replacement, controller enablement, one capture listener and cleanup, background click suppression followed by a real series callback, forced legend redraw, data/resize redraw, and tooltip cleanup. A separate production draw branch proves the device-detail brush remains mutually exclusive while legend and tooltip paths stay active.

### Corrective GREEN and gates

- Focused/shared JavaScript: PASS, `4 passed files`, `32 passed tests`.
  - `bunx vitest run js/hooks/charts/NetflowTrafficTooltip.test.js js/hooks/charts/NetflowStackedAreaChart.test.js js/hooks/charts/ChartRangeSelectionController.test.js js/hooks/charts/ChartRangeSelection.test.js`
- Focused component/helper suite: PASS, `12 tests, 0 failures`.
  - `SERVICERADAR_ALLOW_DB_FREE_TESTS=1 mix test test/phoenix/live/log_live/netflow_chart_range_components_test.exs test/phoenix/live/log_live/netflow_range_selection_test.exs`
- Targeted chart JavaScript lint: PASS.
  - `bunx eslint js/hooks/charts/NetflowTrafficTooltip.js js/hooks/charts/NetflowTrafficTooltip.test.js js/hooks/charts/NetflowStackedAreaChart.js js/hooks/charts/NetflowStackedAreaChart.test.js`
- Elixir format gate: PASS.
  - `mix format --check-formatted`
- Tailwind touch behavior: PASS. A temporary `/tmp` build contained `.touch-pan-y` with `--tw-pan-y: pan-y` and `touch-action: var(--tw-pan-x,) var(--tw-pan-y,) var(--tw-pinch-zoom,)`.
  - `bunx tailwindcss --input css/app.css --output /tmp/task3-netflow-range.css`
  - `rg -n 'pan-y|touch-action' /tmp/task3-netflow-range.css`
- Bazel web-ng unit suite: PASS, `8 out of 8 tests pass`.
  - `bazel test -c opt --config=remote //elixir/web-ng:unit_tests`
- Bazel production JavaScript bundle: PASS.
  - `bazel build -c opt --config=remote //elixir/web-ng/assets:js_bundle`
- Strict OpenSpec validation: PASS (`Change 'add-netflow-chart-range-selection' is valid`).
  - `openspec validate add-netflow-chart-range-selection --strict`
- Whitespace and scope checks: PASS.
  - `git diff --check`
  - `git diff --name-only 9c7e22c332`
  - `git diff --name-only 141eaa97fd9570b4a1c58758dab07a5efc3f5162`

## Second Re-review: Direct Production-helper Coverage

The fresh re-review confirmed the production behavior but rejected the first correction's test seam because it replaced `renderStackedFrame`, `renderStackedRangeOverlay`, and `renderStackedBrush`. This second correction changes test architecture only, aside from exporting those helpers and allowing their existing D3 selection, legend-builder, and brush-factory primitives to be supplied at the lowest practical boundary.

### Second corrective RED

Command:

```text
bunx vitest run js/hooks/charts/NetflowStackedAreaChart.test.js
```

Observed: `10 tests`, `5 failures`. Three direct tests failed because the production helpers were not exported (`renderStackedFrame`, `renderStackedRangeOverlay`, and `renderStackedBrush` were “not a function”). Both real lifecycle branches then failed inside D3 `createElementNS`, proving the new tests were no longer substituting those production helpers and that the low-level recording-selection dependency had not yet been wired.

### Second corrective implementation and mutation coverage

- `renderStackedFrame`, `renderStackedRangeOverlay`, and `renderStackedBrush` are exported and are always called directly by `_draw`; the broad `_renderFrame`, `_renderRangeOverlay`, and `_renderBrush` test substitutions were removed.
- The runtime defaults remain the same D3 and chart functions: `d3.select`, `nfBuildLegend`, and `d3.brushX`. Tests supply faithful low-level recording selections, a recording legend builder, and a recording brush factory only where real DOM creation is unavailable.
- Removing the production frame's `data-netflow-stacked-render-root` append now fails the direct marker assertion and the unchanged-tree lifecycle assertion.
- Removing or changing the production series-path `.on("click", ...)` now fails discovery/invocation of the real bound handler; the lifecycle test also proves root post-drag arbitration followed by delivery through that handler to `netflow_stack_series`.
- Removing the production legend-builder call or callback now fails the direct wiring assertion; invoking the captured real `onLegendToggle` path must mutate hidden state and force another production draw.
- Removing or changing the production range-overlay append now fails exact assertions for the returned current node, `data-range-overlay`, height, hidden fill/stroke class, and `pointer-events="none"`; the lifecycle test requires that exact node to become `rangeController.options.overlay` and be replaced after redraw.
- Removing or changing the production brush path now fails `.brush`, extent, installed `end` callback, `brush.move` clearing, and exact zoom callback assertions. The lifecycle still requires brush/range mutual exclusion.
- Removing tooltip attachment or cleanup from `_draw` fails the existing lifecycle attach/cleanup counts.

### Second corrective GREEN and gates

- Focused/shared JavaScript: PASS, `4 passed files`, `35 passed tests`.
  - `bunx vitest run js/hooks/charts/NetflowTrafficTooltip.test.js js/hooks/charts/NetflowStackedAreaChart.test.js js/hooks/charts/ChartRangeSelectionController.test.js js/hooks/charts/ChartRangeSelection.test.js`
- Targeted chart JavaScript lint: PASS.
  - `bunx eslint js/hooks/charts/NetflowTrafficTooltip.js js/hooks/charts/NetflowTrafficTooltip.test.js js/hooks/charts/NetflowStackedAreaChart.js js/hooks/charts/NetflowStackedAreaChart.test.js`
- Bazel production JavaScript bundle: PASS.
  - `bazel build -c opt --config=remote //elixir/web-ng/assets:js_bundle`
- Bazel web-ng unit suite: PASS, `8 out of 8 tests pass`.
  - `bazel test -c opt --config=remote //elixir/web-ng:unit_tests`
- Strict OpenSpec validation: PASS (`Change 'add-netflow-chart-range-selection' is valid`).
  - `openspec validate add-netflow-chart-range-selection --strict`
- Whitespace and second-correction scope checks: PASS.
  - `git diff --check`
  - `git diff --name-only 3dbe2c6c7b2581ac88b92209e391528888facd10`

## Final Mutation Re-review: Structural Recording Identity

The final mutation re-review found that the recording selection registered selectors on whichever selection received `.attr`, so the tests did not yet prove that production had appended the required child before applying its attributes. This pass changes only the test recorder and assertions; production code is unchanged.

### Final mutation RED

Command:

```text
bunx vitest run js/hooks/charts/NetflowStackedAreaChart.test.js
```

Observed: `10 tests`, `4 failures`. The new frame, overlay, brush, and lifecycle assertions all received `undefined` for the expected child tag names under the old recorder. This established that it lacked explicit structural identity even though selector lookup succeeded.

### Final mutation implementation and coverage

- Every recording `.append(tag)` now creates a distinct child `RecordingSelection` and `FakeNode`, records the explicit tag name, and links both selection and node to the exact parent identity. Attributes continue to mutate only the receiving child.
- The frame helper test requires `renderStackedFrame` to return a distinct `<g>` selection whose node is the registered render root, whose parent is the SVG node, and whose marker attribute is absent from the SVG parent. Deleting the production `.append("g")` fails these assertions.
- The range helper test requires a distinct `<rect>` node under the supplied plot group, proves the plot parent lacks `data-range-overlay`, and the lifecycle requires the controller to receive that exact rect whose parent is the current render root. Deleting the production `.append("rect")` fails these assertions.
- The brush helper test requires a distinct `<g class="brush">` under the supplied plot group. It separately records the final installation call `brushGroup.call(brush)` and the later cleanup call `brushGroup.call(brush.move, null)`, requiring both to target the exact brush child selection. Deleting either the production append or final brush installation fails the test.

### Final mutation GREEN and gates

- Focused/shared JavaScript: PASS, `4 passed files`, `35 passed tests`.
  - `bunx vitest run js/hooks/charts/NetflowTrafficTooltip.test.js js/hooks/charts/NetflowStackedAreaChart.test.js js/hooks/charts/ChartRangeSelectionController.test.js js/hooks/charts/ChartRangeSelection.test.js`
- Targeted chart JavaScript lint: PASS.
  - `bunx eslint js/hooks/charts/NetflowTrafficTooltip.js js/hooks/charts/NetflowTrafficTooltip.test.js js/hooks/charts/NetflowStackedAreaChart.js js/hooks/charts/NetflowStackedAreaChart.test.js`
- Bazel production JavaScript bundle: PASS.
  - `bazel build -c opt --config=remote //elixir/web-ng/assets:js_bundle`
- Whitespace and final-correction scope checks: PASS.
  - `git diff --check`
  - `git diff --name-only 4c4a0e2464eae351727601e299773bfeb85b3c5a`

## Commit

The original implementation is commit `141eaa97fd9570b4a1c58758dab07a5efc3f5162` with subject `feat(web-ng): add NetFlow traffic range selection`. Reviewer corrections are included in the following local fix commit; its exact immutable SHA is reported to the parent after commit creation (`git log -1 --format=%H`). No push was performed.

## Concerns

None. Task 4 still owns Protocol/Application range metadata and click-arbitration opt-in. Browser rollout and cross-card activity verification remain in the later OpenSpec verification/rollout section and were intentionally not performed in this implementation-only task.
