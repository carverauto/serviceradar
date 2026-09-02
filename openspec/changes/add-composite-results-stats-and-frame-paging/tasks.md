## 1. SRQL `composite_results` stats

- [x] 1.1 Add a stats builder next to `composite_results.rs` (count only; group
      fields `check`/`check_slug`/`slug`, `check_name`, `verdict`, `status`,
      `input_key`, `input_value`, `input_stale`). Reuse the jsonb_build_object
      payload shape from `devices/stats`.
- [x] 1.2 `to_sql_and_params/1` and `execute/2` branch on `plan.stats`: grouped
      SQL when present, existing row SELECT when absent. Bind-count assertion
      stays on both paths.
- [x] 1.3 `input_*` group fields compile `CROSS JOIN LATERAL jsonb_each(inputs)`.
      Empty/NULL `inputs` contribute no vantage rows.
- [x] 1.4 Unsupported aggregation or group field returns `InvalidRequest` (no
      silent row fallback).
- [x] 1.5 Grouped stats default limit 100, hard cap 500, independent of
      FrameRunner's row clamp.
- [x] 1.6 Filters (`check`, `verdict`, `status`, `device_uid`, `time`) apply
      before GROUP BY, same as the row query.
- [x] 1.7 Tests in `rust/srql/src/query/tests/entity_examples.rs`:
      - `stats:count() as n by check, verdict` SQL contains GROUP BY and
        aliases `check` (not `slug`)
      - `by input_key, input_value` contains `jsonb_each`
      - `stats:count() as n by hostname` errors
      - `stats:sum(bytes) as n by verdict` errors
      - bind-count matches params
      - Rust `execute` JSON keys match Elixir column/payload keys

## 2. FrameRunner cursor pass-through

- [x] 2.1 `FrameRunner.run_json_frame/7` and the Arrow path pass
      `cursor` from the frame map / opts into `srql_module.query/2` and
      `query_arrow/2`.
- [x] 2.2 Keep copying `pagination` onto the frame. A full page (`row_count ==
      limit`) MUST include `pagination.next_cursor` when SRQL minted one.
- [x] 2.3 Tests in `frame_runner_test.exs` (`:db_free`): fake SRQL records the
      cursor it was given; a frame with `"cursor" => "abc"` forwards it; a
      frame without a cursor does not send one.

## 3. Dashboard host page ABI

- [x] 3.1 Paging is a channel event (`frames:page`), not a LiveView
      `push_patch`. The URL and query string stay put; the renderer stays
      mounted.
- [x] 3.2 `DashboardFrameChannel` accepts `frames:page` with `frame_id` +
      `cursor`, re-runs that frame through FrameRunner, merges into
      `last_frames`, and pushes `frames:replace`.
- [x] 3.3 `DashboardWasmHost.js` `createSrqlApi` grows `page(frameId, cursor)`
      gated on `srql.execute`. Invalid / missing cursor throws, not a query
      replace.
- [x] 3.4 `frames:refresh` clears stored cursors. `api.srql.update` remints
      the stream token (query-string patch), so a new channel join starts at
      offset 0.
- [x] 3.5 Host hook tests (`DashboardWasmHost.test.js`) cover page vs update.

## 4. Dashboard SDK

- [ ] 4.1 `SrqlClient.page(frameId, cursor)` in `src/srql.js` + `.d.ts`.
      Host `api.srql.page` is live; SDK wrap is a follow-up in
      `carverauto/serviceradar-sdk-dashboard` (packages can call the host
      API via `useDashboardApi()` today).
- [ ] 4.2 `useDashboardFramePagination(frameId)` in `src/react.js` reading
      `frame.pagination.{next_cursor,prev_cursor,limit}`.
- [ ] 4.3 Feature-detect (`typeof api.srql.page === "function"`) so packages
      built against this SDK still run on a host that has not deployed yet.
- [ ] 4.4 README: stats frames vs paged row frames; hostname via
      `in:devices uid:(…)` with page size ≤ 200; do not put `cursor:` in the
      query string.
- [ ] 4.5 Publish a minor of `@carverauto/serviceradar-dashboard-sdk`.

## 5. Docs and follow-up

- [x] 5.1 CHANGELOG: `in:composite_results` `stats:` is honoured; previously
      ignored `stats:` on this entity is **BREAKING**.
- [x] 5.2 Developer portal / dashboard-sdk docs: paging ABI, stats examples
      (`by check, verdict`, vantage unnest).
- [ ] 5.3 Do **not** rewrite `com.example.armis.composite` in this repository.
      File a follow-up in `serviceradar-armis-dashboards` once 4.5 is on npm:
      stats frames for breakdown + vantage, paged results + uid-scoped
      devices frame, drop the 2_000-row ceiling banner for hosts that page.
