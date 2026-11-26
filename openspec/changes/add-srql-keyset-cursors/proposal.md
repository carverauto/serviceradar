# Change: Keyset cursors for SRQL pages ordered by a unique key

## Why

An SRQL cursor is an HMAC-signed row offset. Page `n` of a walk runs the same
query with `OFFSET n * limit`, so the database still produces, orders and
discards every row before the page. A walk over a whole selection is quadratic
in its length.

Control-plane code walks whole selections constantly. Policy target resolution
(`SRQLInputResolver.reduce_pages/4`: add-on profiles every 60 s, target
policies, credential rules, producer schedules, netperf selectors), the sweep
compiler's target pages, ephemeral-device expiry exclusions, composite check
scopes, the MTR automation dispatcher and web-ng's "select all matching"
action all follow `next_cursor` until it runs out.

Profiling `pg_stat_statements` on the demo deployment (about 50k devices) found
one such walk, an all-devices add-on profile target, at 42% of live database
time and roughly 670 GB a day of temporary-file writes. Every 1,000-row page of
the device default order re-sorted every device row and spilled to disk.
`perf(core): page device targets by uid` moved policy walks to `sort:uid:asc`.
That made early pages cheap, but a deep offset still costs a scan of every
skipped row. Measured on the demo replica, one 1,000-row device page:

| Page shape                                  | Time    |
|---------------------------------------------|---------|
| default order, `OFFSET 25000`               | ~500 ms, external merge sort |
| `ORDER BY uid`, `OFFSET 25000` / `50000`    | ~270 ms, planner falls back to seq scan + sort |
| `WHERE uid > $last ORDER BY uid`            | ~12 ms, uid index scan |

The offset model also caps every walk: past `srql_max_cursor_offset` (default
100,000) SRQL stops issuing cursors, and since
`read-whole-policy-target-selections` a policy target selection larger than
that fails outright instead of being read. A deployment with more than 100k
devices cannot target "all devices" with any add-on profile or credential rule.

## What Changes

- SRQL issues **keyset cursors** for a query whose effective order is a single
  unique, indexed key of the entity: initially `sort:uid:asc` or
  `sort:uid:desc` on `devices` and `agents`. The next page is read with
  `WHERE <filters> AND uid > $last` (or `<` for descending) and no `OFFSET`.
- A keyset cursor is a new signed cursor version that carries the last key
  value and the key column and direction it belongs to. It is minted by
  whichever component executed the page, from the page's last row, because a
  translate-only caller sees rows that SRQL never does. SRQL exposes signing to
  the Elixir executors through the existing NIF.
- Keyset cursors are forward-only and have no offset ceiling; `window_scan:true`
  has no effect on them. A keyset query requested with `direction: "prev"` is
  rejected.
- Queries whose order is not keyset-eligible keep offset cursors unchanged,
  including every interactive table default order. An offset cursor presented
  to a keyset-eligible query is still honoured, so a walk that straddles an
  upgrade completes.
- Control-plane walkers that fold whole selections into sets page by
  `sort:uid:asc` so they get keyset cursors: the SRQL input resolver (already),
  the sweep compiler, ephemeral-device expiry, composite check scopes and the
  MTR automation dispatcher. web-ng's select-all already sorts by uid.
- Policy target selections are no longer limited by the cursor window, because
  the resolver only reads uid-ordered entities with keyset cursors. The
  fail-closed rule stays for any order that cannot be read whole.

## Impact

- Affected specs: `srql` (new requirement), `wasm-plugin-system` (`Policy Target
  Queries Are Read Whole`).
- Affected code: `rust/srql` (`pagination.rs`, `query/plan.rs`,
  `query/translate.rs`, `query/engine.rs`, devices and agents query builders,
  NIF exports), `ServiceRadar.Observability.SRQLRunner`,
  `ServiceRadarWebNG.SRQL`, `ServiceRadar.Plugins.SRQLInputResolver`, and the
  walkers listed above.
- No schema change: `ocsf_devices` and `ocsf_agents` already carry unique uid
  indexes.
- Wire compatibility: offset (v2) cursors keep their format and meaning.
  Clients that treat cursors as opaque need no change.
