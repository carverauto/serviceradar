# Change: Unify the anomaly reasoner on DeepCausality (single source of truth)

## Why

ServiceRadar's per-series anomaly detector exists today as **two divergent implementations** of the same rolling z-score:

1. `causal_reasoner_nif` (the Rust NIF behind `CausalReasoner`) — built correctly on **DeepCausality** (`deep_causality_core::CausalFlow` + `deep_causality_data_structures::SlidingWindow`), but it **recomputes mean/variance over the full window every sample** (O(window)) and marshals the whole baseline list across FFI on each call.
2. `CompactEvaluator` (`compact_evaluator.ex`) — a **hand-rolled pure-Elixir Welford z-score** with no DeepCausality and no production callers, added purely to chase throughput.

Maintaining two implementations of the same statistics in two languages is a correctness liability: they must be kept in numeric parity by hand and they drift. That drift already produced a real bug — the compact evaluator shipped a naive `Σx² − (Σx)²/n` variance that silently collapsed `stddev` to `0` on large-magnitude counters (PR #3792 review), and the NIF's two-pass variance has the same class of f64 cancellation at counter magnitudes (~1e-6 divergence at 1e9). The anomaly engine that issue #3789 and `update-anomaly-evaluation-cadence` rely on cannot be both fast and correct while the hot-path logic lives in a second, unspecced engine.

Benchmarks settle the design question (single core, this hardware; full numbers in `design.md`):

| path | evals/sec | what |
|---|---|---|
| production `owner` (GenServer + NIF, O(window)) | ~50k | today |
| DeepCausality `SlidingWindow` + O(window) recompute (NIF compute) | 2.8M | the cost we remove |
| **DeepCausality `SlidingWindow` + O(1) Welford** | **102M** | the proposed compute |
| raw ring buffer + O(1) Welford (no DeepCausality) | 105M | the floor |
| DeepCausality `CausalFlow` wrapper + O(1) Welford | 40M | idiomatic per-sample flow |

DeepCausality is **not** the bottleneck: its `SlidingWindow` costs ~0.2 ns over a hand-rolled buffer. The entire cost was the O(window) recompute (a ~36× Welford win) plus per-sample FFI. So the right move is to fold the O(1) Welford **into** the DeepCausality NIF and amortize FFI with a batch entry — not to fork a second Elixir engine. This also resolves the long-standing question (Marvin Hansen's guidance) of whether the reasoner honors the DeepCausality Flow-API intent: it does, and it becomes the single source of truth.

## What Changes

- **Make the DeepCausality NIF the single anomaly reasoner.** Remove the parallel hand-rolled `CompactEvaluator`; all per-series evaluation goes through `causal_reasoner_nif`.
- **Move rolling statistics to incremental O(1).** Replace the per-call full-window recompute (`baseline_window` + `sample_stats`) with a numerically stable **Welford** `{count, mean, m2}` accumulator carried in the reasoner state, updated via `SlidingWindow.first()`-before-`push()` to surface the evicted value.
- **Make the reasoner contract incremental and stateless-across-calls.** `ReasonContext` carries the accumulator (and a bounded window tail) instead of the full baseline list; `ReasonVerdict` returns the next accumulator so the Elixir caller persists `{count, mean, m2, window_tail, consecutive}` instead of a growing list (`finish()` drops flow State, so the next accumulator is folded into the returned value).
- **Add a batched entry `reason_batch`** that evaluates many `(series_state, sample)` pairs per FFI crossing, batched on the Broadway/shard boundary, so the ~1 µs per-sample FFI cost is amortized to ~1 ns/sample and the NIF becomes compute-bound at ~100M/sec/core. Keep `reason/2` for single-shot and out-of-order rebuild.
- **Keep DeepCausality idiomatic.** Continue expressing the per-series reasoner as a `CausalFlow` (the home for future seasonal/trend/corrective causaloids); only drop the wrapper from the inner loop if profiling later shows the ~15 ns/sample matters.
- **Codify the convention** in `AGENTS.md`: use DeepCausality for causal/statistical/streaming-anomaly reasoning; do not hand-roll a parallel detector.

## Impact

- Affected specs: `anomaly-detection`
- Affected code: `elixir/serviceradar_core/native/causal_reasoner_nif` (Welford accumulator, `reason_batch`, context/verdict contract), `elixir/serviceradar_core/lib/serviceradar/observability/anomaly_detection/*` (`context_owner`, `sample_extractor`, ETS/Horde state shrinks to the accumulator), removal of `compact_evaluator.ex` and its bench/test, `bench/anomaly_detection_scale.exs` (add a `reason_batch` mode), `AGENTS.md`.
- Relationship: refines `update-anomaly-evaluation-cadence` — its "replace baseline-list rebuilds with compact incremental state" requirement is satisfied **inside the DeepCausality NIF**, not by a separate Elixir evaluator; this change supersedes the standalone-compact-evaluator direction. Consumes the counter rate/reset handling from `add-monotonic-counter-metric-semantics` unchanged.
- Runtime impact: ~36× lower per-sample compute, FFI amortized via batching, per-series state shrinks from a baseline list to a few scalars, and a latent accuracy bug at counter magnitudes is fixed. No change to the verdict contract (parity-gated).
