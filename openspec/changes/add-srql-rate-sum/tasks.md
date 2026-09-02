# Tasks

## 1. Implementation
- [x] 1.1 Add `DownsampleAgg::RateSum` with the distinction documented on the variant
- [x] 1.2 Parse the `rate_sum` token and list it in the unsupported-agg error
- [x] 1.3 Treat it as rate-shaped in `is_rate_agg` so it takes the rate CTE path
- [x] 1.4 Select the bucket combine via `rate_bucket_combine`, leaving `agg:rate` on AVG

## 2. Invariants that must not change
- [x] 2.1 LAG stays partitioned by the full series identity — summing rates from a coarser partition would be summing nonsense
- [x] 2.2 Counter resets still yield NULL and are still skipped, so a wrap cannot read as a spike

## 3. Tests
- [x] 3.1 `rate_sum` emits `SUM(rate_value)` and not `AVG`
- [x] 3.2 `agg:rate` still emits `AVG(rate_value)` and not `SUM`
- [x] 3.3 The per-counter LAG partition survives
- [x] 3.4 The reset guards survive
- [x] 3.5 End-to-end through `translate_request`, composed with `series:tags.<key>`
- [x] 3.6 Verify the tests fail when the combine is wrong

## 4. Verification
- [x] 4.1 `cargo test -p srql` — 517 pass
- [x] 4.2 `cargo clippy -p srql --all-targets` — clean
- [x] 4.3 `openspec validate add-srql-rate-sum --strict`
- [ ] 4.4 **Blocked — no live data.** Confirm the summed rate matches the sum of per-controller series

## 5. Follow-up (not this change)
- [ ] 5.1 Repoint the dashboard's RADIUS panel at `agg:rate_sum` and retitle it from "mean rate per server" to a fleet total
