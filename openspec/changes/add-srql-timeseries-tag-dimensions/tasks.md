# Tasks

## 1. Shared JSONB key validation
- [ ] 1.1 Move `is_valid_jsonb_key` out of `query::devices::filters::jsonb` into a shared module so `devices` and `timeseries_metrics` cannot drift on what a safe key is
- [ ] 1.2 Keep the existing `devices` call sites working, with no behaviour change
- [ ] 1.3 Unit-test the validator directly: rejects quotes, dots, whitespace, empty, >64 chars; accepts `[A-Za-z0-9_-]`

## 2. Stop discarding filters silently
- [ ] 2.1 Change `build_stats_filter_clause` so an unrecognised field returns an error instead of `Ok(None)`
- [ ] 2.2 Make the error text match the non-stats path so the two read identically
- [ ] 2.3 Regression test: an unsupported field on the stats path errors, and the pre-fix SQL (no predicate, 2 binds) is asserted against so the bug cannot return
- [ ] 2.4 Audit callers for queries that relied on the silent drop; fix any in-tree dashboards or saved queries

## 3. CAGG routing must not change filter semantics
- [ ] 3.1 Add a predicate for "is this filter expressible against the hourly CAGG"
- [ ] 3.2 Disqualify CAGG routing when any filter fails that predicate, falling back to the raw table
- [ ] 3.3 Remove the silent `_ => Ok(None)` from the CAGG branch of `build_stats_filter_clause`
- [ ] 3.4 Test: `gateway_id` + a >6h range now hits the raw table and keeps the predicate
- [ ] 3.5 Test: a `device_id`-only stats query still routes to the CAGG (no regression in the fast path)

## 4. Tag filtering on timeseries_metrics
- [ ] 4.1 Add a `tags.<key>` arm to `apply_filter` (raw path), validating the key first
- [ ] 4.2 Add the matching arm to `build_stats_filter_clause` (stats path), emitting `tags->>'key'` with bound values
- [ ] 4.3 Support Eq, NotEq, Like, NotLike, In, NotIn — matching the `devices` entity
- [ ] 4.4 Confirm NotEq handles a missing tag the way `devices` does (`IS NULL OR <> ?`), so absent tags are not silently excluded
- [ ] 4.5 Tests per operator asserting both the SQL shape and the bind count

## 5. Tag grouping on timeseries_metrics
- [ ] 5.1 Extend `parse_timeseries_group` to accept `tags.<key>`, validating the key
- [ ] 5.2 Emit `tags->>'key'` as the group expression, and project the result under `tags.<key>`
- [ ] 5.3 Verify the key cannot reach the interpolated group expression unvalidated
- [ ] 5.4 Confirm ordering/rank paths (`build_timeseries_stats_order_parts`) resolve a tag group key correctly
- [ ] 5.5 Test grouping by a tag, by a tag plus a column, and rejection of an invalid key

## 6. Verification
- [ ] 6.1 `cargo test -p srql`
- [ ] 6.2 `cargo clippy -p srql -- -D warnings`
- [ ] 6.3 Run the real dashboard queries this unblocks against a live instance and confirm per-site numbers reconcile with the fleet total
- [ ] 6.4 `openspec validate add-srql-timeseries-tag-dimensions --strict`

## 7. Follow-ups (not this change)
- [ ] 7.1 Index supporting `tags->>'<key>'` grouping on the hypertable — measure first
- [ ] 7.2 Cross-series combine for `agg:rate` (sum-of-rates), tracked separately
