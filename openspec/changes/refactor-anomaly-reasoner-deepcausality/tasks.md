# Tasks: Unify the anomaly reasoner on DeepCausality

## 1. Welford accumulator in the NIF
- [ ] 1.1 Add `WelfordAcc{count, mean, m2}` + `welford_add`/`welford_remove` (West deletion, clamp `m2 ≥ 0`) to `causal_reasoner_nif`, ported byte-for-byte from `compact_evaluator.ex`.
- [ ] 1.2 Keep the existing two-pass `sample_stats` path behind a flag as the parity oracle during migration.
- [ ] 1.3 Implement the O(1) admit: on `window.filled()` read `window.first()` → `welford_remove`, then `push`, then `welford_add`; before fill, `welford_add` only.

## 2. Incremental, stateless-across-calls contract
- [ ] 2.1 Extend `ReasonContext` to carry `acc: WelfordAcc` + bounded `window_tail` (≤ `window_size`) for the rolling signal; keep seasonal/trend arrays as-is.
- [ ] 2.2 Extend `ReasonVerdict` to return `next_acc` + `next_window_tail`; fold them into the value channel in `finalize_detector_verdict` before `finish()` (which drops State).
- [ ] 2.3 Rewrite `evaluate_detector` rolling signal to read `(mean, stddev)` from `acc` (`variance = m2/(count−1)`, zero-variance guard) instead of `state.rolling_window.vec()` + `sample_stats`. Move the admit into the `branch_with` clean arm (withholding: only clean samples mutate the baseline).

## 3. Batched evaluation entry
- [ ] 3.1 Add `reason_batch(Vec<(SeriesState, Sample)>) -> Vec<Verdict>` (regular NIF if per-batch < ~1 ms, else DirtyCpu); keep `reason/2` for single-shot and rebuild.
- [ ] 3.2 In Elixir, route Broadway/per-shard batches through `reason_batch` (batch on the message/shard boundary, not per series); tune batch size (~1k) until FFI per-sample cost is dominated by the O(1) arithmetic.

## 4. Elixir state shrink + sharding unchanged
- [ ] 4.1 Change `ContextOwner.reason_update` to call the NIF with the accumulator context instead of the full baseline list; persist `{count, mean, m2, window_tail, consecutive}` in GenServer/ETS state instead of appending to a baseline list.
- [ ] 4.2 Keep the ordered sample log ONLY for `rebuild_from` (out-of-order); replay it through `reason_batch`. Leave Horde registry / single-writer / Broadway concurrency untouched.

## 5. Parity + drift gates
- [ ] 5.1 Keep the existing Rust parity tests green (`repeat_calls_are_deterministic`, `uses_sample_variance_for_z_score`, sustained-flood, zero-variance, confirm-slots, insufficient-baseline, non-finite drop).
- [ ] 5.2 Add a property test: incremental Welford == two-pass within f64 tolerance over random in-order streams, including large-magnitude (≥1e9) series that expose the two-pass cancellation.
- [ ] 5.3 Add a periodic full-slice recompute (on `count < 2` / every-N-evictions) or Kahan compensation to bound windowed-remove drift; add a long-run drift test asserting `|Δz|` stays within tolerance.

## 6. Remove the second implementation
- [ ] 6.1 Once the NIF reaches parity + acceptable batched throughput, delete `compact_evaluator.ex`, its test, and its bench modes; the DeepCausality NIF is the single source of truth.
- [ ] 6.2 Add a `reason_batch` mode to `bench/anomaly_detection_scale.exs`; compare its throughput against the documented compact numbers and the production `owner` path; record results.

## 7. Convention + follow-ups
- [ ] 7.1 Land the `AGENTS.md` "use DeepCausality, don't hand-roll" guideline (this change).
- [ ] 7.2 (Follow-up, defer) Migrate seasonal/trend signals from arrays to accumulators; evaluate adopting the `corrective_ddos_detector` corrective-action pattern for verdicts.

## 8. Validation
- [ ] 8.1 `openspec validate refactor-anomaly-reasoner-deepcausality --strict` passes.
- [ ] 8.2 `./scripts/elixir_quality.sh --project elixir/serviceradar_core` passes; `cargo test` + `cargo clippy` green for `causal_reasoner_nif`.
- [ ] 8.3 Bazel/Go BUILD updated if the NIF adds imports; `bazel test` for affected targets.
