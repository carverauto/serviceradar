## Context
The anomaly detector currently treats every incoming metric sample as an evaluation event. That is simple and correct for low-cardinality streams, but it is the wrong scaling shape for large deployments. At 50k agents and 200 metric series per agent, a 10-second evaluation cadence implies 1M series evaluations/sec before counting raw samples inside each interval. If raw metric samples arrive more frequently than the evaluation cadence, per-sample evaluation spends CPU on redundant intermediate values.

The current implementation also passes baseline lists through the reasoner boundary and rebuilds window statistics for each sample. That makes the cost proportional to the window size and creates avoidable allocation/copy pressure on the hot path.

Issue `fj #3788` adds a separate but related finding: the metric pipeline currently fragments equivalent metrics before they ever reach the detector. A CPU utilization value may arrive as sysmon JSON, plugin-result metrics, or OTLP metrics, with different subjects, schemas, storage sinks, and series-identity recipes. That fragmentation makes high-scale anomaly detection both slower and less correct: the same physical signal can become multiple unrelated anomaly series, while `kind`, `temporality`, and `unit` are missing or discarded.

## Goals / Non-Goals
- Goals:
  - Preserve the current anomaly semantics: learned baseline, anomalous samples withheld from baseline, and confirmation over consecutive evaluation slots.
  - Separate raw sample intake rate from detector evaluation rate.
  - Keep all metrics on JetStream first; `event_writer` remains the persistence path.
  - Normalize all first-class metrics into one metric contract before anomaly extraction.
  - Preserve metric `kind`, `temporality`, `unit`, resource identity, and point attributes through extraction.
  - Support a credible path to 1M detector evaluations/sec and higher raw sample intake when rollups are enabled.
  - Bound memory per active metric series and per shard.
- Non-Goals:
  - Dropping raw samples before persistence.
  - Moving metric ingestion out of JetStream or writing metrics directly to CNPG.
  - Treating raw metric time-series as OCSF events.
  - Replacing the existing anomaly finding and capacity UI surfaces.
  - Implementing edge-side anomaly detection in this change.

## Decisions

### Decision 1: Evaluate per configured slot, not necessarily per raw sample
The anomaly engine SHALL aggregate raw metric samples into per-series evaluation slots. Each slot produces one representative value for the detector. The default slot duration may match the incoming cadence for compatibility, but high-volume deployments can set a longer evaluation interval.

Raw samples continue to flow through JetStream and are persisted by `event_writer`; the slot aggregator is an analysis consumer, not the storage path.

### Decision 0: Canonical metric contract is prerequisite to correct scale
The platform SHALL treat metrics as a first-class signal, not as values smuggled inside status/check-result/plugin-result envelopes. The canonical contract is `serviceradar.metric.v1` evolved additively with `schema_version`, `resource`, `name`, `kind`, `temporality`, `is_monotonic`, `unit`, `points[]`, `thresholds`, `ingress_id`, `ingress_timestamp_unix_nano`, and gateway-attested `ingest_identity`.

The `add-protobuf-metric-envelope` change supersedes the earlier legacy flat-envelope migration path: there is no long-lived dual-accept mode for version-1 JSON gauge envelopes. Producers that currently emit sysmon, SNMP, ICMP, MTR, sweep, rperf, wasm plugin, native add-on, or plugin-result metrics migrate onto the canonical metric path. Raw OTLP metrics may stay as a high-fidelity express lane only if the anomaly extractor receives equivalent normalized point identity and kind/temporality semantics.

OCSF remains the event/finding layer. Raw metric time-series SHALL NOT be forced into OCSF classes; anomaly and capacity Findings derived from metrics continue to use OCSF.

### Decision 2: Use spike-preserving aggregation by metric class
The slot aggregator MUST preserve operationally meaningful spikes. Suggested defaults:
- CPU, memory, disk utilization: max within the slot.
- Interface/flow byte rates: max or sum depending on whether the normalized metric is a rate or count.
- RED latency/error metrics: max for latency/error rate, sum for request counts where the downstream metric is a count.

Each emitted evaluation sample includes slot start/end, aggregation mode, contributing raw sample count, and source metric identity.

### Decision 2A: Kind and temporality drive sample extraction
The anomaly extractor SHALL not blindly reduce every metric to `{value, observed_at_unix_nano}`. It must carry enough metric metadata to decide whether the value is directly evaluable:
- gauge values may be evaluated directly;
- delta sums may be evaluated as their slot delta/rate, depending on metric class;
- cumulative monotonic sums require rate computation and reset handling before z-score evaluation;
- histograms require an explicit projection such as count, sum, mean, p50, p95, or bucket occupancy before evaluation.

Units are part of series identity or validation. The detector SHALL NOT mix percent, bytes, milliseconds, and unitless counts in one baseline.

### Decision 3: Ring buffers hold samples and verdict history; compact stats power evaluation
Each active series keeps bounded state:
- an active bucket accumulator for the current slot,
- a baseline ring buffer for recent clean evaluation values,
- incremental statistics (`count`, `sum`, `sum_squares`, and optionally min/max) for O(1) mean/stddev updates,
- confirmation counters,
- a small verdict ring for UI/audit/recent findings.

The reasoner hot path SHOULD consume compact state rather than a full baseline list. If the NIF boundary remains, it should accept compact stats or a native state resource/batch API so the BEAM does not copy the full window for every evaluation.

### Decision 4: Confirmation is measured in evaluation slots
The consecutive anomaly counter is counted over evaluation slots, not raw samples. If a deployment evaluates every 10 seconds and requires three confirmation slots, the minimum confirmation time is roughly 30 seconds. This keeps the operator-facing "sustained" meaning stable even when raw sample density changes.

### Decision 5: Use shard ownership for high-cardinality state
Per-series single-writer semantics are still required, but the implementation does not need one BEAM process per metric series at scale. The high-cardinality path SHOULD hash series keys across shard workers. Each shard owns many series states in ETS or a native state map, applies slot ordering per series, and emits verdicts.

The existing per-series `ContextOwner` remains useful for correctness tests and lower-cardinality paths, but the production high-cardinality path must be benchmarked with shard ownership.

### Decision 6: Benchmarks must report raw throughput and evaluation throughput separately
Scale validation must show:
- raw samples/sec accepted into the slot aggregation model,
- detector evaluations/sec after aggregation,
- active series count,
- baseline window size,
- evaluation interval,
- concurrency/shard count,
- confirmed anomaly count and failed series count.

The target is not just "1M raw samples/sec after downsampling." The engine needs a measurable path to approximately 1M detector evaluations/sec for deployments where active series count times evaluation cadence requires it.

## Risks / Trade-offs
- Risk: slot aggregation can hide short spikes if the wrong aggregation mode is used.
  - Mitigation: use spike-preserving defaults and store aggregation metadata.
- Risk: longer evaluation intervals increase detection latency.
  - Mitigation: make interval class-specific and expose the latency/throughput tradeoff in configuration.
- Risk: shard ownership is more complex than per-series processes.
  - Mitigation: keep deterministic per-series ordering inside the shard, add reorder/replay tests, and keep `ContextOwner` coverage for semantics.
- Risk: compact stats can diverge from list-based sample variance.
  - Mitigation: add equivalence tests against the existing reasoner over synthetic datasets and randomized windows.

## Migration Plan
1. Keep current per-sample behavior as the default by setting `evaluation_interval` equal to the incoming metric cadence.
2. Add canonical metric contract validation and first-class metric emit APIs through the `add-protobuf-metric-envelope` hard cutover; do not retain legacy version-1 JSON envelope compatibility.
3. Introduce slot aggregation and compact stats behind configuration.
4. Shadow-run bucketed evaluation against the current path in demo and compare verdicts.
5. Switch high-volume metric classes to bucketed evaluation once benchmarks and shadow comparisons pass.
6. Retain raw metric persistence unchanged through JetStream and `event_writer`.
