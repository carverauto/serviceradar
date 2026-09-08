# Tasks

## 1. Implementation
- [x] 1.1 Accept `series:tags.<key>` in `series_expr` for the timeseries entity arm
- [x] 1.2 Validate the key with the shared `is_valid_jsonb_key` before interpolating
- [x] 1.3 Keep `series:core_id` resolving to `tags->>'core_id'`, documented as a pre-existing alias
- [x] 1.4 Leave the non-timeseries entity arms untouched

## 2. Tests
- [x] 2.1 `series:tags.ssid` produces a `tags->>'ssid'` series expression
- [x] 2.2 `series:core_id` still produces `tags->>'core_id'` (no regression)
- [x] 2.3 Unsafe keys (quote, dot, space, empty, >64 chars) are rejected
- [x] 2.4 `in:cpu_metrics ... series:tags.x` still errors
- [x] 2.5 End-to-end through `translate_request`, matching the real dashboard query
- [x] 2.6 Verify the new tests fail if the implementation is reverted

## 3. Verification
- [x] 3.1 `cargo test -p srql`
- [x] 3.2 `cargo clippy -p srql --all-targets`
- [x] 3.3 `openspec validate add-srql-tag-series-split --strict`
- [x] 3.4 Confirm every pre-existing `series:` query generates byte-identical SQL — the 498-test suite passes unchanged, and `series:core_id` is asserted to produce exactly the same SQL as `series:tags.core_id`
