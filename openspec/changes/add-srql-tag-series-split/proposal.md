# Split downsampled series by a tag key

## Why

`add-srql-timeseries-tag-dimensions` made `tags.<key>` available to **filters**
and to **`stats: ... by`**. It did not touch `series:`, which is still a closed
whitelist. That leaves the one query shape fleet dashboards actually need
unexpressible.

The problem is that `stats:` has no bucketing. A per-SSID fleet total written as

```
in:timeseries_metrics metric_name:aruba.ssid.client_count time:last_20m
  stats:sum(value) as clients by tags.ssid
```

sums **every point in the window**. The emitting collector polls every 10
minutes, so a 20-minute window sums two polls and reports roughly double the
real client count. Narrowing the window to under one poll interval trades a
wrong number for an intermittently empty one. Neither is shippable.

The shape that is correct buckets at the poll cadence, sums within each bucket,
and splits the series by the tag:

```
in:timeseries_metrics metric_name:aruba.ssid.client_count time:last_1h
  bucket:10m agg:sum series:tags.ssid
```

Each bucket then holds exactly one poll per series, so the newest bucket is a
true fleet total per SSID — with no row cap, because aggregation happens in the
database rather than by summing raw points client-side.

`series_expr` **already extracts a tag** for this exact purpose:

```rust
"core_id" => "tags->>'core_id'".to_string(),
```

so the extraction is established and accepted here. It is simply frozen to one
hardcoded key. This change generalises that one line rather than introducing a
new mechanism.

## What Changes

1. **`series:tags.<key>` on the timeseries entities** (`timeseries_metrics`,
   `snmp_metrics`, `rperf_metrics`), extracting `tags->>'<key>'`, validated by
   the same `is_valid_jsonb_key` the filter and group paths use.
2. **`series:core_id` keeps working unchanged** on those entities. It is an
   alias for `tags.core_id` that predates this syntax, and other callers rely on
   it; it is retained deliberately rather than migrated.
3. No change to the other metric entities (`cpu_metrics`, `memory_metrics`,
   `disk_metrics`, …). Their `core_id` is a real column, not a tag, and none of
   them carry a `tags` column to extract from.

## Impact

- Affected specs: `srql`
- Affected code: `rust/srql/src/query/downsample/fields.rs`
- Purely additive: every query valid today stays valid and produces identical
  SQL. The only new behaviour is accepting a previously rejected series field.
- Security: the series expression is interpolated into the SELECT and GROUP BY
  lists exactly like the group expression, so the key MUST be validated before
  it reaches the string. Reuses `is_valid_jsonb_key`
  (`[A-Za-z0-9_-]{1,64}`), which excludes quotes, dots, and whitespace.
- Unblocks the fleet-aggregate dashboard panels tracked as gap B1 in the
  customer dashboard package, which currently ship as Top-N approximations.
