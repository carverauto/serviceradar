## 1. Fix silent filter handling in query modules
- [x] 1.1 Replace `_ => {}` with error return in `logs.rs:235` matching the pattern in `devices.rs`
- [x] 1.2 Replace `_ => {}` with error return in `timeseries_metrics.rs:120`
- [x] 1.3 Replace `_ => {}` with error return in `cpu_metrics.rs:191`
- [x] 1.4 Replace `_ => {}` with error return in `traces.rs:111`
- [x] 1.5 Replace `_ => {}` with error return in `services.rs:105`
- [x] 1.6 Replace `_ => {}` with error return in `otel_metrics.rs:145`
- [x] 1.7 Replace `_ => {}` with error return in `pollers.rs:103`
- [x] 1.8 Replace `_ => {}` with error return in `memory_metrics.rs:128`
- [x] 1.9 Replace `_ => {}` with error return in `disk_metrics.rs:133`
- [x] 1.10 Replace `_ => Ok(None)` with error return in `logs.rs` `build_stats_filter_clause`
- [x] 1.11 Replace `_ => return Ok(None)` with error return in `otel_metrics.rs` `build_stats_filter_clause`

## 2. Add regression tests
- [x] 2.1 Add unit test in `logs.rs` asserting unknown filter field returns error
- [x] 2.2 Add unit test in `logs.rs` asserting unknown stats filter field returns error
- [x] 2.3 Add unit test in `traces.rs` asserting unknown filter field returns error
- [x] 2.4 Add unit test in `services.rs` asserting unknown filter field returns error
- [x] 2.5 Add unit test in `pollers.rs` asserting unknown filter field returns error
- [x] 2.6 Add unit test in `cpu_metrics.rs` asserting unknown filter field returns error
- [x] 2.7 Add unit test in `memory_metrics.rs` asserting unknown filter field returns error
- [x] 2.8 Add unit test in `disk_metrics.rs` asserting unknown filter field returns error
- [x] 2.9 Add unit test in `timeseries_metrics.rs` asserting unknown filter field returns error
- [x] 2.10 Add unit test in `otel_metrics.rs` asserting unknown filter field returns error

## 3. Verification and cleanup
- [x] 3.1 Run `cargo clippy -p srql` and fix any new warnings
- [x] 3.2 Run `cargo test -p srql` to verify all existing tests still pass (36 tests passed)
- [x] 3.3 Verify no other query modules have `_ => {}` catch-all patterns for filter handling

## 4. Documentation
- [x] 4.1 Update `docs/docs/srql-language-reference.md` with supported filter fields per entity
- [x] 4.2 Add "Unsupported filter field" to error handling section with reference to filter fields documentation
