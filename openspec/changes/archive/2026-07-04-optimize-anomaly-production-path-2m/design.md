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

Follow-up implementation work through PR #3828 has closed the operational
hardening prerequisites and several production-wrapper cuts:

| Cut | Status | Notes |
|---|---|---|
| Benchmark phase instrumentation | Accepted | Reports batch preparation, sample lookup, native evaluation, eviction, marking, and re-association timing. |
| Persistent per-shard workers | Accepted | Replaced per-batch fanout with shard workers while preserving per-shard restart/fault isolation. |
| Deferred SeenEvents pruning | Accepted | Moved expensive pruning off the hot evaluate call and made retention TTL-driven. |
| Compact event tuple input | Accepted | Adds `{index, series_key, event_key, value, observed_at, config}` compatibility path with redelivery idempotency. |
| Shard-ready prepared batches | Accepted | Adds `evaluate_prepared_shard_batches/1` for callers that already partition inputs by shard. |
| Numeric ID lookup in the BEAM hot loop | Rejected | Measured slower than string-key shard state because the lookup/allocation cost outweighed native savings. |
| Detector-local packed-binary input | Rejected for now | Prototype was faster at 50k series (+~9%) but slower at 100k series (-~10%) because BEAM-side packing cost dominated; lower memory does not justify shipping a second NIF ABI. |
| Protobuf JetStream metric envelope | Proposed follow-up | More promising serialization boundary because producers can encode source-neutral metrics once and consumers can decode directly without JSON/map churn. |
| Columnar/Arrow handoff | Deferred | Useful for offline replay, DuckDB/object-storage analytics, and long-horizon forecasting, not required for the realtime detector hot path or CNPG operational storage. |

The latest focused verification also adds a benchmark correctness gate: synthetic
throughput runs now fail if `failed_series != 0` or if the confirmed anomaly
count does not match the workload. This prevents a faster but semantically empty
path from satisfying the performance gate.

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
  - Expose production anomaly throughput, latency, drops, failures, and sparse
    output volume through low-cardinality telemetry suitable for Prometheus.
- Non-Goals:
  - Moving hot detector state into CNPG, pgvector, or any synchronous DB path.
  - Replacing CNPG/Timescale as the operational hot/warm metrics datastore.
  - Adding a columnar datastore for the realtime anomaly path.
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

### Decision 3: Detector-local binary input is not selected
Tuple inputs still decode one BEAM term per sample, so a packed-binary NIF input
was prototyped. The result was mixed:

- 50k series, 12 baseline, 3 anomaly, 16 shards: tuple prepared-shard path
  ~1.06M eval/s; packed binary ~1.15M eval/s.
- 100k series, same shape: tuple prepared-shard path ~1.00M eval/s; packed
  binary ~0.89M eval/s.

The binary path reduced memory but did not consistently improve throughput
because the Elixir side still had to pack the binary before crossing into Rust.
Shipping that path would add a detector-specific binary ABI without proving it
is the production bottleneck.

The next serialization boundary to evaluate is the JetStream metric envelope:
source producers can publish a canonical protobuf metric event once, and the
EventWriter/anomaly consumers can decode directly into their own representations.
That is more likely to remove JSON/map churn end-to-end than packing a
detector-only record inside the BEAM.

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

### Decision 7: Batch telemetry is required for production visibility
The anomaly engine emits one telemetry event per evaluated batch with bounded
metadata tags only: engine and path. Measurements include duration, input
samples, evaluated samples, emitted sparse events, duplicate drops, validation
drops, failed samples, and output result count.

These events are exposed through the existing `Telemetry.Metrics` definitions so
Prometheus-compatible reporters can graph production throughput and failure
pressure over time without high-cardinality labels such as series key, device
id, subject, or metric name.

## Risks / Trade-offs
- Risk: compact inputs lose metadata needed for finding emission.
  - Mitigation: compact samples carry an index/correlation token so sparse events
    can recover the original sample metadata only for open/clear events; the
    same token is used for idempotent redelivery protection.
- Risk: a detector-local binary input makes the NIF contract harder to evolve.
  - Mitigation: reject the packed-binary prototype until profiling proves it is
    consistently faster in the production wrapper; prefer canonical protobuf at
    the JetStream metric-envelope boundary.
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
5. Emit low-cardinality anomaly batch telemetry and expose it through
   `Telemetry.Metrics`.
6. Record the packed-binary NIF prototype as rejected for now and remove it from
   the production branch.
7. If serialization remains hot after telemetry/profiling, create a separate
   protobuf JetStream metric-envelope proposal that preserves CNPG/EventWriter as
   consumers of the same canonical metric event.
8. Run warm-series, cold-series, and mixed-series benchmarks with the 2M eval/s
   gate.
9. Update OpenSpec results and task status with accepted/rejected cuts and
   measured bottlenecks.
