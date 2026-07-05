# Change: Update anomaly evaluation cadence and scale path

## Why
The current anomaly engine evaluates each incoming metric sample through per-series context ownership and a stateless reasoner. Benchmarks show this shape is not enough for large fleets where 50k agents may each report hundreds of metric series, and it also evaluates too eagerly when raw samples arrive faster than the useful anomaly cadence.

Issue `fj #3788` also shows that the detector is fed by fragmented metric contracts today: sysmon, plugin metrics, and OTLP metrics use different schemas, storage sinks, and series-identity recipes. The scale work cannot be correct if equivalent CPU/memory/disk/interface metrics become unrelated anomaly series or if cumulative counters are evaluated as raw gauges.

## What Changes
- Introduce a platform-side evaluation cadence: raw metric samples remain on JetStream and in CNPG, while the anomaly engine evaluates one spike-preserving bucket per series per configured slot.
- Add bounded per-series ring buffers for active bucket aggregation, baseline values, and recent verdicts.
- Replace baseline-list rebuilds on the hot path with compact incremental state so each evaluation is O(1) with respect to the baseline window.
- Support shard-owned high-cardinality state so the engine does not require one long-lived BEAM process per metric series at customer scale.
- Add correctness and scale benchmarks that separately report raw sample throughput and detector evaluation throughput, with a target path toward 1M evaluations/sec.
- Fold the `fj #3788` metric-pipeline findings into this change: evolve `serviceradar.metric.v1` into a first-class OTLP-grade metric contract with `resource`, `kind`, `temporality`, `unit`, and `points[]`; migrate metric producers onto the canonical metric path; and keep OCSF reserved for events/findings derived from metrics.

## Impact
- Affected specs: `anomaly-detection`, `ingestion-routing`, `plugin-sdk-go`, `wasm-plugin-system`
- Affected code: `elixir/serviceradar_core` anomaly detection, context ownership, causal reasoner NIF boundary, JetStream/Broadway analysis consumers, benchmark/test coverage, gateway metric publishers, metric processors, first-party collector emit paths, plugin SDK metric APIs
- Runtime impact: lower per-sample overhead, bounded memory per active series, clearer backpressure behavior under high-cardinality metric streams
