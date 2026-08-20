# Tasks

## 1. Shared JSONB key validation
- [x] 1.1 Move `is_valid_jsonb_key` out of `query::devices::filters::jsonb` into a shared module so `devices` and `timeseries_metrics` cannot drift on what a safe key is
- [x] 1.2 Keep the existing `devices` call sites working, with no behaviour change
- [x] 1.3 Unit-test the validator directly: rejects quotes, dots, whitespace, empty, >64 chars; accepts `[A-Za-z0-9_-]`

## 2. Stop discarding filters silently
- [x] 2.1 Change `build_stats_filter_clause` so an unrecognised field returns an error instead of `Ok(None)`
- [x] 2.2 Make the error text match the non-stats path so the two read identically
- [x] 2.3 Regression test: an unsupported field on the stats path errors, and the pre-fix SQL (no predicate, 2 binds) is asserted against so the bug cannot return
- [x] 2.4 Audit callers for queries that relied on the silent drop; fix any in-tree dashboards or saved queries — the two profile routes already converted `Ok(None)` into their own error, so the fix moved to the caller that swallowed it (`build_stats_query_with_source`) rather than into the shared builder, preserving those messages

## 3. CAGG routing must not change filter semantics
- [x] 3.1 Add a predicate for "is this filter expressible against the hourly CAGG"
- [x] 3.2 Disqualify CAGG routing when any filter fails that predicate, falling back to the raw table
- [x] 3.3 Remove the silent `_ => Ok(None)` from the CAGG branch of `build_stats_filter_clause` — kept as a capability signal, since the profile routes depend on it; the error now lives in the caller. `CAGG_FILTERABLE_FIELDS` is shared by the routing guard and the filter builder so they cannot drift
- [x] 3.4 Test: `gateway_id` + a >6h range now hits the raw table and keeps the predicate
- [x] 3.5 Test: a `device_id`-only stats query still routes to the CAGG (no regression in the fast path)

## 4. Tag filtering on timeseries_metrics
- [x] 4.1 Add a `tags.<key>` arm to `apply_filter` (raw path), validating the key first
- [x] 4.2 Add the matching arm to `build_stats_filter_clause` (stats path), emitting `tags->>'key'` with bound values
- [x] 4.3 Support Eq, NotEq, Like, NotLike, In, NotIn — matching the `devices` entity
- [x] 4.4 Confirm NotEq handles a missing tag the way `devices` does (`IS NULL OR <> ?`), so absent tags are not silently excluded
- [x] 4.5 Tests per operator asserting both the SQL shape and the bind count

## 5. Tag grouping on timeseries_metrics
- [x] 5.1 Extend `parse_timeseries_group` to accept `tags.<key>`, validating the key
- [x] 5.2 Emit `tags->>'key'` as the group expression, and project the result under `tags.<key>`
- [x] 5.3 Verify the key cannot reach the interpolated group expression unvalidated
- [x] 5.4 Confirm ordering/rank paths (`build_timeseries_stats_order_parts`) resolve a tag group key correctly
- [x] 5.5 Test grouping by a tag, by a tag plus a column, and rejection of an invalid key

## 6. Verification
- [x] 6.1 `cargo test -p srql`
- [x] 6.2 `cargo clippy -p srql -- -D warnings`
- [ ] 6.3 **Blocked — no live data yet.** Run the real dashboard queries this unblocks against a live instance and confirm per-site numbers reconcile with the fleet total
- [x] 6.4 `openspec validate add-srql-timeseries-tag-dimensions --strict`

## 7. Follow-ups (not this change)
- [ ] 7.1 Index supporting `tags->>'<key>'` grouping on the hypertable — measure first
- [ ] 7.2 Cross-series combine for `agg:rate` (sum-of-rates), tracked separately
