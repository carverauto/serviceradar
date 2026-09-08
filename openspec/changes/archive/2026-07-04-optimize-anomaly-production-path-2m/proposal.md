# Change: Optimize anomaly production path to 2M eval/s

## Why
The DeepCausality native shard path can evaluate roughly 2M samples/sec on the
current local benchmark, but the opt-in `NativeContextEngine` path is closer to
0.9M eval/s because it still pays for rich Elixir sample maps, shard grouping,
first-context checks, task fanout, sparse-result sorting, and BEAM term churn.

We need a focused architecture pass that makes the production path look like the
measured direct NIF path without forking the detector or weakening anomaly
semantics.

This work is sequenced after the operational hardening in
`refactor-anomaly-reasoner-deepcausality`: rollback gating, idempotent redelivery
handling, shard single-writer protection, bounded series state, and Welford drift
guards must remain in force before any native path is promoted.

## What Changes
- Add a compact production batch contract for anomaly evaluation that avoids one
  rich Elixir map per scalar metric.
- Treat the compact correlation token as both the sparse-event re-association key
  and the idempotency key for redelivery-safe native state application.
- Move shard partitioning and compact sample preparation earlier in the pipeline
  so `NativeContextEngine` receives shard-ready batches.
- Record the packed-binary NIF prototype result and do not ship a detector-local
  binary ABI unless it is consistently faster than tuples in the production
  wrapper.
- Add batch-level anomaly telemetry so production throughput, latency, drops,
  failures, and sparse event output are visible through the existing metrics
  pipeline.
- Treat canonical protobuf JetStream metric envelopes as the next serialization
  boundary to evaluate if map/JSON decode remains hot; source producers should
  emit source-neutral metric facts, not detector-specific binary records.
- Avoid hot-path ETS lookups for numeric series IDs; any ID assignment must be
  done outside the per-sample loop or inside bounded native shard state.
- Preserve per-shard single-writer evaluation; larger batches must not reintroduce
  native shard lock contention.
- Keep sparse anomaly-open/anomaly-clear output as the production result shape.
- Add benchmark gates that prove the production path reaches or explains failure
  to reach 2M evaluations/sec on the same synthetic workload used by
  `refactor-anomaly-reasoner-deepcausality`.

## Impact
- Affected specs: `anomaly-detection`
- Affected code: `elixir/serviceradar_core` anomaly sample extraction,
  `NativeContextEngine`, `CausalReasoner` Elixir wrapper, Rust
  `causal_reasoner_nif` runtime input APIs, benchmark harnesses, telemetry
  metrics, and focused anomaly tests
- Runtime impact: lower production BEAM allocation/term-copy overhead, tighter
  shard ownership, and benchmarked throughput closer to the direct native shard
  ceiling
