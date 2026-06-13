## 1. Proposal and Guardrails
- [x] 1.1 Validate this OpenSpec proposal with `openspec validate --strict`.
- [x] 1.2 Add repository guidance that DeepCausality-backed `CausalReasoner` is the authoritative anomaly reasoner and parallel detector implementations require an OpenSpec change.

## 2. NIF Rolling State
- [ ] 2.1 Add `WelfordAcc` and bounded `window_tail` fields to the Rust `ReasonContext` and `ReasonVerdict` maps while retaining legacy `baseline` compatibility.
- [ ] 2.2 Implement Welford addition and West deletion helpers with focused Rust tests.
- [ ] 2.3 Update rolling signal evaluation to use compact stats without rebuilding the window on every sample.
- [ ] 2.4 Admit samples into rolling state only on the clean branch and return the next compact state in every verdict.
- [ ] 2.5 Keep a two-pass rebuild/oracle path for test validation and optional bounded drift checks.

## 3. Batch Boundary
- [ ] 3.1 Add a Rust NIF `reason_batch` entrypoint that accepts many independent `(context, sample)` inputs and returns ordered results.
- [ ] 3.2 Add Elixir wrapper/spec normalization for `CausalReasoner.reason_batch/1`.
- [ ] 3.3 Benchmark batch size and scheduler choice; use `DirtyCpu` if tuned batches can exceed the normal scheduler budget.
- [ ] 3.4 Keep the reasoner expressed through `CausalFlow` unless post-batching profiles show the flow wrapper cost dominates real workloads.

## 4. Elixir Runtime Integration
- [ ] 4.1 Update `ContextOwner` to persist `{count, mean, m2, window_tail, consecutive_anomalous}` instead of a full rolling baseline list on the hot path.
- [ ] 4.2 Preserve out-of-order rebuild/replay behavior by rebuilding compact state from ordered samples through the reasoner.
- [ ] 4.3 Wire high-cardinality shard/Broadway boundaries to use `reason_batch` where batches are naturally available.

## 5. Correctness Gates
- [ ] 5.1 Add Rust parity/property tests comparing incremental state with the two-pass oracle over random streams and eviction windows.
- [ ] 5.2 Add large-magnitude counter tests near and above `1e9` to catch naive variance collapse.
- [ ] 5.3 Extend ExUnit coverage for readiness, sample variance, zero-variance, breach threshold, anomalous sample withholding, confirmation slots, non-finite rejection, and returned next-state fields.
- [ ] 5.4 Run the existing synthetic anomaly dataset tests through the DeepCausality compact state path.

## 6. Benchmarks and Cleanup
- [ ] 6.1 Add benchmark modes for per-sample NIF compact state and `reason_batch` throughput.
- [ ] 6.2 Record throughput and allocation results against the production owner, legacy list NIF, and temporary compact evaluator baselines.
- [ ] 6.3 Delete `CompactEvaluator`, compact-specific production call sites, and obsolete benchmark modes after parity and throughput acceptance.
- [ ] 6.4 Update the OpenSpec tasks/results with final benchmark numbers and tuning guidance.
