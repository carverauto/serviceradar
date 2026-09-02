# Add tag dimensions to timeseries_metrics, and stop dropping filters silently

## Why

Two problems, found while porting a customer's Aruba monitoring dashboards off
Grafana onto ServiceRadar. One is a live correctness bug that affects queries
people run today; the other is the feature gap that blocks the port.

### 1. The stats path silently drops filters (correctness bug, affects users now)

`build_stats_filter_clause` ends in `_ => Ok(None)`. Any filter field it does
not recognise is **discarded without an error**, and the query runs unfiltered.
The non-stats path does the opposite — `apply_filter` returns
`"unsupported filter field for timeseries_metrics"`. The two paths disagree.

Verified against the current code by building the SQL directly:

```
in:timeseries_metrics tags.site_code:ORD stats:avg(value) as v by device_id

  -> SELECT device_id AS group_value_0, AVG(value) AS agg_value_0
     FROM timeseries_metrics WHERE timestamp >= ? AND timestamp <= ?
  -> 2 binds (the time bounds only)
```

The `site_code` filter is gone. The operator asked for one site and got a
fleet-wide average, with nothing anywhere indicating the difference. A silent
wrong number is worse than an error, because it is plausible and gets acted on.

**This is not limited to tag keys.** The catch-all swallows any unrecognised
field, so a plain typo silently widens the query:

```
in:timeseries_metrics nonsense_field:x stats:avg(value) as v by device_id
  -> succeeds, aggregating every metric in the window
```

Both were confirmed end-to-end through `translate_request`, not by reading the
match arm. The same filter **without** `stats:` correctly errors with
`unsupported filter field for timeseries_metrics`, so the two paths disagree on
identical input — which is what makes this easy to hit and hard to notice.

### 2. `timeseries_metrics` has no tag dimensions (the feature gap)

`tags` is a `Nullable<Jsonb>` column that is stored, indexed into the row
payload, and returned to clients — but it cannot be filtered, grouped, or split
on. `parse_timeseries_group` whitelists ten fixed columns and nothing else.

Every plugin that emits fleet telemetry puts its real dimensions in `tags`:
site, AP name, radio band, controller, SSID. Without tag dimensions a caller
can only aggregate by `device_id`, which for this fleet means ~9,000 groups
where the useful answer has ~240 (per site) or 3 (per band).

The `devices` entity **already solves exactly this** — it supports both
`metadata.<key>` and `tags.<key>` via `apply_jsonb_text_filter`, guarded by
`is_valid_jsonb_key`. This proposal applies that established pattern to
`timeseries_metrics` rather than inventing anything.

## What Changes

1. **Unrecognised filter fields in the stats path become an error**, matching
   the non-stats path. This is a behaviour change for any caller currently
   relying on a filter being ignored — see the migration note below.
2. **The CAGG branch of the same function errors instead of dropping.** Note
   this one is defence in depth, not a live bug: `should_route_stats_to_cagg`
   already refuses to route a query whose filters the aggregate cannot express,
   so the drop is unreachable through the normal path today. An earlier draft
   of this proposal claimed it was reachable; that was wrong — the probe behind
   the claim called `build_cagg_stats_query` directly and bypassed the routing
   guard. The change is still worth making so the invariant fails loudly if
   routing and filtering ever drift apart, but it fixes no user-visible bug.
3. **`tags.<key>` filtering on `timeseries_metrics`**, in both the raw and
   stats paths, with the same operators the `devices` entity supports.
4. **`tags.<key>` grouping** in `stats:... by tags.<key>`.
5. `is_valid_jsonb_key` moves somewhere shared so `devices` and
   `timeseries_metrics` cannot drift apart on what a safe key is.

### Explicitly out of scope

- **`agg:rate` summed across series.** `agg:rate` computes a per-series rate
  then `AVG(rate_value) GROUP BY bucket, series`, which is correct per series;
  what is missing is a *cross-series* combine. That is a real gap but a
  different shape of change, and it is not what blocks the dashboard port.
- **Joins across entities.** Still unsupported, still out of scope.
- **A tag index.** Grouping on `tags->>'key'` over a hypertable will want a
  supporting index; that is a migration, tracked separately, and correctness
  should not wait on it.

## Impact

- Affected specs: `srql`
- Affected code: `rust/srql/src/query/timeseries_metrics.rs`,
  `rust/srql/src/query/devices/filters/jsonb.rs` (moved), `rust/srql/src/query/cagg.rs`
- **Behaviour change**: queries that today silently ignore an unsupported
  filter will start returning an error. That is the point — those queries are
  already returning wrong numbers. Any dashboard or saved query relying on the
  old behaviour was relying on a bug, and the error names the offending field.
- Security: group expressions are interpolated directly into SQL
  (`format!("{expr} AS group_value_{idx}")`), so tag grouping MUST validate the
  key before it reaches the string. `is_valid_jsonb_key` allows only
  `[A-Za-z0-9_-]{1,64}`, which excludes quotes, dots, and whitespace.
