# MTR Destination Metrics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make every ServiceRadar headline MTR loss and latency metric describe the probed destination, while preserving per-hop MTR diagnostics and making unreached targets explicitly unavailable rather than fabricating endpoint samples.

**Architecture:** Keep raw `mtr_traces` and `mtr_hops` unchanged. A destination sample is the terminal hop (`hop_number = total_hops`) of a trace whose `target_reached` flag is true; this follows the native Go collector, which stops serialization at the target. Aggregate destination loss from probe counters and destination RTT from replies, and keep reachability as a separate trace-count ratio. Dashboard, device, and comparison queries each receive regression coverage because they currently implement independent SQL paths.

**Tech Stack:** Elixir, Phoenix LiveView function components, PostgreSQL/Timescale SQL through `ServiceRadarWebNG.Repo`, ExUnit, Bazel.

**Spec:** Approved product contract from the 2026-08-30 MTR investigation; this is a bug fix restoring Matt's Traceroute semantics, so OpenSpec does not require a change proposal.

## Global Constraints

- Preserve raw per-hop `sent`, `received`, `loss_pct`, RTT, hostname, ECMP, ASN, and MPLS fields and the hop table. Silent or rate-limited transit hops may legitimately show 100% loss.
- Treat a row as a destination sample only when its trace has `target_reached = true` and `hop_number = total_hops`. Never substitute the deepest responding intermediary for an unreached target.
- Compute aggregate destination loss as `100 * SUM(sent - received) / SUM(sent)` over valid destination samples with `sent > 0`.
- Compute aggregate destination RTT as `SUM(avg_us * received) / SUM(received)` over valid destination samples with `received > 0`.
- Compute reachability as `100 * reached_trace_count / attempted_trace_count`. Unreached traces count against reachability but contribute no destination loss or RTT sample.
- Keep attempted trace counts separate from endpoint sample counts so zero loss is distinguishable from unavailable data.
- Device summary cards, trends, and recent bars use the latest 50 matching traces regardless of the history table's current page.
- Use destination terminology for headline values. Keep path-wide maxima explicitly labeled as hop diagnostics.
- Add a failing regression test before each production-code change. Database tests run against the isolated `srql-fixtures` scratch CNPG database; DB-free component tests carry `@moduletag :db_free`.
- Do not add migrations, tables, dependencies, scripts, or direct metric writes.

---

### Task 1: Make recent device observations destination-aware

**Files:**

- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/diagnostics_live/mtr_data.ex`
- Modify: `elixir/web-ng/test/serviceradar_web_ng_web/live/diagnostics_live/mtr_data_test.exs`

**Step 1: Write failing data-layer tests**

Add fixtures covering:

- a reached trace with a 100%-loss silent transit hop followed by a responsive destination;
- a second reached trace with partial destination response;
- an unreached trace whose deepest responding intermediary has high RTT;
- at least 51 ordered traces so a caller can prove a fixed latest-50 window.

Assert that `list_traces/1` returns destination counters/RTT only for reached terminal hops, that the unreached trace has no destination sample, and that `build_trends/1` never includes intermediary RTT.

Run the focused test and record the expected pre-fix failures:

```bash
cd elixir/web-ng
MIX_ENV=test mix test test/serviceradar_web_ng_web/live/diagnostics_live/mtr_data_test.exs
```

**Step 2: Attach destination observations to bounded trace rows**

Change `list_traces/1` to select the bounded newest traces in a CTE, then left-join only `target_reached` terminal hops. Return these additional string-keyed columns:

- `destination_sent`
- `destination_received`
- `destination_avg_us`
- `destination_loss_pct`, derived from `sent` and `received`, not the stored percentage

Rows without a valid destination sample must keep these values `nil`.

**Step 3: Make trends use endpoint observations**

Change `build_trends/1` to build latency from `destination_avg_us` on the supplied rows. Remove the deepest-responsive-hop lookup and its private SQL helper. Keep the existing hop-depth trend.

**Step 4: Verify and commit**

Run the focused test, `mix format` on touched files, and commit as `fix(mtr): expose destination observations for recent traces`.

---

### Task 2: Stabilize and relabel the device MTR summary

**Files:**

- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/device_live/mtr_runtime.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/device_live/device_mount_assigns.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/device_live/show_template.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/device_live/mtr_components.ex`
- Modify: `elixir/web-ng/test/phoenix/live/device_live_test.exs`
- Create: `elixir/web-ng/test/phoenix/live/device_live/mtr_components_test.exs`

**Step 1: Write failing LiveView and component tests**

Update the existing mixed two-trace device MTR test to expect 50.0% reachability and destination RTT from the reached target only. Add a 51-trace pagination test: when page 2 displays the oldest unreachable 900 ms trace, the cards and charts must still describe the newest 50 reached 10 ms traces.

Add a DB-free `render_component/2` test for the detail modal with a 100%-loss silent intermediate hop and a zero-loss destination. Assert `Destination Loss` is 0.0%, `Max Hop Loss` is 100.0%, and an unreached trace renders destination loss as `-`.

Run the focused tests and capture the expected pre-fix failures:

```bash
cd elixir/web-ng
MIX_ENV=test mix test test/phoenix/live/device_live_test.exs test/phoenix/live/device_live/mtr_components_test.exs
```

**Step 2: Load a stable recent window**

In `MtrRuntime.load_traces/2`, keep `mtr_traces` as the requested table page, and separately call `MtrData.list_traces/1` with `limit: 50` for `mtr_recent_traces`. Build trends from the recent rows. Initialize and pass the new assign through mount and template code. Pending-job suppression may use the recent rows because they are the newest completions.

**Step 3: Correct summary arithmetic and labels**

Derive cards and recent bars from `mtr_recent_traces`, not the paginated table rows. Calculate:

- reachability as reached count divided by attempted count;
- destination loss by summing destination lost/sent probes;
- destination RTT by weighting `destination_avg_us` by `destination_received`;
- endpoint sample count independently.

Rename `Avg Last-Hop Latency` to `Destination Latency`, add a `Destination Loss` card, and show `-` when no endpoint sample exists. Retain `Avg Hop Depth` as path context. Add stable DOM IDs for the reachability, destination-latency, destination-loss, and recent-sample regions.

**Step 4: Correct modal semantics without hiding hop behavior**

Pass the trace to `mtr_hop_dashboard/2`. Derive modal destination loss from the reached terminal hop's counters. Rename `Avg Loss` to `Destination Loss`, `Peak Avg RTT` to `Peak Hop Avg RTT`, and `Most Lossy Hop` to `Max Hop Loss`. Keep the per-hop loss table and bars unchanged.

**Step 5: Verify and commit**

Run the focused tests, `mix format` on touched files, and commit as `fix(mtr): stabilize device destination metrics`.

---

### Task 3: Correct dashboard headline metrics and sparklines

**Files:**

- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/dashboard_live/data/mtr.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/dashboard_live/data/service_sparklines.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/dashboard_live/data/states_cards.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/dashboard_live/data/empty_defaults.ex`
- Create: `elixir/web-ng/test/phoenix/live/dashboard_live/mtr_metrics_test.exs`

**Step 1: Write a failing weighted-aggregation regression**

Insert three traces in one sparkline bucket:

- reached A: transit 10/1 at 900 ms, destination 10/10 at 10 ms;
- reached B: transit 20/20 at 5 ms, destination 20/5 at 40 ms;
- unreached C: intermediary 30/30 at 800 ms and silent terminal 30/0.

Assert both `DashboardLive.Data.load_mtr/1` and `load_sparklines/1` report destination loss 50.0% and reply-weighted destination RTT 20.0 ms. Assert `path_count` is 3, `endpoint_sample_count` is 2, and the unreached trace degrades reachability without becoming an endpoint sample.

Run the focused test and record the current all-hop/deepest-responder failure:

```bash
cd elixir/web-ng
MIX_ENV=test mix test test/phoenix/live/dashboard_live/mtr_metrics_test.exs
```

**Step 2: Rewrite the dashboard summary CTEs**

Select `target_reached` and `total_hops` with traces. Join destination hops only under the global terminal-hop rule. Return weighted loss, weighted RTT, and `endpoint_sample_count`. Count a trace as degraded when it is unreached or its destination sample has loss above 0% or RTT above 100 ms.

The overlay-only fallback cannot prove destination identity, so it must expose `endpoint_sample_count: 0`; it may continue to describe path overlays only when no Timescale trace data exists.

**Step 3: Rewrite per-bucket sparkline aggregation**

Join `mtr_traces` to terminal destination hops and use the same counter/reply weighting in each bucket. Omit buckets with no destination denominator rather than emitting a false zero.

**Step 4: Relabel dashboard cards**

Rename headline labels to `Destination Latency` and `Destination Loss`. Base availability on `endpoint_sample_count`; when paths exist but endpoints do not, render `No endpoint sample` rather than 0 ms / 0%.

**Step 5: Verify and commit**

Run the focused test, `mix format` on touched files, and commit as `fix(mtr): use destination metrics on dashboard`.

---

### Task 4: Correct diagnostics window comparisons

**Files:**

- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/diagnostics_live/mtr_data.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/diagnostics_live/mtr_compare.ex`
- Modify: `elixir/web-ng/test/serviceradar_web_ng_web/live/diagnostics_live/mtr_data_test.exs`
- Modify: `elixir/web-ng/test/phoenix/live/diagnostics_live/mtr_compare_test.exs`

**Step 1: Write failing comparison regressions**

Use reached traces with silent/high-loss intermediates and a responsive terminal target, plus an unreached trace with a high-latency intermediary. Assert window summaries expose `endpoint_sample_count`, reply-weighted destination RTT, and probe-weighted destination loss. Add an empty-endpoint window case whose metric and delta values are unavailable rather than zero.

Assert the rendered comparison labels are `Destination Latency` and `Destination Loss`.

**Step 2: Replace all-hop and deepest-responder window SQL**

Use the global terminal-hop rule in `window_summary/2`. Return nullable `avg_destination_us` and `destination_loss_pct` plus `endpoint_sample_count`. Preserve attempt, reachability, hop-depth, agent, and target counts.

Update `window_deltas/2` so destination deltas are `nil` whenever either window lacks an endpoint denominator. Add a nullable rounding helper rather than converting missing values to 0.0.

**Step 3: Update comparison presentation**

Render `-` for unavailable destination values and deltas. Rename all labels and internal assigns that still imply last-responsive-hop latency or all-hop average loss.

**Step 4: Verify and commit**

Run both focused test files, `mix format` on touched files, and commit as `fix(mtr): compare destination metrics by window`.

---

### Task 5: Cross-surface verification

**Files:**

- Modify only if verification exposes a defect in Tasks 1-4.

**Step 1: Run focused Elixir contracts**

With the isolated scratch database environment active:

```bash
cd elixir/web-ng
MIX_ENV=test mix test \
  test/serviceradar_web_ng_web/live/diagnostics_live/mtr_data_test.exs \
  test/phoenix/live/diagnostics_live/mtr_compare_test.exs \
  test/phoenix/live/dashboard_live/mtr_metrics_test.exs \
  test/phoenix/live/device_live/mtr_components_test.exs \
  test/phoenix/live/device_live_test.exs
mix precommit
```

**Step 2: Run repository verification**

From the worktree root, with `.bazelrc.remote` and `.bazelrc.local` linked from the primary checkout:

```bash
make test
make lint
```

Read the actual summaries and preserve an explicit nonzero exit path; a command merely starting is not verification.

**Step 3: Verify the live UI read-only**

Use the `demo-cnpg-local-web-ng` workflow to run this worktree's web-ng against demo CNPG. Inspect the dashboard MTR cards, a device MTR tab, and diagnostics comparison with Playwright. Confirm unreachable traces do not display intermediary RTT or fabricated 0% destination loss, and that changing device history pages does not change the latest-50 summary.

**Step 4: Final review**

Request a whole-branch code review against `origin/staging`. Resolve review findings, rerun covering tests for any fix, and leave the worktree on the feature branch without pushing to `staging`.
