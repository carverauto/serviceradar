# Design: Keyset cursors for SRQL pages ordered by a unique key

## Context

SRQL has two execution paths that both hand out cursors:

- `query/translate.rs` returns SQL, binds and pagination to a caller that runs
  the SQL itself: `ServiceRadar.Observability.SRQLRunner` in core and
  `ServiceRadarWebNG.SRQL` in web-ng, through the `ServiceRadarSRQL.Native`
  NIF. Translation computes `next_cursor = encode(offset + limit)` before the
  query runs; the executor keeps it only when the page came back full
  (`SRQLRunner.next_cursor/2`, `ServiceRadarWebNG.SRQL.next_cursor/3`).
- `query/engine.rs` executes inside Rust and mints its cursors the same way.

`pagination.rs` signs `{v: 2, offset}` with HMAC-SHA256 under
`cursor_secret`. `plan.rs` decodes it and refuses offsets past
`max_cursor_offset` (default 100,000) unless the query carries
`window_scan:true` or is an exhaustive profile stats query.

A keyset cursor needs the last row's key. On the translate path SRQL never
sees rows, so the cursor cannot be computed at translation time.

## Goals / Non-Goals

Goals:

- A whole-selection walk costs one index range scan per page, independent of
  how deep the page is.
- Walks over uid-ordered device and agent selections have no offset ceiling.
- No change for interactive tables, UI paging, or any order that is not a
  single unique key.

Non-Goals:

- Multi-column keyset (`(last_seen_time, uid)` row comparisons). Nullable
  leading columns and mixed directions need NULL-ordering rules that no current
  walker needs. A later change can add them per entity.
- Backward (`prev`) keyset paging. Walkers only move forward; interactive
  tables keep offset cursors and their prev links.
- Snapshot-consistent walks. A keyset walk reflects concurrent writes the same
  way an offset walk does, except that it can no longer skip or repeat a row
  because an earlier row was inserted or deleted.
- Narrowing the walkers' projections (they read full device rows). That is a
  separate cost and a separate change.

## Decisions

### 1. Eligibility is declared per entity, decided at plan time

A query is keyset-eligible when its effective order, after SRQL appends any
tie-break, reduces to exactly one column that the entity declares as a unique,
indexed keyset key. The first declarations are `uid` on `devices` and
`agents`. Repeated `sort:uid:asc` tokens (the resolver appends one after any
operator sort) collapse to one key, so `in:devices sort:uid:asc sort:uid:asc`
is eligible and `in:devices sort:hostname:asc sort:uid:asc` is not.

Eligibility is decided in `plan.rs` and recorded on `QueryPlan`, so every
entity builder and both execution paths read one decision.

Alternative considered: keyset for any order ending in a unique key, using row
comparisons. Rejected for this change (see Non-Goals).

### 2. Cursor version 3 carries the key, its column and direction

```
{v: 3, entity, col, dir, key, sig}
sig = HMAC-SHA256(cursor_secret, canonical_json({v, entity, col, dir, key}))
```

`canonical_json` is compact UTF-8 JSON with no insignificant whitespace.
Object keys appear in the fixed order `v`, `entity`, `col`, `dir`, `key`.
`v` is the number 3. `entity`, `col` and `dir` are JSON strings. `key` is a
JSON string for the scalar uid declared today. A later composite key is a
JSON array of strings in declared column order, which cannot encode to the
same bytes as a scalar string. The signature is not part of the signed
object. Example input bytes:

`{"v":3,"entity":"devices","col":"uid","dir":"asc","key":"dev-1"}`

Binding the entity, column and direction stops a cursor minted for one walk
from being replayed against a query ordered differently, where `uid > $key`
would silently mean something else. The filters are not bound; offset (v2)
cursors do not bind them either, and an operator who swaps filters mid-walk
gets the same "continue from here" behaviour either way.

### 3. The executor mints the cursor from the page it ran

For an eligible plan, translation returns no `next_cursor`. Instead it returns
`pagination.keyset = {entity, column, direction}`. When the executor gets a
full page, it reads the key column of the last row and asks SRQL to sign a v3
cursor through a new NIF export,
`ServiceRadarSRQL.Native.keyset_cursor(entity, column, direction, key)`. The
secret stays inside the NIF, as it does for v2.

- `SRQLRunner` and `ServiceRadarWebNG.SRQL` gain the same small branch in
  `next_cursor`.
- `engine.rs` mints the v3 cursor from the last row it already holds.
- The key column must be in the projection. Every device and agent projection
  selects `uid` today; the plan rejects an eligible query whose projection
  would drop it rather than produce an unpageable result.

Alternative considered: return a `next_cursor` template that the executor fills
in. Rejected: an unsigned template would let any caller forge a position, and
a signed template cannot be signed before the key exists.

### 4. Eligible SQL drops OFFSET

The builder adds `AND uid > $key` (`<` for descending) and emits `LIMIT n`
with no `OFFSET`. Measured on the demo replica with about 50k devices: about
12 ms per 1,000-row page at any depth, against about 270 ms for the same order
with `OFFSET 25000` or more, where the planner abandons the uid index for a
sequential scan and an external sort.

### 5. Compatibility

- A v2 offset cursor on an eligible query is honoured as an offset, so a walk
  that straddles a rolling upgrade completes. Its next cursor is v3.
- A v3 cursor on a query that is not eligible, or whose entity, column or
  direction differs, is rejected as an invalid cursor.
- `window_scan:true` is accepted and ignored on eligible queries.
- `direction: "prev"` with a v3 cursor is rejected; with no cursor, an eligible
  query returns its first page and no `prev_cursor`.

### 6. Walkers adopt `sort:uid:asc` and keep an operator sort

A walker that folds a selection into a set or a count does not depend on row
order, so it pages by uid when the query has no operator-supplied sort. In
scope: `SRQLInputResolver` (appends `sort:uid:asc` and does not replace an
operator sort), `SweepCompiler.fetch_target_query_pages`,
`EphemeralDeviceExpiry.collect_excluded`, `CompositeChecks.Scope`,
`MtrAutomationDispatcher.collect_target_contexts`.
`DeviceHostnameRdns` orders its cohort by `last_seen` on purpose and keeps
offset paging. web-ng's select-all already sends `sort:uid:asc window_scan:true`.

Only a device or agent selection whose effective order is uid alone is
keyset-paged and free of the cursor window. No operator-supplied sort is that
case: the resolver appends `sort:uid:asc`. An operator-supplied sort is kept.
Appending `sort:uid:asc` after some other sort does not replace it and does
not make the order uid alone (decision 1), so that selection stays on offset
cursors and still fails closed past the cursor window.

`SRQLInputResolver.reduce_page` keeps its generic fail-closed check: a full
page without `next_cursor` is an error. Keyset walks never reach it, because
a full eligible page always carries a cursor. There is no entity-specific
exception for devices or agents.

## Risks / Trade-offs

- Two cursor formats to maintain. Mitigated by keeping v2 untouched and
  sharing the HMAC helper.
- A walker that forgets `sort:uid:asc` silently keeps the quadratic cost.
  Mitigated by the walker list above and a per-walker test asserting the query
  shape it sends.
- Clients that parse cursors (none known; they are documented as opaque) would
  break on v3.

## Migration Plan

Ship SRQL and both executors together, because a v3 cursor minted by a new
executor must be decoded by the SRQL in the same release. Core and web-ng ship
in one chart release, so there is no cross-version window between them. Roll
back by reverting; outstanding v3 cursors then fail as invalid, and walkers
restart from the first page on their next run.

## Open Questions

- Should `interfaces` (unique `(device_id, if_index)` today) get a keyset
  declaration in this change? No current walker needs it.
