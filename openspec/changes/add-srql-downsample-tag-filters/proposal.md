# Allow bucketed queries to be filtered by a tag key

## Why

Tag support arrived in three pieces and stopped one short of complete:

| Path | `tags.<key>` filter | `tags.<key>` group / split |
|---|---|---|
| raw rows | yes (#3823) | n/a |
| `stats:` | yes (#3823) | yes, `by tags.<key>` (#3823) |
| `bucket:`/`agg:` | **no** | yes, `series:tags.<key>` (#4037) |

So a bucketed aggregate can be *split* by a tag but not *scoped* to one:

```
# works — clients per site over time
... time:last_1h bucket:10m agg:sum series:tags.site_code

# rejected — clients at ORD over time
... tags.site_code:ORD time:last_1h bucket:10m agg:sum series:tags.ssid
```

Every fleet dashboard wants the second form, because that is what a per-site or
per-controller drill-down is. Today the only workarounds are to split by the tag
and discard every series but one client-side — which wastes the row budget on
data that is thrown away, and silently truncates once the discarded series push
the result past the cap — or to move the dimension out of tags entirely.

This is a capability gap, **not** a correctness bug: `timeseries_filter_clause`
already returns an error for fields it cannot apply, so such a query fails
loudly rather than returning unfiltered numbers. Nothing is currently wrong; it
is simply inexpressible.

## What Changes

1. **`tags.<key>` filtering on the downsample path** for `timeseries_metrics`,
   emitting `tags->>'<key>'`, with the same operators the other paths support.
2. The key is validated by the shared `is_valid_jsonb_key` before interpolation.
3. Unknown fields keep erroring, unchanged.

Scoped to `timeseries_metrics`. The other downsample entities filter real
columns and have no `tags` column to extract from.

## Impact

- Affected specs: `srql`
- Affected code: `rust/srql/src/query/downsample/filters.rs`
- Purely additive: every query valid today produces identical SQL. The only new
  behaviour is accepting a field that was previously rejected.
- Security: the expression is interpolated into a WHERE clause, so the key is
  validated first; values are bound, never interpolated.
