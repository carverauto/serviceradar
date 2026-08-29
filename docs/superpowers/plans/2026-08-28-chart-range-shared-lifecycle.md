# Chart Range Shared Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the first qualifying range drag commit exactly once on both server-rendered SVG and D3 NetFlow charts, including across renderer-owned node replacement.

**Architecture:** Keep one `ChartRangeSelectionController` shared by Events and every NetFlow renderer. Bind gesture ownership to the stable hook root, publish renderer geometry as an atomic replaceable binding, and gate the behavior with a real-Chromium acceptance test that exercises native pointer routing and SVG replacement.

**Tech Stack:** Phoenix LiveView/HEEx, JavaScript, D3, Vitest, Playwright/Chromium, Bazel, BuildBuddy.

**Spec:** `openspec/changes/add-netflow-chart-range-selection/design.md`

## Global Constraints

- Do not add a D3-only brush path; Lines, Grid, Stacked, 100%, Protocol, and Application must use the shared controller.
- Do not add Docker, Colima, or local container steps. Build, test, and publish through Bazel targets only.
- Keep pointer capture threshold-gated so a sub-threshold protocol/application tap retains its native series target.
- Starts remain strict to current plot bounds; active continuation and release coordinates may clamp through current renderer geometry.
- Preserve exact server-supplied `{start, end}` intervals and existing server-side validation.
- Preserve the standalone Events adapter, NetFlow tooltips, series clicks, keyboard operation, touch scrolling, and device-detail `data-zoomable` behavior.
- Write each production change only after its focused test has failed for the expected reason.
- Use the worktree's linked `.bazelrc.remote` and `.bazelrc.local` for every Bazel command.

---

### Task 1: Real-Chromium first-attempt regression

**Files:**

- Create: `elixir/web-ng/assets/chart_range_selection_acceptance_harness.js`
- Create: `elixir/web-ng/assets/chart_range_selection_acceptance.playwright.js`
- Create: `elixir/web-ng/assets/chart_range_selection_test_runner.mjs`
- Create: `elixir/web-ng/test/playwright/chart_range_selection.playwright.js`
- Modify: `elixir/web-ng/assets/BUILD.bazel`
- Modify: `elixir/web-ng/test/playwright/BUILD.bazel`
- Modify: `elixir/web-ng/test/playwright/playwright.config.js`
- Modify: `buildbuddy.yaml`

**Interfaces:**

- Consumes: production `NetflowTrafficTooltip` and `NetflowStackedAreaChart` hook objects.
- Produces: `window.chartRangeAcceptance.mount(renderer)`, `replaceRendererNodes()`, `updateHook()`, `snapshot()`, plus Bazel targets `//elixir/web-ng/assets:chart_range_selection_unit_tests`, `//elixir/web-ng/assets:asset_unit_tests`, and `//elixir/web-ng/test/playwright:chart_range_selection_acceptance`.

- [ ] **Step 1: Add a browser harness around the real hooks**

Create an IIFE-bundled browser fixture that mounts each production hook without replacing its controller or geometry code. The public fixture shape is:

```js
window.chartRangeAcceptance = {
  mount(renderer) {
    const root = renderer === "server-svg" ? serverSvgFixture() : d3Fixture()
    const hookDefinition = renderer === "server-svg" ? NetflowTrafficTooltip : NetflowStackedAreaChart
    const hook = Object.assign(Object.create(hookDefinition), {
      el: root,
      pushEvent(name, payload) {
        trace.push({kind: "push", name, payload})
      },
    })
    document.body.replaceChildren(root)
    hook.mounted()
    state = {hook, renderer, root, trace}
    return snapshot()
  },
  replaceRendererNodes,
  updateHook() {
    state.hook.updated()
    return snapshot()
  },
  snapshot,
}
```

Use two literal intervals and expected payloads rather than deriving expectations with production helpers:

```js
const INTERVALS = [
  {start: "2026-08-29T01:00:00.000000Z", end: "2026-08-29T01:00:59.999999Z"},
  {start: "2026-08-29T01:01:00.000000Z", end: "2026-08-29T01:01:59.999999Z"},
]
```

The harness must record pointer type, target/current-target labels, pointer ID, root capture state, renderer replacement/update, pushes, and clicks. It must use a real `ResizeObserver` fallback only when Chromium does not provide one; it must not fake pointer capture, layout, bubbling, or event dispatch.

- [ ] **Step 2: Add the failing table-driven Playwright case**

For `server-svg` and `d3`, start with a fresh page and run this sequence:

```js
for (const renderer of ["server-svg", "d3"]) {
  test(`${renderer} first drag survives a compatible node replacement`, async ({page}) => {
    await mountFixture(page, renderer)
    const box = await page.locator('[role="group"]').boundingBox()
    expect(box).not.toBeNull()

    await page.evaluate(() => window.chartRangeAcceptance.replaceRendererNodes())

    const session = await page.context().newCDPSession(page)
    await session.send("Input.dispatchMouseEvent", {
      type: "mousePressed",
      x: box.x + box.width * 0.25,
      y: box.y + box.height * 0.5,
      button: "left",
      buttons: 1,
      clickCount: 1,
    })
    await page.evaluate(() => window.chartRangeAcceptance.updateHook())
    await session.send("Input.dispatchMouseEvent", {
      type: "mouseReleased",
      x: box.x + box.width * 0.75,
      y: box.y + box.height + 8,
      button: "left",
      buttons: 0,
      clickCount: 1,
    })

    expect(await pushes(page)).toEqual([{
      kind: "push",
      name: "netflow_range_selected",
      payload: {
        start: "2026-08-29T01:00:00.000000Z",
        end: "2026-08-29T01:01:59.999999Z",
      },
    }])
  })
}
```

Add a second table-driven case that sends one qualifying `mouseMoved` before replacement so explicit capture is established, then releases after redraw. Add one sub-threshold click case that asserts zero range pushes and one existing click action.

- [ ] **Step 3: Register focused/full Vitest and browser acceptance targets**

Create a Bazel-owned Vitest runner instead of installing dependencies in the worktree:

```js
import {startVitest} from "vitest/node"
import {resolve} from "node:path"

const runfilesRoot = resolve(process.env.TEST_SRCDIR, process.env.TEST_WORKSPACE)
const filters = process.argv.slice(2).map((filter) => resolve(runfilesRoot, filter))
const context = await startVitest("test", filters, {
  root: process.cwd(),
  run: true,
  watch: false,
})
await context.exit()
```

In `assets/BUILD.bazel`, add one `js_test` with the four chart files as arguments and one with the complete existing asset-test inventory:

```starlark
_CHART_RANGE_SELECTION_TESTS = [
    "js/hooks/charts/ChartRangeSelection.test.js",
    "js/hooks/charts/ChartRangeSelectionController.test.js",
    "js/hooks/charts/NetflowStackedAreaChart.test.js",
    "js/hooks/charts/NetflowTrafficTooltip.test.js",
]

_ASSET_UNIT_TESTS = glob([
    "js/lib/god_view/*.test.js",
    "js/wasm/*.test.js",
    "js/lib/remote_desktop/*.test.js",
    "js/lib/srql/*.test.js",
    "js/utils/*.test.js",
    "js/hooks/charts/*.test.js",
]) + [
    "js/hooks/DashboardWasmHost.test.js",
    "js/hooks/DialogTopLayer.test.js",
    "js/hooks/ToastTopLayer.test.js",
    "js/hooks/RemoteAccessDesktopSession.test.js",
    "js/hooks/RemoteAccessSSHConsole.test.js",
    "js/hooks/SRQLInput.test.js",
    "js/hooks/SRQLTimeCookie.test.js",
    "js/hooks/SettingsNavTree.test.js",
    "component/test/DashboardPanelChart.test.jsx",
    "component/test/RemoteAccessDesktopSession.test.jsx",
    "component/test/RemoteAccessSSHConsole.test.jsx",
    "component/test/sshEphemeralKeypair.test.js",
]
```

Both targets use `:node_modules`, the real production/test sources, and `chart_range_selection_test_runner.mjs`; neither invokes Bun, npm, or a shell script.

In `assets/BUILD.bazel`, reuse the existing esbuild binary to produce `chart_range_selection_acceptance.bundle.js`, and export the Playwright test library with its production JS dependencies and `@playwright/test`. In `test/playwright/BUILD.bazel`, add:

```starlark
playwright_bin.playwright_test(
    name = "chart_range_selection_acceptance",
    size = "medium",
    args = ["test", "--config=playwright.config.js"],
    chdir = package_name(),
    data = [
        "chart_range_selection.playwright.js",
        "playwright.config.js",
        "//elixir/web-ng/assets:chart_range_selection_acceptance_test_lib",
        "//elixir/web-ng/assets:chart_range_selection_acceptance_bundle",
        "//elixir/web-ng/assets:node_modules/@playwright/test",
    ],
    env = {
        "CHART_RANGE_SELECTION_ACCEPTANCE_BUNDLE": "$(rootpath //elixir/web-ng/assets:chart_range_selection_acceptance_bundle)",
        "CI": "1",
        "PLAYWRIGHT_BROWSERS_PATH": "/ms-playwright",
        "PLAYWRIGHT_TEST_MATCH": "chart_range_selection.playwright.js",
    },
    exec_properties = {
        "container-image": "docker://registry.carverauto.dev/serviceradar/playwright-rbe@sha256:d9266ee97f0dbd297618a10afb00b5006ebf2bb19dd38887da3230ed4b7829ea",
    },
    tags = ["acceptance_test", "external", "no-local", "no-remote-cache"],
)
```

Make `playwright.config.js` use `process.env.PLAYWRIGHT_TEST_MATCH || "god_view_elk_scene.playwright.js"`, retaining the existing default. Add the new target beside the God View acceptance step in `buildbuddy.yaml` with `--test_output=errors --nocache_test_results --flaky_test_attempts=1`.

- [ ] **Step 4: Run the acceptance target and verify RED**

Run:

```bash
bazel test -c opt --config=remote \
  //elixir/web-ng/test/playwright:chart_range_selection_acceptance \
  --test_output=errors --nocache_test_results --flaky_test_attempts=1
```

Expected: FAIL on current production code because the new renderer SVG receives the physical pointer-down before the adapter rebinds the controller's SVG listener, yielding zero `netflow_range_selected` pushes on the first attempt. The trace must show the replacement and pointer-down occurred; an infrastructure error or missing fixture does not qualify as RED. If both renderer cases pass, stop before Task 2 and use the captured trace to revise the root-cause hypothesis and OpenSpec design.

- [ ] **Step 5: Commit the failing browser regression**

```bash
git add buildbuddy.yaml elixir/web-ng/assets/BUILD.bazel \
  elixir/web-ng/assets/chart_range_selection_acceptance_harness.js \
  elixir/web-ng/assets/chart_range_selection_acceptance.playwright.js \
  elixir/web-ng/assets/chart_range_selection_test_runner.mjs \
  elixir/web-ng/test/playwright/BUILD.bazel \
  elixir/web-ng/test/playwright/chart_range_selection.playwright.js \
  elixir/web-ng/test/playwright/playwright.config.js
git commit -m "test(web-ng): reproduce first chart range drag loss"
```

### Task 2: Stable-root controller ownership

**Files:**

- Modify: `elixir/web-ng/assets/js/hooks/charts/ChartRangeSelectionController.test.js`
- Modify: `elixir/web-ng/assets/js/hooks/charts/ChartRangeSelectionController.js`
- Modify: `elixir/web-ng/assets/js/hooks/charts/ChartRangeSelection.test.js`

**Interfaces:**

- Consumes: existing controller option object with `root`, `svg`, `overlay`, `status`, `buckets`, geometry callbacks, and `emit`.
- Produces: the same public constructor/update/destroy/click-suppression API; pointer-down ownership moves from replaceable `svg` to stable `root` without changing adapter call sites.

- [ ] **Step 1: Add focused failing controller tests**

Add tests whose observable outcomes are emission, cancellation, and cleanup—not listener implementation details:

```js
it("commits the first drag started on a replacement SVG before a compatible update", () => {
  const seams = controllerSeams()
  const controller = new ChartRangeSelectionController(seams.options)
  const replacement = seams.replaceSvgAndOverlay()

  replacement.svg.dispatch(pointer("pointerdown", {clientX: 25, pointerId: 9}))
  controller.update(seams.optionsFor(replacement))
  seams.document.dispatch(pointer("pointerup", {clientX: 75, pointerId: 9}))

  expect(seams.emit).toHaveBeenCalledTimes(1)
  expect(seams.emit).toHaveBeenCalledWith({
    start: "2026-08-29T01:00:00.000000Z",
    end: "2026-08-29T01:01:59.999999Z",
  })
})
```

Also cover: same semantic identity with new geometry commits once; changed intervals cancel and clean document listeners; pointer-up can be the first qualifying sample; a below-threshold gesture leaves click suppression false; destroy removes root/document listeners.

- [ ] **Step 2: Run the focused controller suite and verify RED**

Run:

```bash
bazel test -c opt --config=remote \
  //elixir/web-ng/assets:chart_range_selection_unit_tests \
  --test_output=errors --nocache_test_results
```

Expected: the replacement-SVG first-attempt test FAILS with zero calls to `emit`; all pre-existing tests remain green.

- [ ] **Step 3: Move pointer-start ownership to the stable root**

Change `bind()`/cleanup so the stable root owns all gesture and keyboard listeners:

```js
root.addEventListener("pointerdown", onPointerDown)
root.addEventListener("pointermove", onPointerMove)
root.addEventListener("pointerup", onPointerUp)
root.addEventListener("pointercancel", onPointerCancel)
root.addEventListener("lostpointercapture", onLostPointerCapture)
root.addEventListener("keydown", onKeyDown)

this.cleanup = () => {
  root.removeEventListener("pointerdown", onPointerDown)
  root.removeEventListener("pointermove", onPointerMove)
  root.removeEventListener("pointerup", onPointerUp)
  root.removeEventListener("pointercancel", onPointerCancel)
  root.removeEventListener("lostpointercapture", onLostPointerCapture)
  root.removeEventListener("keydown", onKeyDown)
}
```

Remove the SVG listener registrations. In `update()`, a compatible binding update replaces `this.options`, renders into the current overlay, and retains the active pointer transaction without unbinding the stable root merely because `svg` changed. Keep semantic cancellation for root, event, enabled-state, or ordered interval changes. Keep immediate document tracking on accepted pointer-down and threshold-gated `setPointerCapture` unchanged.

- [ ] **Step 4: Run focused suites and verify GREEN**

Run:

```bash
bazel test -c opt --config=remote \
  //elixir/web-ng/assets:chart_range_selection_unit_tests \
  --test_output=errors --nocache_test_results
```

Expected: PASS with one emission in the replacement case, zero in semantic-cancellation and sub-threshold cases, and no leaked listeners.

- [ ] **Step 5: Commit the shared-controller fix**

```bash
git add elixir/web-ng/assets/js/hooks/charts/ChartRangeSelectionController.js \
  elixir/web-ng/assets/js/hooks/charts/ChartRangeSelectionController.test.js \
  elixir/web-ng/assets/js/hooks/charts/ChartRangeSelection.test.js
git commit -m "fix(web-ng): keep chart range gestures on stable roots"
```

### Task 3: Atomic adapter readiness and renderer regressions

**Files:**

- Modify: `elixir/web-ng/assets/js/hooks/charts/NetflowTrafficTooltip.test.js`
- Modify: `elixir/web-ng/assets/js/hooks/charts/NetflowStackedAreaChart.test.js`
- Modify: `elixir/web-ng/assets/js/hooks/charts/NetflowTrafficTooltip.js` only if its update order fails the readiness test
- Modify: `elixir/web-ng/assets/js/hooks/charts/NetflowStackedAreaChart.js` only if its post-draw handoff fails the readiness test
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/log_live/index.ex`
- Modify: `elixir/web-ng/test/phoenix/live/log_live/netflow_chart_range_components_test.exs`

**Interfaces:**

- Consumes: unchanged controller option contract.
- Produces: initially disabled chart roots that become focusable only after each adapter supplies a complete current binding.

- [ ] **Step 1: Add failing adapter and component readiness tests**

Assert server markup does not advertise an interactive surface before its hook is mounted:

```elixir
assert html =~ ~s(aria-disabled="true")
refute html =~ ~s(tabindex="0")
```

In each hook test, mount with missing/invalid geometry and assert the root remains `aria-disabled`; supply complete geometry/buckets, call the real hook update/draw, and assert `tabindex="0"` and no `aria-disabled`. Replace SVG/overlay with identical intervals during a physical gesture and assert exactly one range push. Keep literal expected timestamps.

Add explicit regression cases proving a sub-threshold Lines/Grid click still emits `netflow_bucket`, a protocol/application click still emits `netflow_stack_series`, and a later independent click is not suppressed.

- [ ] **Step 2: Run adapter/component tests and verify RED**

Run:

```bash
bazel test -c opt --config=remote \
  //elixir/web-ng/assets:chart_range_selection_unit_tests \
  --test_output=errors --nocache_test_results
bazel test -c opt --config=remote //elixir/web-ng:unit_tests_phoenix_live --test_output=errors
```

Expected: the initial-readiness component assertion FAILS because current markup sets `tabindex="0"` before the hook binding is ready. Existing interaction behavior must remain green.

- [ ] **Step 3: Make readiness atomic with the renderer handoff**

Render range-enabled roots initially with `aria-disabled="true"` and without `tabindex="0"`. Let `ChartRangeSelectionController.bind()` set `tabindex="0"` and remove `aria-disabled` only after `normalizeOptions()` confirms root, SVG, overlay, status, valid buckets, emit, and geometry. Ensure D3 calls controller update only after it completes `clearSVG`, draws the current render tree, and creates the current overlay; ensure the server adapter calls update after the LiveView patch has supplied current nodes.

Do not add timers, retries, duplicate hooks, or renderer-specific pointer state.

- [ ] **Step 4: Run all focused hooks plus real Chromium and verify GREEN**

Run:

```bash
bazel test -c opt --config=remote \
  //elixir/web-ng/assets:chart_range_selection_unit_tests \
  --test_output=errors --nocache_test_results
bazel test -c opt --config=remote //elixir/web-ng:unit_tests_phoenix_live --test_output=errors
bazel test -c opt --config=remote \
  //elixir/web-ng/test/playwright:chart_range_selection_acceptance \
  --test_output=errors --nocache_test_results --flaky_test_attempts=1
```

Expected: every target passes. Chromium traces show one first-attempt push for both renderers after node replacement, and click cases show their original action without a range push.

- [ ] **Step 5: Commit adapter readiness and regressions**

```bash
git add elixir/web-ng/assets/js/hooks/charts/NetflowTrafficTooltip.js \
  elixir/web-ng/assets/js/hooks/charts/NetflowTrafficTooltip.test.js \
  elixir/web-ng/assets/js/hooks/charts/NetflowStackedAreaChart.js \
  elixir/web-ng/assets/js/hooks/charts/NetflowStackedAreaChart.test.js \
  elixir/web-ng/lib/serviceradar_web_ng_web/live/log_live/index.ex \
  elixir/web-ng/test/phoenix/live/log_live/netflow_chart_range_components_test.exs
git commit -m "fix(web-ng): enable chart range selection after render"
```

### Task 4: Verification, immutable build, and cluster rollout

**Files:**

- Modify: `openspec/changes/add-netflow-chart-range-selection/tasks.md`
- Modify: deployment state only through the repository's Bazel/demo rollout targets and guarded GitOps flow.

**Interfaces:**

- Consumes: green focused tests and exact feature-branch SHA.
- Produces: immutable `sha-<full-git-sha>` images running on farm01 and CarverAuto demo with recorded exact digests.

- [ ] **Step 1: Run formatting, complete asset, and web-ng gates**

Run:

```bash
bazel test -c opt --config=remote \
  //elixir/web-ng/assets:asset_unit_tests \
  --test_output=errors --nocache_test_results
cd elixir/web-ng
mix format --check-formatted
cd ../..
bazel test -c opt --config=remote //elixir/web-ng:unit_tests --test_output=errors
bazel build -c opt --config=remote //elixir/web-ng/assets:js_bundle
```

Expected: all commands exit 0. Read the output of each command and retain the BuildBuddy invocation URL for Bazel failures or evidence.

- [ ] **Step 2: Run repository-required gates**

Run from the worktree root:

```bash
make lint
make test
```

Expected: both exit 0. Resolve only failures attributable to this branch; report unrelated baseline failures instead of mutating unrelated code.

- [ ] **Step 3: Update OpenSpec task evidence and validate**

Mark tasks 6.1 through 6.6 complete only when their artifacts and outputs exist. Run:

```bash
openspec validate add-netflow-chart-range-selection --strict
git diff --check
```

Expected: strict validation and whitespace check pass.

- [ ] **Step 4: Build and push the immutable image set through Bazel**

Use the repository `demo-local-rollout` skill and Bazel push targets with tag `sha-$(git rev-parse HEAD)`. Do not invoke Docker, Colima, `crane` packaging, or read generated Bazel output paths. Record the registry digest returned for `serviceradar-web-ng` and every copied/published companion image required by the rollout target.

- [ ] **Step 5: Roll farm01 and CarverAuto demo and verify exact artifacts**

Use the guarded farm01 and CarverAuto rollout paths from `demo-local-rollout`. Wait until every workload is Available/Ready, then query running image IDs and fail if either cluster is not running the recorded digest.

On each cluster, use a fresh page for each assertion:

- Lines first drag after mount opens Flow Explorer.
- Grid first drag after mount opens Flow Explorer.
- Stacked and 100% first drag after mount open Flow Explorer.
- Protocol and Application first drag after mount open Flow Explorer.
- One server-SVG and one D3 gesture immediately after redraw open Flow Explorer on the first attempt.
- A one-bucket click and a series click retain their existing actions.
- A later ordinary click is not suppressed.

Every browser check must explicitly fail when the URL does not reach `view=explorer` with one absolute `time:[start,end]` clause. Confirm the gesture began after rollout completion, not while old and new pods were mixed.

- [ ] **Step 6: Complete OpenSpec evidence and commit**

Update tasks 5.3, 5.9, and 6.7 only after both clusters pass against the exact digest. Keep archival for a separate PR after deployment. Commit:

```bash
git add openspec/changes/add-netflow-chart-range-selection docs/superpowers/plans/2026-08-28-chart-range-shared-lifecycle.md
git commit -m "docs(openspec): complete chart range lifecycle evidence"
```
