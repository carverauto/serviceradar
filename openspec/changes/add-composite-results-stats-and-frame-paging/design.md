# Design: Composite-results aggregation and dashboard frame paging

## Context

`in:composite_results` (`rust/srql/src/query/composite_results.rs`) is a
first-class entity: `device_composite_check_results INNER JOIN composite_checks`,
projected as ten columns with `check_slug` / `check_name` SQL aliases so the
Rust struct path and the Elixir column-name path agree
(`composite_results_aliases_the_joined_check_columns`).

Web-ng never talks to the Rust query engine over HTTP. It translates via the
NIF (`ServiceRadarSRQL.Native.translate/5`, which already accepts `cursor`)
and runs the SQL through Ecto (`srql.ex:132-146`). FrameRunner is the only
dashboard consumer:

```
srql_module.query(query, %{scope: scope, limit: limit})
```

`limit` is clamped (`frame_runner.ex` `@max_frame_limit`). `cursor` is not
passed. `pagination` from the SRQL response is copied onto the frame and
ignored by every renderer, including the SDK.

`plan.stats` is populated by the parser for
`in:composite_results stats:count() as n by verdict`. `build_query/1` never
reads it, so the NIF emits a bounded SELECT of plain rows. That is the
bug `add-composite-service-checks` left open: "countable by status" with no
syntax and no GROUP BY.

The customer Armis dashboard (`serviceradar-armis-dashboards`) currently declares
two frames, both `limit:2000`, and rolls up in the browser. On a 28k-device
check the counts are a sample. Raising the clamp ships tens of megabytes of
`inputs` jsonb over the dashboard channel every 15s (`refresh_interval_ms`
is hardcoded to 15_000 in `show.ex` host payload) into a 2Gi web-ng pod.

## Goals / Non-Goals

**Goals**

- Fleet-accurate verdict / status / check counts from a GROUP BY, not from
  a truncated row frame.
- Fleet-accurate vantage-point counts (input key × value × stale) without
  shipping every `inputs` snapshot.
- A device table that pages through **all** matching rows, with hostnames
  resolved for the current page only.
- A host ABI trusted modules can use without minting a new query string per
  page (cursors stay request metadata, as they are for every other SRQL
  entity).

**Non-Goals**

- Dumping the fleet into the renderer.
- `in:composite_checks`.
- Joining `ocsf_devices` into `CompositeResultRow`.
- Changing `@max_frame_limit` as the primary lever.
- Rewriting customer dashboard packages in this repository.

## Decisions

### D1 — `stats:` is the aggregation path; silent ignore is a bug

`count()` is the only aggregation in v1. Group fields, with aliases:

| token | column | response key |
| --- | --- | --- |
| `check`, `check_slug`, `slug` | `composite_checks.slug` | `check` |
| `check_name` | `composite_checks.name` | `check_name` |
| `verdict` | `device_composite_check_results.verdict` | `verdict` |
| `status` | `device_composite_check_results.status` | `status` |
| `input_key` | `jsonb_each.key` | `input_key` |
| `input_value` | `(jsonb_each.value->>'value')` | `input_value` |
| `input_stale` | `((jsonb_each.value->>'stale')::boolean)` | `input_stale` |

Combinations are legal (`by check, verdict`, `by check, input_key, input_value`).
`input_*` fields require the jsonb unnest; using them without the others
still unnests. Mixing `input_*` with a non-input field is legal (the join
to `composite_checks` is already there).

Unsupported `stats:` (e.g. `sum(bytes)`, `by hostname`, `by inputs`)
returns `InvalidRequest`. This is **BREAKING** versus today's ignore. There
is no supported consumer of the ignore.

Shape matches device grouped stats: one JSON object per group, alias as the
count key, ordered by count descending. Default group limit 100, hard cap
500 — plenty for checks × verdicts, small enough that a stats frame is not
a row dump. `plan.limit` still applies; FrameRunner's clamp is then
irrelevant for these frames.

SQL sketch (count by check, verdict):

```sql
SELECT jsonb_build_object(
         'check', composite_checks.slug,
         'verdict', device_composite_check_results.verdict,
         'n', COUNT(*)
       ) AS payload
FROM device_composite_check_results
INNER JOIN composite_checks
  ON composite_checks.id = device_composite_check_results.check_id
WHERE …filters…
GROUP BY composite_checks.slug, device_composite_check_results.verdict
ORDER BY COUNT(*) DESC
LIMIT $n
```

Elixir reads `payload` the same way device stats does
(`devices/stats.rs` `jsonb_build_object` + `DeviceStatsPayload`). Do not
invent a second deserialization path. The Rust `execute/2` engine path
(standalone SRQL service) must emit the same objects so the two consumers
do not diverge the way bare `slug` vs `check_slug` once did.

Filters (`check:`, `verdict:`, `status:`, `device_uid:`, `time:`) apply
**before** GROUP BY, identical to the row query's `apply_filter`.

### D2 — Vantage rollup is jsonb_each, not a new entity

`inputs` is
`key -> {value, observed_at, stale, reason}`
(`Evaluation.snapshot/1`). The vantage-points view needs counts per
`(check, input_key, input_value)` plus a stale tally. Unnest:

```sql
CROSS JOIN LATERAL jsonb_each(device_composite_check_results.inputs) AS input(key, value)
```

`input_stale` is a group field, not a filter, so a renderer can stack
stale vs fresh without a second query. Filtering `input_key:dfw_edge` is
out of v1 (would need a jsonb filter in `apply_filter`); the breakdown
always groups.

Empty `inputs` (`{}` or NULL) contributes no vantage rows. That matches
today's client rollup (`parseInputs` returns `[]`).

### D3 — Cursors stay request metadata; `api.srql.page` is the ABI

Do **not** add `cursor:<token>` to the SRQL grammar. `QueryAst` has no
cursor field; `QueryRequest.cursor` is how every entity pages
(`plan.rs:33-48`). The NIF already takes it (`Native.translate/5`).

Host additions:

1. **FrameRunner** accepts `cursor` on the frame map and on `opts`, and
   passes `%{scope, limit, cursor}` into `srql_module.query/2`. Arrow path
   too (`query_arrow/2` already has the arity).
2. **LiveView** `handle_event("dashboard_frame_page", %{"frame_id",
   "cursor"}, socket)` re-runs **that frame only** with the cursor,
   `push_event` / channel `frames:replace` for the one id. It does **not**
   `push_patch` the URL. Paging is not a new saved query.
3. **DashboardWasmHost** exposes `api.srql.page(frameId, cursor)` gated on
   `srql.execute` (already in the package capability allow-list).
4. **SDK** `createSrqlClient` grows `page`. React:
   `useDashboardFramePagination(frameId)` reads `frame.pagination` and
   returns `{next, prev, page(cursor)}`.

When `api.srql.update` fires, cursors drop. The new query is offset 0.

`keep_host_mounted?` in `show.ex:45-48` already avoids remounting on
query-string patches. `dashboard_frame_page` must not set `load_state` to
`:loading`.

Signed cursors (`pagination.rs`) remain the only way to name an offset.
Renderers cannot pass raw `offset:`. That keeps the public cursor cap
(`srql_max_cursor_offset`, default 100_000) in force, which is the right
guard now that a dashboard can actually page.

### D4 — Device table page size 200, hostname via a second frame

`MAX_FILTER_LIST_VALUES` is 200 in the parser. A page of results plus

```
in:devices uid:(uid1,uid2,…) limit:200
```

is how hostnames resolve without a 28k device frame. The results frame
declares `limit:200` (or ≤200). Going above 200 without a join on
`ocsf_devices` would silently drop hostnames for the tail of the page.

Do not raise the list cap in this change. If a later change joins
hostname onto `composite_results`, the page size can grow independently.

Sort for a stable page: `sort:device_uid:asc` (already a recognised order
field). Default `evaluated_at DESC` is fine for a "recently evaluated"
page; the device table should request an explicit sort so cursor pages
do not shuffle.

Search (`hostname`, free text) that cannot be expressed as an
`in:composite_results` filter stays client-side **on the current page**,
and the UI must say so. Device-uid / check / verdict / status filters
push down via `api.srql.update`. Hostname search is the one that cannot
push down today (`hostname:` is `InvalidRequest` on this entity). Call
that out in the SDK docs rather than pretending.

### D5 — Stats frames and row frames are different declarations

A package that wants a complete breakdown declares, for example:

```
data_frames:
  - id: by_check_verdict
    query: "in:composite_results stats:count() as n by check, verdict"
    limit: 500
    required: true
  - id: by_vantage
    query: "in:composite_results stats:count() as n by check, input_key, input_value, input_stale"
    limit: 500
    required: false
  - id: results
    query: "in:composite_results sort:device_uid:asc limit:200"
    limit: 200
    required: true
  - id: devices
    query: "in:devices limit:200"
    limit: 200
    required: false
```

`devices` starts empty-ish and is rewritten with `uid:(…)` after the
first results page. `@max_frames` 12 still holds. Four frames is enough
for the Armis composite dashboard.

Stats queries do not mint a `next_cursor` unless the group count hits
`limit`. A well-authored stats frame will not.

## Risks / Trade-offs

- **BREAKING silent-stats.** Anyone who copy-pasted `stats:` onto
  `composite_results` and parsed rows will see grouped objects. Mitigation:
  error on unsupported aggregations; document the break in CHANGELOG.
  There is no in-tree caller.
- **jsonb_each cost.** Unnesting `inputs` on 28k × N keys is still a
  sequential scan plus expand, but it returns tens of rows, not tens of
  thousands, and it does not cross the LiveView socket. Index: existing
  PK `(device_uid, check_id)` is enough for the filtered case
  (`check:slug`). Unfiltered vantage-across-all-checks on a huge fleet
  may want a later expression index; do not add one speculatively.
- **Channel still refreshes every 15s.** Stats frames are cheap; a 200-row
  page is cheap. Leave the interval alone in this change. A package that
  still declares a 2_000-row unfiltered frame is unchanged.
- **SDK version.** `page` is additive. Publish a minor of
  `@carverauto/serviceradar-dashboard-sdk`. Old packages keep working;
  they just cannot page.
- **Cursor replay.** Stream tokens are already not user-bound
  (`add-dashboard-package-access-control`). Frame cursors are SRQL
  offset MACs, same as the explorer. No new exposure.

## Migration Plan

1. Land SRQL stats (Rust tests first: SQL shape, bind counts, error
   cases). web-ng picks it up through the NIF with no Elixir query change.
2. Land FrameRunner cursor + LiveView event + JS host. Feature-detect in
   the SDK (`typeof api.srql.page === "function"`).
3. Publish SDK minor.
4. Customer packages (Armis dashboard) switch frames in their own
   repo. Until they do, they keep seeing the ceiling banner on hosts that
   still clamp at 2_000.

Rollback: revert the SRQL stats commit and stats queries start failing
(better than silently dumping rows). Revert the page API and packages
fall back to `update`.

## Open Questions

None that block implementation. Page size 200 is forced by the parser
list cap; stats group cap 500 is an implementation constant, not an
operator setting.
