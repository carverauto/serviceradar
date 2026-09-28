## Context

#4629 landed on `staging` as `25cc841071`. `Device.read` and the paginated `PrefixTag` reads now declare `default_limit: 250` and `max_page_size: 1_000_000_000`. Ash's default maximum of 250 no longer clamps those actions, and `more?` matches the page that was actually requested. `Ash.stream!/2` is how the fence, device lookup, the MTR baseline, and the AWX reconciler already read a full set.

`ServiceRadar.Ash.Page.unwrap/1` still throws away `more?`. A bare `Ash.read` of `Device.read` still returns one default page of 250. Every caller that unwraps that page and continues has the same defect as before, only now the lie is in the caller rather than in Ash.

SRQL is a separate mechanism. `srql_max_limit` defaults to unlimited. The 500 in the Rust tests is a fixture. What production does enforce:

- no `limit:` becomes `LIMIT 100`
- the request limit wins over a `limit:` token in the query string, and LiveView pages clamp that request (devices and logs at 100)
- grouped device stats compile an explicit limit down to 100, and omit a truncation flag
- other grouped stats clamp at 500
- ordinary cursors stop at `srql_max_cursor_offset` (100_000) with an error
- logs with no `time:` are given the last 24 hours

Issue #4632 separates those from honest top-N widgets and from `LIMIT 1` scalar lookups.

## Goals / Non-Goals

- Goals:
  - A caller that needs every matching row either receives every row or fails visibly.
  - An explicit limit is the limit that runs.
  - A partial page that is not the end of the set is distinguishable from the end.
  - Regression tests use a batch larger than one default page, so a small fixture cannot go green.
- Non-Goals:
  - Raising `max_page_size` on telemetry resources, or copying the test value 500 into `SRQL_MAX_LIMIT`. A larger finite ceiling moves the cliff.
  - Changing interactive page sizes (device list 20/100, log list 20/100, dashboard table "Showing first N of M").
  - Removing the select-all refusal above 10_000 devices. That path errors. It does not apply a silent subset. Streaming bulk actions are a later change.
  - Reworking `LIMIT 1` scalar lookups.
  - The 48-bucket hourly trend, alert cards of 8, BGP top 20, and MTR hop top 20. Those are top-N views.
  - Implementing the JSONB group-by work in `add-srql-jsonb-group-by`. This change only stops that delta from re-declaring a hard maximum of 100.

## Decisions

- Decision: completeness for internal device reads is `Ash.stream!/2` or an explicit loop on `more?`, at a batch size at or below the action's default page. Do not pass `page: [limit: length(batch)]` and assume the batch fits. That assumption is what the fence used when it thought the cap was 5_000.
  - Alternatives considered: set every read to `max_page_size: 1_000_000_000` and keep single-page callers. Rejected. One page of devices is a large JSONB row, and a caller that forgets to ask still gets 250 and discards `more?`.

- Decision: grouped stats keep the omitted-limit default (20 groups for devices). An explicit `limit:` is compiled as requested. When the returned groups are not the full grouping, the response sets a truncation indicator. Silently compiling `limit:101` to `LIMIT 100` is forbidden.
  - Alternatives considered: uncap group-by entirely and always return every group. Rejected for interactive charts. The bug is the silent reduction, not the existence of a default page.

- Decision: window-coverage jobs page inside the job. Netflow exporter discovery, interface-pair refresh, threat-candidate refresh, GeoIP of observed flow IPs, capacity history, seasonal baselines, and hostile-flow exposure continue until the window is exhausted. They do not stop at 5_000, 10_000, 20_000, or 50_000 because that constant was a comfortable batch for a small lab.
  - The 50_000-point capacity and seasonal queries are the sharp case: `sort:timestamp:desc limit:50000` keeps the newest points across every series, so most series never enter the model. The read has to be per series, or paged until each series in scope is represented across its horizon.
  - IP enrichment's existing spec already says a newly seen flow IP is enriched. The top-200-by-bytes query does not implement that. This change makes the job walk the uncached set. It does not turn the dashboard into a dump of every IP.

- Decision: the interactive cursor ceiling stays for ordinary SRQL. Jobs that must finish a window use a server-side page loop that is allowed to continue, the same way exhaustive `profile_hour_of_week` queries already bypass `srql_max_cursor_offset`. They must not reuse the interactive ceiling and then treat the error as an empty tail.

- Decision: `add-srql-jsonb-group-by` is edited in this change so its `MODIFIED` copy of device group-by no longer says "a maximum of 100". Archiving that change after this one would otherwise replay the cap over `openspec/specs/srql/spec.md`. The archive copies under `openspec/changes/archive/` are left alone.

## Risks / Trade-offs

- Streaming a large device match holds the work in the caller. Batch size stays modest (the existing 250 default) so a million-row identity pass does not materialize as one query. Memory risk moves to the caller's accumulator; each site must stream into its existing per-batch work, not `Enum.to_list` the estate.
- A truthful `more?` on a page the caller ignores is still a silent bug. Tests have to exceed one page. A declaration check cannot see it. #4629's contract test stays; it is not sufficient.
- Honoring large explicit group limits can make a chart query heavier. The UI clamp for interactive pages stays. The engine stops lying when a caller asked for more.
- Paging netflow cache refresh lengthens the maintenance job. The job already reschedules. A partial refresh that reports success is the worse failure.

## Migration Plan

No schema migration. Deploy the readers and the SRQL planner together. Rollback is a revert of the callers; the #4629 page-size declarations stay.

## Open Questions

- None that block the proposal. Bulk select-all above 10_000 stays a visible error until a separate change streams the bulk action.
