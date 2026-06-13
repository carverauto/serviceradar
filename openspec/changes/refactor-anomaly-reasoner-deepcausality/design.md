# Design: Unify the anomaly reasoner on DeepCausality

## Context

Two implementations of the same per-series rolling z-score exist: the DeepCausality NIF (`causal_reasoner_nif`, O(window) recompute) and a hand-rolled Elixir Welford (`compact_evaluator.ex`, no production callers). The goal is one source of truth, on DeepCausality (Marvin Hansen's library, which already guides the engine design — `examples/causal_correction_examples/corrective_ddos_detector` is the reference pattern), that is also fast enough for fleet scale.

## Benchmark evidence

Rust microbench (`/tmp/dc_bench`, in-process, no FFI, W=300, 5M in-order samples at `1e9 + sin(i) + cos(i/3)`, crates.io `deep_causality_core 0.10.0` / `deep_causality_data_structures 0.10.14`, the versions the NIF ships):

| variant | ns/op | evals/sec/core | meaning |
|---|---|---|---|
| A | ~354 | ~2.8 M | DeepCausality `SlidingWindow` + O(window) two-pass recompute (today's NIF compute) |
| B | ~9.8 | ~102 M | DeepCausality `SlidingWindow` + O(1) Welford (proposed) |
| C | ~9.6 | ~105 M | raw ring buffer + O(1) Welford (floor, no DeepCausality) |
| D | ~24.8 | ~40 M | `CausalFlow` wrapper + O(1) Welford (idiomatic per-sample flow) |

Elixir end-to-end (OTP 28, 10 cores): production `owner` ~50k/s; `reasoner` (NIF only) ~140k/s; `compact` single 5.7–9.4M/s; `compact_shards` 13.2M/s (tight loop); `compact_ets_shards` 2.0M/s (realistic per-series ETS state).

Conclusions:
- **DeepCausality is not the bottleneck.** B vs C = 1.02× (~0.2 ns); the `SlidingWindow` is effectively free.
- **The cost is the O(window) recompute.** A vs B = ~36×. Welford erases it.
- **FFI is the only real constraint.** A per-sample NIF caps near ~1M/s (FFI ~1 µs/call). Batching ~1k samples/crossing amortizes FFI to ~1 ns/sample → compute-bound at ~100M/s/core — ~8× a whole 10-core Elixir shard, ~50× the realistic ETS-distributed path, ~2000× production.
- **Accuracy bonus.** At 1e9 magnitude the naive two-pass variance (A) diverges ~1e-6 from Welford via catastrophic cancellation; B/C/D agree to the bit. Welford fixes speed and accuracy.

## Decisions

### 1. Welford lives in the NIF's `DetectorState`, stateless across calls
`CausalFlow` threads an arbitrary State struct (no `Clone`/`Default` bound at step level), so add `WelfordAcc{count: usize, mean: f64, m2: f64}` to `DetectorState`. The reasoner stays stateless across calls (Marvin's "ship the immutable context to round-robinnable instances"): the caller passes the accumulator in via `ReasonContext` and the NIF returns the updated accumulator in the verdict. `finish()` returns only the value channel and **drops State**, so `finalize_detector_verdict` must fold `next_acc` (and `next_window_tail`) into the returned value — exactly how `next_consecutive_anomalous` is already threaded out today.

### 2. Eviction via `SlidingWindow.first()` before `push()`
`SlidingWindow::push` returns `()` and silently drops the oldest; read `window.first()` (the oldest = next evict) **before** `push()`, but only once `window.filled()`. Before fill, push evicts nothing, so only `welford_add` runs. Welford math is ported byte-for-byte from `compact_evaluator.ex` (`add`: `n=count+1; d=v−mean; mean+=d/n; m2+=d*(v−mean_new)`; `remove`/West deletion: `n=count−1; mean=(count*mean−v)/n; m2−=(v−mean_old)*(v−mean_new)`; clamp `m2 ≥ 0`).

### 3. Bounded window tail, not the full baseline list, on the wire
`ReasonContext.baseline: Vec<f64>` (the whole window) is replaced for the rolling signal by `{acc: WelfordAcc, window_tail: Vec<f64>}` bounded by `window_size` (needed only for the eviction value and for rebuild). Seasonal/trend signals keep passing arrays for now (low cardinality; migrate later). Elixir per-series state shrinks from a growing list to `{count, mean, m2, window_tail, consecutive}`.

### 4. `reason_batch` is mandatory, not optional
Add `reason_batch(Vec<(SeriesState, Sample)>) -> Vec<Verdict>` (regular NIF if per-batch < ~1 ms, else DirtyCpu). Batch on the message/shard boundary, not per series. Keep `reason/2` for single-shot and for `ContextOwner.rebuild_from` (out-of-order replay, which still needs the ordered sample log in Elixir — replay it through `reason_batch`).

### 5. Keep `CausalFlow` per-sample (idiomatic), bare-loop only if profiling demands it
D (40M/s) is ~20× the realistic target and keeps the per-series reasoner expressed as a flow — the home for future seasonal/trend/corrective causaloids. Keep it. If a future profile shows the ~15 ns wrapper dominates after batching, the inner loop can call the bare Welford+window path (B, 102M/s) and reserve `CausalFlow` for orchestration. Either is far above need; do not over-optimize prematurely.

### 6. Sharding/ETS/Horde stay in Elixir, unchanged
The NIF is per-series stateless; distribution (Horde registry, single-writer `ContextOwner`, Broadway concurrency, shard partitioning) is a BEAM concern and is untouched. Only the stored row shrinks.

### 7. Parity is the acceptance gate
Preserve exactly: sample variance with `(n−1)` divisor; `z = |(x−mean)/stddev|` with the zero-variance guard (return `n_sigma+1.0` on non-zero deviation, else `0.0`); `breach = score ≥ n_sigma`; `include_in_baseline = !breached`; consecutive increment/reset and confirm-slot hysteresis; `insufficient_baseline` gate at `count < min_samples` OR `count < 2`; non-finite drop. The existing Rust test oracle plus a new incremental-vs-two-pass property test (random in-order streams within f64 tolerance) gate the change.

## Risks / mitigations

- **Windowed Welford-remove (West) drift** over millions of evictions: clamp `m2 ≥ 0` (as compact already does) plus a periodic full-slice recompute (e.g. on `count < 2` or every N evictions) or Kahan compensation. Simulated drift over 200k evictions at 1e9: `|Δz| ≈ 3e-5` — negligible at `n_sigma=3`, but bound it.
- **Out-of-order ingestion**: pure accumulator threading is in-order only; keep the ordered sample log in Elixir for `rebuild_from`, replayed through `reason_batch`.
- **No library stats primitive**: verified DeepCausality ships none (algorithms = BRCD/SURD/mRMR, metric = Clifford signatures, uncertain = Monte-Carlo batch). We own the Welford math inside the causaloid; the win is the Flow + `SlidingWindow` primitives, not a built-in detector.

## Alternatives considered

- **Keep two implementations (Elixir compact + NIF), parity-tested.** Rejected: the parity burden is exactly what produced the variance bug; it scales poorly as seasonal/trend/corrective signals are added.
- **A pure-Elixir anomaly engine, retire the NIF.** Rejected: abandons the DeepCausality causal model and Marvin's guidance, and FFI was never the issue once batched — the Elixir path is also slower than batched-NIF compute.
- **Leave the NIF O(window) and just shard harder.** Rejected: 50k→production scale needs the 36× per-sample win; sharding multiplies a too-slow per-core number.
