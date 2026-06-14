## Context
The previous `refactor-anomaly-reasoner-deepcausality` change moved rolling
anomaly evaluation into one DeepCausality-backed Rust NIF path with Welford
state, native shard resources, tuple inputs, and sparse state-change output.

That work established two useful numbers on the same local synthetic workload
of 1,000 series, 300 clean baseline samples, 5 anomalous samples, and 10 shards:

| Path | Throughput | Meaning |
|---|---:|---|
| Direct native shard tuple path | ~1.69M-2.25M eval/s | NIF/runtime ceiling with compact tuple input |
| Opt-in `NativeContextEngine` path | ~0.73M-0.90M eval/s | Current wrapper path through rich sample maps |

The remaining gap is mostly outside DeepCausality math. The production path still
accepts rich sample maps, derives shard inputs from those maps, checks first-seen
context through ETS, fans out via `Task.async_stream`, sorts sparse results back
to original input order, and decodes one tuple term per sample. Small tuning in
that shape will not reliably produce 2M eval/s.

This proposal assumes the preceding `refactor-anomaly-reasoner-deepcausality`
implementation has landed its operational hardening first: native/sharded
engines are opt-in behind `ANOMALY_ANALYSIS_CONTEXT_ENGINE`, redelivered samples
do not double-fold committed Welford state, shard calls preserve single-writer
access, high-cardinality series state is bounded, and Welford eviction drift is
periodically corrected from the bounded clean tail. Any optimization in this
change must preserve those guarantees.

## Goals / Non-Goals
- Goals:
  - Reach at least 2M production-path evaluations/sec on the existing synthetic
    benchmark profile, or produce a measured bottleneck report explaining the
    next limiting component.
  - Keep DeepCausality-backed `CausalReasoner` as the only rolling anomaly
    detector.
  - Preserve readiness, baseline admission, sample variance, threshold,
    confirmation, and sparse open/clear semantics.
  - Eliminate avoidable per-sample Elixir map allocation and per-sample hot-path
    ETS lookups from production anomaly evaluation.
  - Keep all metrics flowing through JetStream/event_writer; this is an
    analysis-path optimization only.
- Non-Goals:
  - Moving hot detector state into CNPG, pgvector, or any synchronous DB path.
  - Replacing DeepCausality with a separate detector implementation.
  - Changing canonical metric semantics, counter normalization, or evaluation
    cadence. Those remain owned by the existing metric pipeline and cadence
    proposals.
  - Returning verdict maps for clean samples in production.

## Decisions

### Decision 1: Production input becomes compact before the engine boundary
The production anomaly pipeline SHALL build compact sample batches before calling
`NativeContextEngine`. The compact representation includes only the data needed
for the native shard call:

- original input index or opaque correlation/idempotency token,
- shard id,
- series identity or native series id,
- scalar value,
- observed timestamp,
- optional first-context fields for new series.

Rich sample maps may still exist for compatibility, tests, and event emission,
but they are not the hot-path transport format into the native evaluator.

The correlation token is not just for output re-association. It must be stable
for JetStream redelivery of the same sample and must be used to avoid applying an
already-committed sample to native Welford state a second time.

### Decision 2: Shard-ready batches replace engine-local grouping
The current engine groups arbitrary samples by shard on every call. The optimized
path moves that grouping upstream, so the engine can receive a list of
already-partitioned shard batches. This removes repeated hash/group/sort work and
allows larger shard-local NIF calls.

The compatibility `evaluate_events_batch/1` API remains, but the benchmarked
production path must exercise the shard-ready compact API.

Shard-ready does not mean concurrently calling the same shard resource from
multiple Broadway processors. Each native shard must still have one writer at a
time, either by routing through a shard owner process or by an equivalent
serialized execution boundary. Larger batches must reduce lock churn, not turn
native `try_lock` errors into redelivery loops.

### Decision 3: Columnar or binary NIF input is benchmark-gated
Tuple inputs are useful but still decode one BEAM term per sample. The
implementation SHALL benchmark at least one lower-overhead input contract:

- columnar lists/arrays: indexes, values, timestamps, and series identifiers in
  separate vectors;
- packed binary input: fixed-width numeric columns for index/value/timestamp and
  a separate first-seen/string table;
- hybrid input: strings only on first series observation, numeric IDs afterward.

The selected contract is the fastest measured correct path. It must not require
per-sample ETS lookup to translate series keys into numeric IDs.

### Decision 4: Numeric IDs only help if lookup is outside the hot loop
The prior numeric-series experiment was slower because the engine paid ETS
lookup/allocation cost per sample. This proposal allows numeric series IDs only
when one of these is true:

- the ID is already present on the compact sample before the anomaly hot loop;
- the native shard interns the series key once and returns/uses an ID afterward;
- the batch includes a side table of new series keys plus numeric sample columns.

Numeric IDs are rejected if they require a per-sample BEAM-side lookup in the
evaluation loop.

Any native series-id intern table is part of shard runtime state and must be
bounded by the same `max_series`/eviction policy as the detector state. Evicting
a series must drop its detector state, active-state marker, recent idempotency
tokens, and any native string-to-id/id-to-state mapping together.

### Decision 5: Sparse output stays mandatory
The production path returns only anomaly-open and anomaly-clear events. Clean
non-events stay inside native shard state. Debug or parity modes may return full
verdicts, but those modes are not the benchmarked production target.

### Decision 6: The 2M target is a benchmark gate, not a semantic invariant
The target is 2M production-path evaluations/sec on the existing local synthetic
profile. This number belongs to the change gate and benchmark report, not the
long-lived anomaly-detection spec semantics.

If the implementation cannot hit that target, the benchmark report must show
where the time is going, such as compact batch construction, shard fanout, NIF
decode, native lock contention, series lookup/interning, idempotency checks, or
sparse result re-association.

## Risks / Trade-offs
- Risk: compact inputs lose metadata needed for finding emission.
  - Mitigation: compact samples carry an index/correlation token so sparse events
    can recover the original sample metadata only for open/clear events; the
    same token is used for idempotent redelivery protection.
- Risk: columnar/binary input makes the NIF contract harder to evolve.
  - Mitigation: keep the map/tuple APIs as compatibility/debug paths and version
    any packed binary format.
- Risk: moving shard grouping upstream couples pipeline stages to native engine
  internals.
  - Mitigation: define a small project-owned compact batch struct/API instead of
    exposing raw NIF argument shape across the application.
- Risk: first-seen context handling becomes a hidden bottleneck.
  - Mitigation: benchmark cold-series and warm-series profiles separately and
    ensure warm-series steady state has no per-sample ETS lookup.
- Risk: native series ID interning creates a new unbounded map.
  - Mitigation: require shard-local intern tables to share detector-state
    eviction and max-series accounting.
- Risk: larger shard-local batches hold native resources longer.
  - Mitigation: preserve one writer per shard and report native lock contention
    separately in benchmark instrumentation.

## Migration Plan
1. Add instrumentation to split production benchmark time across sample
   preparation, shard grouping, NIF evaluation, and result re-association.
2. Introduce a compact anomaly batch struct/API and adapt the benchmark harness
   to generate compact batches directly.
3. Add a shard-ready engine API that accepts compact shard batches while keeping
   `evaluate_events_batch/1` compatibility.
4. Carry the compact correlation token through idempotency checks before native
   state application and through sparse event metadata recovery after native
   evaluation.
5. Implement and benchmark columnar, packed-binary, and/or hybrid native input
   contracts against the tuple baseline.
6. Select the fastest correct contract and wire it into the production path.
7. Run warm-series, cold-series, and mixed-series benchmarks with the 2M eval/s
   gate.
8. Update OpenSpec results and task status with accepted/rejected cuts and
   measured bottlenecks.
