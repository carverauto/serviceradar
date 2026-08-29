# Integrated review fix report

Date: 2026-08-28

Reviewed base SHA: `ae526f70e8edcbc9e7b7672409b47d8eb85fdf50`

Result commit: the commit containing this report, with subject
`fix(web-ng): close chart range rollout gaps`. The concrete commit SHA is
recorded in the task handoff because a commit cannot embed its own hash.

## Scope and root cause

This pass closed the three pre-rollout whole-branch findings without changing
the controller's public API or adding a renderer-specific gesture path.

The runtime defect was in the two compatible-gesture early returns in
`ChartRangeSelectionController.update()`. Both replaced `this.options` and
preserved the pending or active transaction, but neither called
`restoreEnabledReadiness()`. A LiveView patch that reapplied
`aria-disabled="true"` and removed `tabindex` therefore remained visible after
an otherwise compatible handoff.

Production click arbitration was verified in both chart hooks: the arbiter is
registered on the chart root in capture phase. The acceptance harness now
recognizes the closest `[phx-click]` action at `document` bubble phase, using
the production `phx-click`, `phx-value-start`, and `phx-value-end` attributes.
A focused stop-propagation control proves the action trace cannot be produced
before the click reaches `document`.

## RED evidence

Before editing controller production code:

```text
bazel test -c opt --config=remote //elixir/web-ng/assets:chart_range_selection_unit_tests --test_output=errors --nocache_test_results
```

- BuildBuddy invocation: `3e94ab8c-cb4d-45db-bc26-3d65c637b07f`
- Result: failed for the expected behavioral reason.
- Failures: both new compatible-handoff tests received
  `aria-disabled="true"` where no attribute was expected.
- The remaining 67 focused tests passed.
- An earlier sandbox-only Bazel output-base failure was rejected as RED
  evidence and is not counted.

## GREEN and integration evidence

Focused controller and adapter suite:

```text
bazel test -c opt --config=remote //elixir/web-ng/assets:chart_range_selection_unit_tests --test_output=errors --nocache_test_results
```

- BuildBuddy invocation: `87c939e8-34bc-4be7-ac2a-21725df6e635`
- Result: passed.

Real Chromium acceptance suite:

```text
bazel test -c opt --config=remote //elixir/web-ng/test/playwright:chart_range_selection_acceptance --test_output=errors --nocache_test_results --flaky_test_attempts=1
```

- BuildBuddy invocation: `dc21ef04-9b73-412d-b089-7b847500bf87`
- Result: passed, including both renderer families, delegated server action
  acceptance, and the propagation-stop control.

Complete asset unit suite:

```text
bazel test -c opt --config=remote //elixir/web-ng/assets:asset_unit_tests --test_output=errors --nocache_test_results
```

- BuildBuddy invocation: `3846eddb-e624-4e29-b21b-82306e2405e2`
- Result: passed.

Production bundle:

```text
bazel build -c opt --config=remote //elixir/web-ng/assets:js_bundle
```

- Result: passed.
- The captured Bazel build output did not emit a BuildBuddy invocation ID.

Whitespace verification:

```text
git diff --check
```

- Result: passed before report creation and rerun after staging.

## Bun lock reproducibility

Installed Bun: `1.3.9` (`cf6cdbbb`).

The required best-effort Socket Firewall command was attempted first:

```text
sfw bun install --lockfile-only --ignore-scripts
```

The initial sandboxed attempt could not prepare Socket Firewall's user cache.
Two approved retries reached `Resolving dependencies` but made no progress and
wrote no files; both were interrupted at bounded cutoffs. The repository guide
explicitly treats Socket Firewall support for Bun as best-effort, so the same
plain Bun lockfile-only command was used as the fallback:

```text
bun install --lockfile-only --ignore-scripts
```

Output: `Saved bun.lock (695 packages) [193.00ms]`; exit 0. The exact lock diff
was one insertion in the root workspace dependency map:

```text
"d3-scale": "^4.0.2",
```

Frozen verification:

```text
bun install --lockfile-only --ignore-scripts --frozen-lockfile
```

Output: `Saved bun.lock (695 packages) [4.00ms]`; exit 0. No `node_modules`
directory existed before or after either successful Bun command.

## Files changed

- `elixir/web-ng/assets/js/hooks/charts/ChartRangeSelectionController.js`
- `elixir/web-ng/assets/js/hooks/charts/ChartRangeSelectionController.test.js`
- `elixir/web-ng/assets/chart_range_selection_acceptance_harness.js`
- `elixir/web-ng/assets/chart_range_selection_acceptance.playwright.js`
- `elixir/web-ng/assets/bun.lock`
- `.superpowers/sdd/2026-08-28-chart-range-shared-lifecycle/integrated-review-fix-report.md`

## Self-review

- Both compatible branches invoke the same readiness helper already used by
  unchanged updates and initial binding; no public API or adapter contract
  changed.
- Pending and active tests prove readiness restoration, one root listener,
  retained pointer state/capture, and exactly one final emission.
- Semantic incompatibility, strict geometry, threshold-gated capture, click
  suppression, keyboard, touch, and renderer behavior remain on the existing
  shared controller paths and stay covered by the focused/full suites.
- Server action acceptance is observed only after native bubbling reaches
  `document`; no target-specific listener or fake Phoenix gesture exists.
- Bun 1.3.9 produced no unrelated lock churn and did not install packages.
