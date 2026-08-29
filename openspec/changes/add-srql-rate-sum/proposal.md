# Sum per-series rates instead of only averaging them

## Why

`agg:rate` computes a per-series rate correctly — the LAG window partitions by
the full series identity, so deltas are per underlying counter and counter
resets yield NULL — and then combines them inside each display bucket with:

```sql
AVG(rate_value) AS value
```

That answers *"what is the typical rate of one of these"*. There is no way to
ask *"what is the combined rate of all of them"*, and the two differ whenever a
display series collapses more than one underlying counter.

Aruba RADIUS is the concrete case. Each controller keeps its **own** counters
for every RADIUS server it talks to, so the counters are per
`(controller, radius_server)` pair. A fleet total for a server is the **sum**
across controllers; `AVG` understates it by exactly the number of controllers
reporting that server. The dashboard has shipped this panel labelled "mean rate
per server and NOT a fleet total" since it was written, because the honest
number was the only one available.

## What Changes

`agg:rate_sum` — identical to `agg:rate` in every respect except that the
per-series rates are summed within a bucket rather than averaged.

Everything that makes a rate trustworthy is unchanged and deliberately so:

- The LAG window still partitions by the full series identity. Summing rates
  computed over a coarser partition would be summing nonsense — the deltas
  themselves have to be per underlying counter.
- Counter resets still yield NULL and are still skipped, so a wrap cannot
  surface as a spike.

`agg:rate` is untouched. A test asserts it still emits `AVG`.

## Impact

- Affected specs: `srql`
- Affected code: `rust/srql/src/parser/ast.rs`, `parser/duration.rs`,
  `query/downsample/fields.rs`, `query/downsample/sql.rs`
- Purely additive: every existing query produces identical SQL.
- The unknown-agg error message now advertises `rate_sum`.

### Why this is not a plugin change

An earlier plan had `aruba-controller-fabric` emit per-interval deltas as
gauges, so `agg:sum` would give the total. **That plan was not viable and the
plugin already documents why:** a WASM invocation is stateless and the host ABI
has no state or KV function, so it cannot hold a previous-poll cache. The Python
collector could, and its cache reset on every restart — the first poll after a
deploy emitted NULL deltas for every server.

Cumulative counters are the correct wire format for a stateless producer. The
combine belongs at query time, which is where this change puts it.

### Deliberately out of scope

- **Making `agg:rate` itself configurable.** A silent change to what an existing
  panel plots is worse than a new token.
- **`stats:`-side rate aggregation.** `stats:` has no bucketing, so a rate has
  nowhere to live there.
