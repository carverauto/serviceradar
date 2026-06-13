## 1. Proposal and Guardrails
- [x] 1.1 Validate this OpenSpec proposal with `openspec validate --strict`.
- [x] 1.2 Add repository guidance that DeepCausality-backed `CausalReasoner` is the authoritative anomaly reasoner and parallel detector implementations require an OpenSpec change.

## 2. NIF Rolling State
- [x] 2.1 Add `WelfordAcc` and bounded `window_tail` fields to the Rust `ReasonContext` and `ReasonVerdict` maps while retaining legacy `baseline` compatibility.
- [x] 2.2 Implement Welford addition and West deletion helpers with focused Rust tests.
- [x] 2.3 Update rolling signal evaluation to use compact stats without rebuilding the window on every sample.
- [x] 2.4 Admit samples into rolling state only on the clean branch and return the next compact state in every verdict.
- [x] 2.5 Keep a two-pass rebuild/oracle path for test validation and optional bounded drift checks.

## 3. Batch Boundary
- [x] 3.1 Add a Rust NIF `reason_batch` entrypoint that accepts many independent `(context, sample)` inputs and returns ordered results.
- [x] 3.2 Add Elixir wrapper/spec normalization for `CausalReasoner.reason_batch/1`.
- [x] 3.3 Benchmark batch size and scheduler choice; use `DirtyCpu` if tuned batches can exceed the normal scheduler budget.
- [x] 3.4 Keep the reasoner expressed through `CausalFlow` unless post-batching profiles show the flow wrapper cost dominates real workloads.

## 4. Elixir Runtime Integration
- [x] 4.1 Update `ContextOwner` to persist `{count, mean, m2, window_tail, consecutive_anomalous}` instead of a full rolling baseline list on the hot path.
- [x] 4.2 Preserve out-of-order rebuild/replay behavior by rebuilding compact state from ordered samples through the reasoner.
- [x] 4.3 Add `reason_batch` for independent batch callers and keep the shard fallback wired where batches are naturally available.
- [x] 4.4 Add native shard resources for hot runtime state and gate native/sharded engines behind `ANOMALY_ANALYSIS_CONTEXT_ENGINE`.
- [x] 4.5 Return sparse anomaly-open/anomaly-clear events so clean non-events do not allocate verdict maps across the BEAM boundary.
- [x] 4.6 Add compact tuple inputs for the hot shard path and keep map inputs as compatibility wrappers.

## 5. Correctness Gates
- [x] 5.1 Add Rust parity/property tests comparing incremental state with the two-pass oracle over random streams and eviction windows.
- [x] 5.2 Add large-magnitude counter tests near and above `1e9` to catch naive variance collapse.
- [x] 5.3 Extend ExUnit coverage for readiness, sample variance, zero-variance, breach threshold, anomalous sample withholding, confirmation slots, non-finite rejection, and returned next-state fields.
- [x] 5.4 Run the existing synthetic anomaly dataset tests through the DeepCausality compact state path.

## 6. Benchmarks and Cleanup
- [x] 6.1 Add benchmark modes for per-sample NIF compact state and `reason_batch` throughput.
- [x] 6.2 Record throughput and allocation results against the production owner, legacy list NIF, and temporary compact evaluator baselines.
- [x] 6.3 Delete `CompactEvaluator` and compact-specific production/test call sites after parity and throughput acceptance while keeping benchmark modes for accepted and rejected DeepCausality cuts.
- [x] 6.4 Update the OpenSpec tasks/results with final benchmark numbers and tuning guidance.
- [x] 6.5 Benchmark and document rejected hot-path cuts: sequential shard calls, prepared map inputs, and numeric id lookup.
- [x] 6.6 Benchmark and document accepted hot-path cuts: sparse events, tuple inputs, native shard state, and unused `SlidingWindow` removal.
