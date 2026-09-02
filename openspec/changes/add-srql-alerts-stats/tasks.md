# Tasks

## 1. Implementation
- [x] 1.1 Parse `stats:count() as <alias> by <field>[,<field>]` for the alerts entity
- [x] 1.2 Whitelist groupable columns; reject free-text and unknown fields
- [x] 1.3 Reject non-`count()` aggregations and a missing group
- [x] 1.4 Sanitise the alias — it becomes both a JSON key and SQL text
- [x] 1.5 Build the aggregate by WRAPPING the row query, so filters cannot diverge
- [x] 1.6 Wire both `execute` and `to_sql_and_params`

## 2. Correctness details
- [x] 2.1 Interpolate LIMIT rather than binding it — the inner query owns the placeholder numbering
- [x] 2.2 Bind the time range as a real `Timestamptz`, not text; translation-only tests never bind, so this would have failed at execution only
- [x] 2.3 Order by count descending so truncation keeps the largest groups
- [x] 2.4 Reuse the row path's bind collection so ordering cannot drift from the SQL

## 3. Tests
- [x] 3.1 Aggregation is real: `COUNT(*)` and `GROUP BY` present
- [x] 3.2 Filters survive into the aggregate
- [x] 3.3 Multi-field grouping
- [x] 3.4 Ungroupable fields, non-count aggregations, missing group, unsafe aliases all error
- [x] 3.5 Row queries are byte-unchanged without `stats:`
- [x] 3.6 Verify the new tests fail when the implementation is reverted

## 4. Verification
- [x] 4.1 `cargo test -p srql` — 520 pass
- [x] 4.2 `cargo clippy -p srql --all-targets` — clean
- [x] 4.3 `openspec validate add-srql-alerts-stats --strict`
- [ ] 4.4 **Blocked — no live data.** Confirm per-severity counts sum to the unfiltered alert total

## 5. Follow-ups (not this change)
- [ ] 5.1 Ungrouped `stats:count()` for a bare total — errors clearly today
- [ ] 5.2 Time-bucketed alert counts (`bucket:`/`agg:`) — a separate path
