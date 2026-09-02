# Aggregate the alerts entity instead of silently ignoring `stats:`

## Why

`in:alerts stats:count() as n by severity` returns a page of raw alert rows
with a 200.

Not an error, not an empty result — the `stats:` clause is discarded and the
generated SQL is **byte-identical to a plain row query**: no `COUNT`, no
`GROUP BY`. `alerts.rs` has no stats handling at all, and `engine.rs` dispatches
to it unconditionally.

A caller asking "how many critical alerts per device" gets back alert rows, and
if the client counts them it counts a truncated page rather than the fleet. That
is the same failure this project has now hit three times — a query that succeeds
and answers a different question than the one asked — and it is the reason
`add-srql-timeseries-tag-dimensions` exists.

It also blocks the alert dashboard panels that `add-alert-device-identity` just
unblocked on the write side: alerts now carry a canonical `device_uid`, but
nothing can group by it.

## What Changes

1. **`stats:count() as <alias> by <field>[,<field>]` aggregates** on the alerts
   entity, returning one row per group.
2. **Unsupported requests error** rather than falling through to a row listing:
   a non-`count()` aggregation, an ungroupable field, a missing group, or an
   unsafe alias.

### Grouping wraps the row query rather than rebuilding its filters

The stats SQL is `SELECT ... FROM (<the row query>) src GROUP BY ...`.

Rebuilding the WHERE clause in raw SQL is how the two paths drift, and a filter
honoured when listing but ignored when counting is exactly the silent-wrong-
number this change is fixing. Wrapping means there is one filter implementation,
one bind ordering, and an unsupported filter still errors from where it always
did.

### Only `count()`

Alerts carry no numeric measure worth averaging. `metric_value` is whatever
tripped a threshold; its mean across unrelated rules is a number nobody should
act on. Requests for `avg`/`sum`/`max` are rejected rather than answered.

### Groupable fields are deliberately narrow

`severity`, `status`, `source_type`, `device_uid`, `agent_uid`, `metric_name`,
`escalation_level` — the dimensions an operator triages along. Free-text columns
are excluded: grouping by `title` yields one group per alert, which is a row
listing wearing an aggregate's clothes.

## Impact

- Affected specs: `srql`
- Affected code: `rust/srql/src/query/alerts.rs`
- **Behaviour change**: queries that today receive rows for a `stats:` request
  will now receive aggregates, or an error if the request was never expressible.
  Any client that "worked" was reading a truncated row page as if it were a
  count, so this replaces a wrong answer with a right one or a loud failure.
- No migration. No schema change.
- Security: the alias is interpolated as a JSON key and SQL identifier and is
  restricted to `[A-Za-z0-9_]{1,64}`; group fields resolve through a closed
  whitelist to fixed column names. Filter values remain bound.

### Deliberately out of scope

- **Ungrouped `stats:count()`** (a bare total). It needs a different shape and
  no panel needs it yet; it errors with a message saying so rather than being
  half-implemented.
- **Time-bucketed alert counts** (`bucket:`/`agg:`), which is a separate path.
