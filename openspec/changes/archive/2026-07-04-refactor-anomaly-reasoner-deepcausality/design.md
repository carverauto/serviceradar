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

## Implementation Benchmark Results
Local verification on 2026-06-13 used:

```bash
ANOMALY_BENCH_SERIES=1000 \
ANOMALY_BENCH_BASELINE=300 \
ANOMALY_BENCH_WINDOW=300 \
ANOMALY_BENCH_ANOMALY=5 \
ANOMALY_BENCH_CONCURRENCY=10 \
ANOMALY_BENCH_BATCH_SIZE=1000 \
MIX_ENV=test mix run --no-start bench/anomaly_detection_scale.exs
```

The synthetic workload produced 305,000 evaluations per mode. All modes confirmed
3,000 sustained anomalies with zero failed series.

| Mode | Evaluations/sec | Memory delta MB | Notes |
|---|---:|---:|---|
| `owner` | 40,857 | 0.33 | Production `ContextOwner` plus DeepCausality NIF path |
| `legacy_list` | 145,124 | -2.48 | Old list-shaped NIF context baseline |
| `reasoner` | 141,474 | -2.68 | Per-sample compact NIF state with empty `baseline` |
| `reasoner_batch` | 154,564 | -2.63 | Batch size 1000, `DirtyCpu` scheduler |
| `compact` | 4,095,554 | -2.21 | Temporary Elixir compact evaluator baseline |
| `compact_shards` | 11,292,950 | -2.32 | Temporary sharded compact evaluator baseline |
| `compact_ets_shards` | 2,000,341 | -2.18 | Temporary ETS sharded compact evaluator baseline |

Batch-size sweep for `reasoner_batch` on the same workload:

| Batch size | Evaluations/sec |
|---:|---:|
| 1 | 92,462 |
| 10 | 114,195 |
| 100 | 136,110 |
| 1000 | 159,425 |

These results validate the correctness path and show that batching improves the
Rustler boundary, but the map/list value contract still caps throughput well
below the pure Elixir compact evaluator. The dominant remaining costs are BEAM
process ownership for `owner` and value transfer of the bounded `window_tail`
plus verdict maps for the NIF modes. `reason_batch` remains `DirtyCpu` because
tuned batches can contain 1000 evaluations and exceed a normal scheduler budget.

The temporary compact evaluator is still removed by this proposal because it is a
parallel detector implementation. The implementation therefore moves the
multi-million-evaluations/sec state model into the DeepCausality NIF itself by
adding native shard resources and sparse state-change output. Future attempts to
push beyond the current tuple/resource path should change the same reasoner
contract, for example with columnar or binary sample input, instead of keeping
two reasoners alive.

## Final Implementation Benchmark Results
The approved implementation moved beyond the initial value-map plan and added
native shard resources plus sparse state-change output. Local production-mode
verification on 2026-06-13 used the same 1,000-series, 300-clean-sample,
5-anomaly-sample workload with 10 shards and `MIX_ENV=prod`.

| Mode / cut | Evaluations/sec | Notes |
|---|---:|---|
| `sharded_engine_events` | ~108k | GenServer shard owners, sparse events |
| `reasoner_state_values_changes_shards` | ~1.68M | Direct native resource with compact map inputs |
| `reasoner_state_value_tuples_changes_shards` | ~1.69M-2.25M | Direct native resource with compact tuple inputs and no per-sample input map; latest repeat was ~2.02M |
| `native_engine_events` | ~0.73M-0.90M | Opt-in native engine from sample maps through tuple NIF input and sparse events |

Additional measured cuts:

- Sequential shard calls were rejected: they dropped the production engine to
  about 389k evaluations/sec because losing DirtyCpu parallelism cost more than
  task fanout.
- Prepared map inputs were rejected: bypassing wrapper normalization exposed the
  strict Rustler `NifMap` contract and measured slower after adding strict
  context construction.
- Numeric series IDs were tested in the engine path and were slower than string
  series keys because the ETS id lookup/allocation cost outweighed the Rust
  `HashMap<String, _>` cost for this workload.
- Removing an unused native `SlidingWindow` object from `DetectorState` was kept:
  the detector uses Welford state and the bounded clean tail directly, so the
  extra window allocation/update was not part of verdict semantics.

The current direct NIF ceiling is above 2M evaluations/sec on this workstation.
The remaining gap in opt-in `native_engine_events` is primarily outside the
DeepCausality math: rich Elixir sample maps, per-series first-context checks,
shard bucketing, task fanout, and sparse result re-association. The next
architecture step toward the earlier 10M+ target is not another map-shaped NIF
shim; it is a columnar/binary or upstream compact sample path that avoids
constructing one rich Elixir map per scalar sample.

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
  - Treating Rust runtime detector state as durable state without checkpoint/replay semantics.
  - Changing metric extraction, counter normalization, or evaluation cadence in this proposal.
  - Rewriting seasonal/trend signal semantics beyond keeping them compatible with the current reasoner.

## Decisions

### Decision 1: The NIF owns compact rolling state through two contracts
`ReasonContext` accepts compact rolling state:

- `rolling_acc`: `%{count: non_neg_integer(), mean: float(), m2: float()}`
- `window_tail`: bounded list of clean values in admission order
- `consecutive_anomalous`: existing sustained-confirmation state

For compatibility, replay, tests, and checkpoint rebuilds, `ReasonVerdict`
returns the next `rolling_acc`, next `window_tail`, and next
`consecutive_anomalous`. Elixir remains the owner of durable state and
checkpoints.

For the streaming hot path, the NIF also exposes shard-local native resources
that store the same state in Rust and return sparse anomaly-open/anomaly-clear
events. These resources are runtime acceleration state, not durable truth. They
must be recoverable from the compact value state and ordered samples maintained
outside the NIF.

The implementation must account for the DeepCausality flow contract: `finish()` returns the value channel and drops State. Any next-state fields that Elixir needs, including `next_rolling_acc` and `next_window_tail`, must be folded into the verdict value before `finish()`, the same way `next_consecutive_anomalous` is surfaced today.

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

### Decision 8: Native shard resources are opt-in until recovery is complete
The streaming anomaly pipeline keeps the checkpointed owner-backed
`ContextEngine` as the default engine. Operators can opt into shard/native paths
with `ANOMALY_ANALYSIS_CONTEXT_ENGINE=sharded` or
`ANOMALY_ANALYSIS_CONTEXT_ENGINE=native` while the native runtime state recovery
contract is finalized.

The native paths store per-series Welford state, bounded clean tail,
confirmation count, and active anomaly state in Rust resources. They return only
anomaly-open and anomaly-clear state changes, so clean non-events do not cross
the BEAM boundary as verdict maps.

This state is hot runtime state, not durable truth. Durable replay and
checkpointing remain Elixir/CNPG responsibilities. The owner-backed default is
the rollback/recovery path until native checkpoint restore can prove that open
anomalies clear correctly and warm baselines survive process restart.

### Decision 9: Compact tuple input is the current BEAM/NIF contract
The production shard path passes `{index, series_key, context | nil, value,
observed_at_unix_nano}` tuples to the NIF instead of one map per sample. The map
API remains for compatibility and tests, but the tuple path is the measured hot
path because it raises the direct native-resource ceiling from about 1.68M for
map inputs to roughly 1.69M-2.25M evaluations/sec for tuple inputs on the
benchmark workload.

## Risks / Trade-offs
- Risk: incremental removal math diverges from the old two-pass detector for large counters.
  - Mitigation: add Rust and ExUnit parity tests with streams near `1e9`, random eviction windows, and bounded z-score drift assertions.
- Risk: returning compact state through maps still allocates at high batch rates.
  - Mitigation: keep map state as the compatibility/checkpoint contract and use native shard resources plus tuple inputs for the production hot path.
- Risk: scheduler misuse can harm BEAM latency.
  - Mitigation: benchmark realistic batch sizes and use `DirtyCpu` whenever batches can exceed the normal NIF budget.
- Risk: state migration from full `baseline` lists to compact state can break replay/rebuild.
  - Mitigation: maintain legacy baseline decoding during migration and rebuild compact state from ordered sample logs with the DeepCausality reasoner.

## Migration Plan
1. Add compact state fields to the NIF structs while continuing to accept the existing `baseline` list.
2. Build compact state from `baseline` only when `rolling_acc`/`window_tail` is missing.
3. Return next compact state in verdicts and update Elixir context normalization/types.
4. Update `ContextOwner` checkpoint state to persist compact rolling state and bounded tail.
5. Add `reason_batch` for independent batch callers and native shard-resource tuple APIs for the streaming high-cardinality path.
6. Gate native shard engines behind `ANOMALY_ANALYSIS_CONTEXT_ENGINE` until native checkpoint restore is implemented.
7. Run parity, drift, synthetic dataset, and benchmark gates against both old list and new compact NIF paths.
8. Remove `CompactEvaluator` production/test call sites once the DeepCausality path is accepted, while keeping benchmark modes that compare accepted and rejected DeepCausality cuts.
