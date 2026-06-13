## Context
The current NIF boundary accepts a full `baseline` list in `ReasonContext`. On every sample, Rustler decodes that list, the NIF rebuilds a `SlidingWindow`, and the detector recomputes mean/stddev over the full rolling window. This is semantically simple, but it makes the hot path proportional to window size and copies data across the BEAM/NIF boundary for every evaluation.

`CompactEvaluator` was added to prove that a bounded ring plus Welford state can produce equivalent rolling-z verdicts in O(1). That proof should not become a second engine. The same state model should be folded into the DeepCausality NIF so future work extends one reasoner.

## Benchmark Evidence
Issue `fj #3796` includes the benchmark evidence that justifies this refactor. Rust microbenchmarks used in-process evaluation with no FFI, a window size of 300, and 5M in-order samples around `1e9 + sin(i) + cos(i / 3)` against the DeepCausality versions shipped by the NIF.

| Path | ns/op | evals/sec/core | Meaning |
|---|---:|---:|---|
| DeepCausality `SlidingWindow` plus O(window) two-pass recompute | ~354 | ~2.8M | Current NIF compute shape |
| DeepCausality `SlidingWindow` plus O(1) Welford | ~9.8 | ~102M | Proposed compute shape |
| Raw ring buffer plus O(1) Welford | ~9.6 | ~105M | Lower-bound comparison without DeepCausality |
| `CausalFlow` wrapper plus O(1) Welford | ~24.8 | ~40M | Idiomatic per-sample flow shape |

Elixir end-to-end measurements from the same issue show the current production `owner` path around 50k evaluations/sec, the per-sample reasoner NIF around 140k evaluations/sec, `CompactEvaluator` single-core around 5.7M to 9.4M evaluations/sec, compact shards around 13.2M evaluations/sec, and compact ETS shards around 2.0M evaluations/sec.

The conclusion is specific: DeepCausality itself is not the bottleneck. The raw ring and DeepCausality `SlidingWindow` Welford paths are within about 2 percent of each other. The large win comes from removing the O(window) recompute, and the remaining BEAM/NIF overhead is handled by batching rather than by keeping a second Elixir detector.

## Relationship To Evaluation Cadence
The active `update-anomaly-evaluation-cadence` proposal already requires compact incremental state as part of the high-scale anomaly path. This proposal narrows where that compact state lives: inside the DeepCausality-backed NIF and its value contract, not in `CompactEvaluator`.

`update-anomaly-evaluation-cadence` still owns slot aggregation, metric-class evaluation cadence, shard ownership, and the broader canonical metric-pipeline work. This proposal satisfies the reasoner hot-path portion of that design and removes the parallel evaluator once parity and throughput are proven.

## Goals / Non-Goals
- Goals:
  - Keep DeepCausality as the single authoritative anomaly reasoner.
  - Preserve existing verdict semantics: readiness, sample variance, z-score thresholding, anomalous sample withholding, and sustained confirmation.
  - Make rolling evaluation O(1) with respect to the baseline window.
  - Reduce BEAM/NIF copy overhead by passing compact state and supporting batch evaluation.
  - Provide parity, drift, and benchmark gates before removing the compact evaluator.
- Non-Goals:
  - Replacing DeepCausality with an Elixir-only detector.
  - Adding a mutable native resource that owns long-lived production state in Rust.
  - Changing metric extraction, counter normalization, or evaluation cadence in this proposal.
  - Rewriting seasonal/trend signal semantics beyond keeping them compatible with the current reasoner.

## Decisions

### Decision 1: The NIF carries rolling Welford state through value maps
`ReasonContext` will accept a compact rolling state:

- `rolling_acc`: `%{count: non_neg_integer(), mean: float(), m2: float()}`
- `window_tail`: bounded list of clean values in admission order
- `consecutive_anomalous`: existing sustained-confirmation state

`ReasonVerdict` will return the next `rolling_acc`, next `window_tail`, and next `consecutive_anomalous`. Elixir remains the owner of durable state and checkpoints. The NIF stays stateless across calls except for values passed in and out of each call.

The implementation must account for the DeepCausality flow contract: `finish()` returns the value channel and drops State. Any next-state fields that Elixir needs, including `next_rolling_acc` and `next_window_tail`, must be folded into the verdict value before `finish()`, the same way `next_consecutive_anomalous` is surfaced today.

This avoids lifecycle and crash-recovery complexity from native resources while still removing the full baseline rebuild from the hot path.

### Decision 2: Welford add and West removal are the rolling-stat primitive
The NIF will update `rolling_acc` with numerically stable Welford addition and West deletion when the bounded window evicts an old clean value. The variance used for z-score evaluation remains sample variance: `m2 / (count - 1)`.

The implementation must guard non-finite samples, `count < min_samples`, `count < 2`, and zero/non-finite stddev exactly enough to preserve current verdict semantics.

### Decision 3: Admission happens only on the clean branch
The rolling signal evaluates against the current clean baseline before the new sample is admitted. If the sample breaches, it is withheld from `window_tail` and `rolling_acc`; if clean, it is appended and the oldest value is removed when the configured `window_size` is exceeded.

This keeps the existing causal flow shape and prevents anomalous samples from teaching the baseline.

### Decision 4: Batch evaluation amortizes Rustler overhead
The NIF will expose `reason_batch` for a list of independent evaluation inputs. The Elixir wrapper will normalize inputs and return one result per input in the same order.

The batch API is intended for Broadway/shard boundaries where many series are available at once. Per-series ordering remains the caller's responsibility; the NIF treats each pair as an independent state transition and returns each next state.

The scheduler choice must be measured. If the tuned batch size can exceed the normal scheduler budget, `reason_batch` must run as `DirtyCpu`; otherwise it may use the normal scheduler. The proposal expects tuning around approximately 1k evaluations per batch, but benchmarks decide the final default.

### Decision 5: Keep CausalFlow unless profiling proves it dominates
The implementation should keep the per-sample reasoner expressed as a `CausalFlow`. The benchmarked flow wrapper path is around 40M evaluations/sec/core, which is already far above the current production and realistic ETS-distributed paths while preserving the idiomatic home for future causal, seasonal, trend, and corrective logic.

A bare loop around Welford and `SlidingWindow` can be considered later if a post-batching profile shows the approximately 15 ns flow wrapper cost dominates real workloads. That optimization is not part of the first implementation.

### Decision 6: Two-pass statistics remain as an oracle, not the hot path
The NIF will keep a two-pass rebuild path for tests, debug assertions, or explicit validation. Property tests and synthetic large-counter datasets will compare incremental Welford state against that oracle.

Periodic full recompute or compensated recompute may be added if benchmarks show drift over long eviction streams. Any recompute must be bounded and observable so it does not silently reintroduce O(window) work per evaluation.

### Decision 7: CompactEvaluator is temporary scaffolding
`CompactEvaluator` and compact-specific benchmark modes exist only until the DeepCausality NIF path proves parity and throughput. After that, production code, tests, and benchmarks should exercise the DeepCausality reasoner path rather than maintaining a second rolling-z implementation.

## Risks / Trade-offs
- Risk: incremental removal math diverges from the old two-pass detector for large counters.
  - Mitigation: add Rust and ExUnit parity tests with streams near `1e9`, random eviction windows, and bounded z-score drift assertions.
- Risk: returning compact state through maps still allocates at high batch rates.
  - Mitigation: use batch evaluation first, then profile whether an owned native state resource is justified under a separate proposal.
- Risk: scheduler misuse can harm BEAM latency.
  - Mitigation: benchmark realistic batch sizes and use `DirtyCpu` whenever batches can exceed the normal NIF budget.
- Risk: state migration from full `baseline` lists to compact state can break replay/rebuild.
  - Mitigation: maintain legacy baseline decoding during migration and rebuild compact state from ordered sample logs with `reason_batch`.

## Migration Plan
1. Add compact state fields to the NIF structs while continuing to accept the existing `baseline` list.
2. Build compact state from `baseline` only when `rolling_acc`/`window_tail` is missing.
3. Return next compact state in verdicts and update Elixir context normalization/types.
4. Update `ContextOwner` checkpoint state to persist compact rolling state and bounded tail.
5. Add `reason_batch` and wire the high-cardinality/shard path to use it.
6. Run parity, drift, synthetic dataset, and benchmark gates against both old list and new compact NIF paths.
7. Remove `CompactEvaluator` and its benchmark modes once the DeepCausality path is accepted.
