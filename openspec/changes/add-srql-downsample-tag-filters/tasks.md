# Tasks

## 1. Implementation
- [x] 1.1 Add a `tags.<key>` arm to `timeseries_filter_clause` in `query/downsample/filters.rs`
- [x] 1.2 Validate the key with the shared `is_valid_jsonb_key` before interpolating
- [x] 1.3 Leave the other downsample entity arms untouched — they have no `tags` column
- [x] 1.4 Keep the unknown-field error path unchanged

## 2. Tests
- [x] 2.1 A tag filter composes with `series:tags.<key>` and both reach the SQL
- [x] 2.2 Unsafe keys (quote, dot, space, empty) are rejected
- [x] 2.3 Unknown fields still error rather than being dropped
- [x] 2.4 Verify the new tests fail if the implementation is reverted

## 3. Verification
- [x] 3.1 `cargo test -p srql` — 502 pass
- [x] 3.2 `cargo clippy -p srql --all-targets` — clean
- [x] 3.3 `openspec validate add-srql-downsample-tag-filters --strict`
- [ ] 3.4 **Blocked — no live data.** Confirm a per-site trend reconciles with the unfiltered fleet trend
