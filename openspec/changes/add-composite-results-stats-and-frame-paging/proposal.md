# Change: Aggregate composite results in SRQL and page dashboard frames

## Why

Dashboard packages that visualise composite checks cannot tell the truth on a
fleet-sized deployment. `in:composite_results` is one row per
`(device_uid, check)`. FrameRunner clamps every frame (`@max_frame_limit`,
currently 2_000; a parallel spike to 100_000 is not the architecture). A 28,000
device check therefore arrives as a truncated sample. The renderer then
**counts in the browser**, so every tile, bar, and "N down" figure is a count
of the sample, not of the fleet.

Two host facts make raising the clamp the wrong fix:

1. **`stats:` is parsed and ignored.** `composite_results.rs` never reads
   `plan.stats`. `in:composite_results stats:count() as n by verdict` returns
   plain rows. `add-composite-service-checks` already required "count devices
   per verdict" (`specs/srql` delta, Requirement: Composite Results Entity)
   and did not specify syntax; the entity shipped without an aggregation path.
2. **SRQL already paginates.** `QueryEngine.build_pagination/2` mints
   `next_cursor` / `prev_cursor`. FrameRunner copies `pagination` onto the
   frame (`frame_runner.ex:160`) and then never passes a cursor back in
   (`srql_module.query(query, %{scope, limit})` at `:150`). Trusted modules
   have `api.srql.update` (replace the query, remount-adjacent) and no page
   call.

The customer Armis composite dashboard (`com.example.armis.composite`) is the
package that hit this; the hole is in the host, not in that package.

## What Changes

- **SRQL `in:composite_results` honours `stats:`.** `count()` grouped by
  `check` / `check_slug` / `check_name` / `verdict` / `status`, including
  combinations (`by check, verdict`). Unsupported aggregations and group
  fields **error** rather than returning a truncated row dump.
  **BREAKING** for any caller that today issues `stats:` on this entity and
  depends on receiving plain rows. That behaviour is a silent lie; it has no
  supported consumer.
- **Vantage-point rollup via jsonb unnest.** `stats:count() as n by
  input_key, input_value` (optional `input_stale`) compiles to
  `CROSS JOIN LATERAL jsonb_each(inputs)` so the vantage-points view is a
  GROUP BY, not a client fold over 28k snapshots.
- **FrameRunner passes the SRQL cursor it already returns.** A new
  `dashboard_frame_page` LiveView event / host API `api.srql.page(frameId,
  cursor)` re-runs **one** frame with `{scope, limit, cursor}` and pushes
  `frames:replace` for that id. Query text is unchanged; the cursor resets
  when `api.srql.update` changes the query.
- **SDK** (`@carverauto/serviceradar-dashboard-sdk`): `SrqlClient.page`,
  `build` grows an optional `cursor` is **not** a query-string token (cursors
  stay request metadata, matching `Native.translate/5`), and React gets
  `useDashboardFramePagination`.
- **Row-frame page size stays modest.** Default 500, hard cap remains the
  FrameRunner max. Device-table pages that also resolve hostnames via
  `in:devices uid:(…)` MUST stay at ≤ `MAX_FILTER_LIST_VALUES` (200,
  `parser/filters.rs:3`) because that is the IN-list cap.

## Non-goals

- Raising `@max_frame_limit` to 50k/100k as the way fleet dashboards work.
  A higher cap can remain an operator escape hatch; it is not this design.
- `in:composite_checks` (the check catalogue). Check identity for rollups
  comes from the join that already aliases `check_slug` / `check_name`.
- Adding `hostname` onto `CompositeResultRow`. Hostname stays a second frame
  scoped to the current page's uids.
- Infinite-scroll accumulation of every device row in the renderer.
- Changing northbound Armis export, evaluation, or the composite check
  authoring UI.
- Rewriting the customer Armis dashboard package in this repo. Consumption is a
  follow-up in `serviceradar-armis-dashboards` once this host contract ships.

## Impact

- Affected specs: `srql`, `dashboard-packages` (new capability for the
  runtime host/frame ABI)
- Affected code:
  - `rust/srql/src/query/composite_results.rs` (+ stats module, tests in
    `query/tests/entity_examples.rs`)
  - `elixir/web-ng/lib/serviceradar_web_ng/dashboards/frame_runner.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/dashboard_package_live/show.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/channels/dashboard_frame_channel.ex`
  - `elixir/web-ng/assets/js/hooks/DashboardWasmHost.js`
  - `@carverauto/serviceradar-dashboard-sdk` (`src/srql.js`, `src/react.js`)
- Related open change: `add-composite-service-checks` (unarchived). This
  change supplies the aggregation contract that change named but did not
  implement.
- Follow-up (other repo): `com.example.armis.composite` switches breakdown /
  vantage to stats frames and the device table to paged `api.srql.page`.
