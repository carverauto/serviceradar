## 1. Proposal and Baseline
- [ ] 1.1 Validate this OpenSpec change with `openspec validate optimize-anomaly-production-path-2m --strict`.
- [ ] 1.2 Record the current direct tuple/resource and production `native_engine_events` benchmark numbers in the PR.
- [x] 1.3 Add benchmark instrumentation for sample prep, shard grouping, NIF time, result re-association, and emitted event count.
- [ ] 1.4 Confirm the `refactor-anomaly-reasoner-deepcausality` operational hardening is present before promoting any native/sharded path: rollback gate, redelivery idempotency, per-shard single writer, bounded series state, and Welford drift recompute.

## 2. Compact Production Batch Contract
- [ ] 2.1 Add a project-owned compact anomaly sample/batch type for correlation/idempotency token, shard id, series identity or id, value, timestamp, and optional first context.
- [ ] 2.2 Add a shard-ready engine API that accepts compact shard batches without regrouping arbitrary sample maps.
- [ ] 2.3 Keep the current map-shaped `evaluate_events_batch/1` API as a compatibility wrapper.
- [ ] 2.4 Add tests that sparse events can recover original sample metadata through the compact sample index/correlation token.
- [ ] 2.5 Add redelivery tests proving a repeated correlation/idempotency token does not refold native Welford state or emit duplicate sparse events.

## 3. Native Input Experiments
- [ ] 3.1 Implement a columnar native shard input path and benchmark it against tuple input.
- [ ] 3.2 Implement a packed-binary or hybrid native shard input path if columnar input does not reach the target.
- [ ] 3.3 Benchmark numeric series IDs only with lookup outside the per-sample BEAM hot loop.
- [ ] 3.4 Bound any native series-id intern table with the same max-series eviction policy as detector state.
- [ ] 3.5 Reject any input contract that is faster only by changing anomaly semantics or returning fewer required state-change events.

## 4. Production Wiring
- [ ] 4.1 Move shard partitioning and compact sample construction upstream of `NativeContextEngine` in the production analysis path.
- [ ] 4.2 Ensure warm-series steady state performs no per-sample ETS lookup before the NIF call.
- [ ] 4.3 Keep sparse open/clear output as the only production result shape.
- [ ] 4.4 Preserve fallback/debug paths for full verdicts and map/tuple compatibility.
- [ ] 4.5 Preserve per-shard single-writer access when multiple Broadway processors receive samples for the same shard.

## 5. Correctness and Scale Gates
- [ ] 5.1 Run existing CausalReasoner, NativeContextEngine, pipeline, and synthetic dataset tests through the selected production path.
- [ ] 5.2 Add parity tests comparing map, tuple, and selected compact/columnar/binary input paths.
- [ ] 5.3 Benchmark warm-series throughput on the existing 1,000-series synthetic profile and target at least 2M production-path evaluations/sec.
- [ ] 5.4 Benchmark cold-series and mixed-series profiles to quantify first-context/series-interning overhead.
- [ ] 5.5 If 2M eval/s is not reached, publish an explanatory bottleneck table and the next proposed cut.
- [ ] 5.6 Report native lock contention, duplicate-token drops, intern-table size, detector-state evictions, and Welford recompute count in benchmark/debug telemetry.
